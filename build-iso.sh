#!/usr/bin/bash

set -e
set -o pipefail

LOCALDIR="$(readlink -f "$(dirname "$0")")"
TMPDIR="$(mktemp -d -p /home/user)"
BUILDERDIR="$TMPDIR/qubes-builder"

# Hide sensitive info
[ "$DEBUG" = "1" ] && set -x

exit_launcher() {
    local exit_code=$?
    make -C "$BUILDERDIR" distclean || true
    sudo rm -rf "$TMPDIR"
    if [ ${exit_code} -ge 1 ]; then
        echo "-> An error occurred during build. Manual update is required"
    fi
    exit "${exit_code}"
}

trap 'exit_launcher' 0 1 2 3 6 15

git clone https://github.com/QubesOS/qubes-builder "$BUILDERDIR"
make -C "$BUILDERDIR" get-sources BUILDERCONF= COMPONENTS="release-configs" GIT_URL_release_configs=https://github.com/qubesos/qubes-release-configs
cp "$BUILDERDIR"/qubes-src/release-configs/R4.1/qubes-os-iso-full-online.conf "$BUILDERDIR"/builder.conf
sed -i "s|iso-full-online.ks|travis-iso-full.ks|" "$BUILDERDIR"/builder.conf
make -C "$BUILDERDIR" get-sources
#sed -i 's#\(<packagereq type="\)optional\(">kernel-latest.*$\)#\1mandatory\2#' "$BUILDERDIR"/qubes-src/installer-qubes-os/conf/comps-qubes.xml
make -C "$BUILDERDIR" install-deps remount iso sign-iso upload-iso VERBOSE=0
