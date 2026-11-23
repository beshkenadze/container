#!/bin/bash
# Fails when the installer package has no cluster-shim. Without it, `container cluster create
# --shared-image-store` fails on the installed release.
#
#   scripts/check-release-package.sh <installer.pkg>

set -euo pipefail

pkg="${1:?usage: $0 <installer.pkg>}"
shim="./libexec/container/plugins/cluster/resources/cluster-shim"

files="$(pkgutil --payload-files "$pkg")"
if ! grep -qxF "$shim" <<<"$files"; then
    echo "error: $pkg has no ${shim#./}" >&2
    exit 1
fi
echo "$pkg has ${shim#./}"
