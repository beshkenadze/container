#!/bin/bash
# Live check: a create under a name that the data root's file system folds onto an existing
# entity (`ABC` beside `abc` on case-insensitive APFS) must not touch the existing entity.
#
#   C=<container CLI> scripts/live-check-folded-names.sh [--machines]
#
# Every object carries a random suffix; the script refuses to start if either spelling already
# exists, and its cleanup removes only the objects that it created. --machines also checks
# container machines (it boots an alpine machine, about a minute).
#
# Output per entity: PASS (refused, the first entity is intact), FAIL (the first entity was
# changed or removed), N/A (the data root is case-sensitive, so the names are distinct).
# Exit status: 0 when nothing failed, 1 when a check failed, 2 when the script could not run.

set -u
C="${C:-container}"
WITH_MACHINES=0
[[ "${1:-}" == "--machines" ]] && WITH_MACHINES=1

ROOT="${CONTAINER_APP_ROOT:-$HOME/Library/Application Support/com.apple.container}"
RUN="$(LC_ALL=C tr -dc 'a-z0-9' </dev/urandom | head -c 6)"
FAILED=0
MADE_VOLUMES=()
MADE_CONTAINERS=()
MADE_MACHINES=()

die() { echo "ERROR: $*" >&2; exit 2; }
lower() { printf '%s' "$1" | tr 'A-Z' 'a-z'; }
upper() { printf '%s' "$1" | tr 'a-z' 'A-Z'; }

cleanup() {
    local name
    for name in "${MADE_MACHINES[@]+"${MADE_MACHINES[@]}"}"; do
        "$C" machine stop "$name" >/dev/null 2>&1
        "$C" machine delete "$name" >/dev/null 2>&1 || echo "cleanup: machine $name not removed" >&2
    done
    for name in "${MADE_CONTAINERS[@]+"${MADE_CONTAINERS[@]}"}"; do
        "$C" delete -f "$name" >/dev/null 2>&1 || echo "cleanup: container $name not removed" >&2
    done
    for name in "${MADE_VOLUMES[@]+"${MADE_VOLUMES[@]}"}"; do
        "$C" volume delete "$name" >/dev/null 2>&1 || echo "cleanup: volume $name not removed" >&2
    done
}
trap cleanup EXIT

"$C" system status >/dev/null 2>&1 || die "the container system does not answer ($C system status)"
[[ -d "$ROOT" ]] || die "no data root at $ROOT"

# Case behaviour of the data root decides what the checks expect.
probe="$ROOT/.foldprobe-$RUN"
: >"$probe" || die "cannot write $probe"
CASE_INSENSITIVE=0
[[ -e "$ROOT/$(upper ".foldprobe-$RUN")" ]] && CASE_INSENSITIVE=1
rm -f -- "$probe"
echo "data root: $ROOT (case-insensitive: $CASE_INSENSITIVE), run: $RUN"

absent() { # kind name...
    local kind="$1" name
    shift
    for name in "$@"; do
        case "$kind" in
            volume) "$C" volume list --quiet 2>/dev/null | grep -qix "$name" && die "volume $name exists" ;;
            container) "$C" list --all --quiet 2>/dev/null | grep -qix "$name" && die "container $name exists" ;;
            machine) "$C" machine list 2>/dev/null | awk 'NR>1{print $1}' | grep -qix "$name" && die "machine $name exists" ;;
        esac
    done
}

result() { # entity verdict detail
    echo "$1: $2 - $3"
    [[ "$2" == FAIL ]] && FAILED=1
}

