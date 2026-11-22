#!/bin/bash
# Live check: a create under a name that the data root's file system folds onto an existing
# entity (`ABC` beside `abc` on case-insensitive APFS) must not touch the existing entity.
#
#   C=<container CLI> scripts/live-check-folded-names.sh [--machines]
#
# Every object carries a random suffix. Before it makes anything, the script refuses to run when
# any entity of any kind matches one of its names in either spelling: in the directories under
# the daemon's own app root (as the file system compares names) and in every listing. Its cleanup
# removes only the objects that it created, by name. It is for a host where nobody else creates
# entities whose names start with vfold, cfold or mfold during the run: an entity that another
# actor creates under one of its names between the preflight and the cleanup would be removed. --machines also checks container machines (it boots
# an alpine machine, about a minute).
#
# Output per entity: PASS (refused, the first entity is intact), FAIL (the first entity was
# changed or removed), N/A (the data root is case-sensitive, so the names are distinct).
# Exit status: 0 when every check passed, 1 when a check failed, 2 when the script could not run,
# 3 when nothing failed but a check was N/A.

set -u
C="${C:-container}"
WITH_MACHINES=0
[[ "${1:-}" == "--machines" ]] && WITH_MACHINES=1

RUN="$(LC_ALL=C tr -dc 'a-z0-9' </dev/urandom | head -c 6)"
FAILED=0
SKIPPED=0
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

# The data root of the daemon that the CLI talks to, not one chosen by this shell.
status="$("$C" system status 2>/dev/null)" || die "the container system does not answer ($C system status)"
ROOT="$(printf '%s\n' "$status" | awk '$1 == "paths.appRoot" { sub(/^[^ ]+ +/, ""); print }')"
ROOT="${ROOT%/}"
[[ -n "$ROOT" && -d "$ROOT" ]] || die "the daemon reports no usable app root ($ROOT)"
MACHINE_ROOT="$ROOT/plugin-state/machine-apiserver/machines"

# The case behaviour of each entity root decides what its check expects: a root can be a link to,
# or a mount of, another file system. The probe never replaces an existing file: noclobber makes
# the redirection fail instead.
folds() { # directory -> prints 1 when it compares names without case, 0 otherwise
    local dir="$1"
    # A root that does not exist yet is probed at its nearest existing parent; nothing is created.
    while [[ ! -d "$dir" ]]; do dir="$(dirname "$dir")"; done
    local probe="$dir/.foldprobe-$RUN"
    (set -o noclobber; : >"$probe") 2>/dev/null || die "cannot create the probe $probe (it exists, or the root is not writable)"
    [[ -e "$dir/$(upper ".foldprobe-$RUN")" ]] && echo 1 || echo 0
    rm -f -- "$probe"
}
FOLD_VOLUMES=$(folds "$ROOT/volumes")
FOLD_CONTAINERS=$(folds "$ROOT/containers")
FOLD_MACHINES=0
[[ $WITH_MACHINES -eq 1 ]] && FOLD_MACHINES=$(folds "$MACHINE_ROOT")
echo "data root: $ROOT (case-insensitive: volumes $FOLD_VOLUMES, containers $FOLD_CONTAINERS, machines $FOLD_MACHINES), run: $RUN"

# Every listing, read once. A listing that fails stops the run: an unseen entity could match.
LISTINGS="$("$C" list --all --format json)" || die "container list failed"
LISTINGS+="$("$C" volume list --format json)" || die "container volume list failed"
LISTINGS+="$("$C" network list --format json)" || die "container network list failed"
LISTINGS+="$("$C" machine list 2>&1)" || die "container machine list failed"

# Refuses to run when any entity of any kind matches one of the names in either spelling.
absent() { # name...
    local name spelling
    for name in "$@"; do
        for spelling in "$(lower "$name")" "$(upper "$name")"; do
            [[ -e "$ROOT/containers/$spelling" || -e "$ROOT/volumes/$spelling" || -e "$MACHINE_ROOT/$spelling" ]] &&
                die "an entity named $spelling exists under $ROOT"
        done
        printf '%s' "$LISTINGS" | grep -qi -- "$name" && die "an entity listed by the runtime matches $name"
    done
    return 0
}

result() { # entity verdict detail
    echo "$1: $2 - $3"
    [[ "$2" == FAIL ]] && FAILED=1
    [[ "$2" == N/A ]] && SKIPPED=1
    return 0
}

# A refusal of the second create counts only when its error is the name conflict.
conflict() { [[ "$1" == *"already exist"* || "$1" == *"cannot be created"* ]]; }

check_volumes() {
    local FOLD=$FOLD_VOLUMES
    local first="vfold$RUN" second
    second="$(upper "$first")"
    absent "$first"
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
    if [[ $FOLD -eq 0 ]]; then
        result volumes N/A "case-sensitive data root, create $second rc=$rc"
    elif [[ "$data" != precious ]]; then
        result volumes FAIL "create $second (rc=$rc: ${out//$'\n'/ }) erased $first: /data/p reads '${data//$'\n'/ }'"
    elif [[ $rc -eq 0 ]]; then
        result volumes FAIL "create $second succeeded on a case-insensitive root"
    elif ! conflict "$out"; then
        result volumes FAIL "create $second failed for another reason: ${out//$'\n'/ }"
    else
        result volumes PASS "create $second refused (${out//$'\n'/ }); $first still holds its data"
    fi
}

check_containers() {
    local FOLD=$FOLD_CONTAINERS
    local first="cfold$RUN" second
    second="$(upper "$first")"
    absent "$first"
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
    if [[ $FOLD -eq 0 ]]; then
        result containers N/A "case-sensitive data root, create $second rc=$rc"
    elif [[ "$data" != *precious* ]]; then
        result containers FAIL "create and delete of $second (rc=$rc: ${out//$'\n'/ }) destroyed $first: ${data//$'\n'/ }"
    elif [[ $rc -eq 0 ]]; then
        result containers FAIL "create $second succeeded on a case-insensitive root"
    elif ! conflict "$out"; then
        result containers FAIL "create $second failed for another reason: ${out//$'\n'/ }"
    else
        result containers PASS "create $second refused (${out//$'\n'/ }); $first still holds its data"
    fi
}

# The state of a machine bundle that a folded create must not change: its configuration, its boot
# configuration, and the identity of its root file system.
machine_state() { # bundle directory
    shasum "$1/config.json" "$1/boot-config.json" 2>/dev/null | cut -d' ' -f1 | tr '\n' ' '
    stat -f '%i %z %m' "$1/rootfs.ext4" 2>/dev/null
}

check_machines() {
    local FOLD=$FOLD_MACHINES
    local first="mfold$RUN" second
    second="$(upper "$first")"
    absent "$first"
    if ! "$C" machine create alpine:3.22 --name "$first" >/dev/null 2>&1; then
        # A create can publish its bundle and then fail: clean it up too.
        [[ -d "$MACHINE_ROOT/$first" ]] && MADE_MACHINES+=("$first")
        die "machine create $first failed"
    fi
    MADE_MACHINES+=("$first")
    "$C" machine stop "$first" >/dev/null 2>&1
    local bundle="$MACHINE_ROOT/$first"
    [[ -f "$bundle/config.json" ]] || die "no bundle configuration at $bundle/config.json"
    local before after out rc
    before="$(machine_state "$bundle")"
    out="$("$C" machine create alpine:3.22 --name "$second" 2>&1)"
    rc=$?
    if [[ $rc -eq 0 ]] || "$C" machine list 2>/dev/null | awk 'NR>1{print $1}' | grep -qx "$second"; then
        MADE_MACHINES+=("$second")
    fi
    after="$(machine_state "$bundle")"
    if [[ $FOLD -eq 0 ]]; then
        result machines N/A "case-sensitive data root, create $second rc=$rc"
    elif [[ "$before" != "$after" ]]; then
        result machines FAIL "create $second (rc=$rc) changed the bundle of $first: $(grep -o '"id" *: *"[^"]*"' "$bundle/config.json" | head -1)"
    elif [[ $rc -eq 0 ]]; then
        result machines FAIL "create $second succeeded on a case-insensitive root"
    elif ! conflict "$out"; then
        result machines FAIL "create $second failed for another reason: ${out//$'\n'/ | }"
    else
        result machines PASS "create $second refused (${out//$'\n'/ | }); the bundle of $first is unchanged"
    fi
}

check_volumes
check_containers
[[ $WITH_MACHINES -eq 1 ]] && check_machines
[[ $FAILED -eq 1 ]] && exit 1
[[ $SKIPPED -eq 1 ]] && exit 3
exit 0