check_volumes() {
    local first="vfold$RUN" second
    second="$(upper "$first")"
    absent volume "$first" "$second"
    "$C" volume create --opt size=64M "$first" >/dev/null || die "volume create $first failed"
    MADE_VOLUMES+=("$first")
    "$C" run --rm -v "$first:/data" busybox:1.37-musl sh -c 'echo precious > /data/p && sync' >/dev/null 2>&1 ||
        die "writing into volume $first failed"
    local out rc
    out="$("$C" volume create --opt size=64M "$second" 2>&1)"
    rc=$?
    [[ $rc -eq 0 ]] && MADE_VOLUMES+=("$second")
    local data
    data="$("$C" run --rm -v "$first:/data" busybox:1.37-musl cat /data/p 2>/dev/null)"
    if [[ $CASE_INSENSITIVE -eq 0 ]]; then
        result volumes N/A "case-sensitive data root, create $second rc=$rc"
    elif [[ "$data" != precious ]]; then
        result volumes FAIL "create $second (rc=$rc: ${out//$'\n'/ }) erased $first: /data/p reads '${data//$'\n'/ }'"
    elif [[ $rc -eq 0 ]]; then
        result volumes FAIL "create $second succeeded on a case-insensitive root"
    else
        result volumes PASS "create $second refused (${out//$'\n'/ }); $first still holds its data"
    fi
}

check_containers() {
    local first="cfold$RUN" second
    second="$(upper "$first")"
    absent container "$first" "$second"
    "$C" run --name "$first" busybox:1.37-musl sh -c 'echo precious > /p && sync' >/dev/null 2>&1 ||
        die "container run $first failed"
    MADE_CONTAINERS+=("$first")
    local out rc
    out="$("$C" create --name "$second" --network none busybox:1.37-musl true 2>&1)"
    rc=$?
    if [[ $rc -eq 0 ]]; then
        # The delete is part of the sequence under test; on the old runtime it removes $first's bundle.
        "$C" delete "$second" >/dev/null 2>&1 || MADE_CONTAINERS+=("$second")
    fi
    local data
    data="$("$C" export "$first" 2>/dev/null | tar -xOf - p 2>/dev/null)"
    if [[ $CASE_INSENSITIVE -eq 0 ]]; then
        result containers N/A "case-sensitive data root, create $second rc=$rc"
    elif [[ "$data" != *precious* ]]; then
        result containers FAIL "create and delete of $second (rc=$rc: ${out//$'\n'/ }) destroyed $first: ${data//$'\n'/ }"
    elif [[ $rc -eq 0 ]]; then
        result containers FAIL "create $second succeeded on a case-insensitive root"
    else
        result containers PASS "create $second refused (${out//$'\n'/ }); $first still holds its data"
    fi
}

check_machines() {
    local first="mfold$RUN" second
    second="$(upper "$first")"
    absent machine "$first" "$second"
    "$C" machine create alpine:3.22 --name "$first" >/dev/null 2>&1 || die "machine create $first failed"
    MADE_MACHINES+=("$first")
    "$C" machine stop "$first" >/dev/null 2>&1
    local bundle="$ROOT/plugin-state/machine-apiserver/machines/$first/config.json"
    [[ -f "$bundle" ]] || die "no bundle configuration at $bundle"
    local before after out rc
    before="$(shasum "$bundle" | cut -d' ' -f1)"
    out="$("$C" machine create alpine:3.22 --name "$second" 2>&1)"
    rc=$?
    [[ $rc -eq 0 ]] && MADE_MACHINES+=("$second")
    after="$(shasum "$bundle" | cut -d' ' -f1)"
    if [[ $CASE_INSENSITIVE -eq 0 ]]; then
        result machines N/A "case-sensitive data root, create $second rc=$rc"
    elif [[ "$before" != "$after" ]]; then
        result machines FAIL "create $second (rc=$rc) rewrote the configuration of $first: $(grep -o '"id" *: *"[^"]*"' "$bundle" | head -1)"
    elif [[ $rc -eq 0 ]]; then
        result machines FAIL "create $second succeeded on a case-insensitive root"
    else
        result machines PASS "create $second refused (${out//$'\n'/ | }); the configuration of $first is unchanged"
    fi
}

check_volumes
check_containers
[[ $WITH_MACHINES -eq 1 ]] && check_machines
exit $FAILED
