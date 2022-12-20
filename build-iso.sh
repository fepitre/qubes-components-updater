#!/usr/bin/bash

set -e
set -o pipefail

LOCALDIR="$(readlink -f "$(dirname "$0")")"
RELEASE="${1:-4.1}"
BUILDERDIR="/home/user/iso/builder-${RELEASE}"
if [ -n "${ISO_FLAVOR}" ]; then
    BUILDERDIR="${BUILDERDIR}-${ISO_FLAVOR}"
fi

ISO_VERSION="${RELEASE}.$(date +%Y%m%d)"
export ISO_VERSION

[ "$DEBUG" = "1" ] && set -x

exit_launcher() {
    local exit_code=$?
    if [ ${exit_code} -ge 1 ]; then
        echo "-> An error occurred during build. Manual update is required."
    fi
    exit "${exit_code}"
}

trap 'exit_launcher' 0 1 2 3 6 15

if [ -d "${BUILDERDIR}" ]; then
    make -C "$BUILDERDIR" distclean || true
    sudo rm -rf "$BUILDERDIR"
fi

git clone https://github.com/QubesOS/qubes-builder "$BUILDERDIR"
make -C "$BUILDERDIR" get-sources BUILDERCONF= COMPONENTS="release-configs" GIT_URL_release_configs=https://github.com/qubesos/qubes-release-configs
cp "$BUILDERDIR/qubes-src/release-configs/R${RELEASE}/qubes-os-iso-full-online.conf" "$BUILDERDIR"/builder.conf
sed -i "s|iso-full-online.ks|travis-iso-full.ks|" "$BUILDERDIR"/builder.conf
echo "USE_QUBES_REPO_TESTING=1" >> "$BUILDERDIR"/builder.conf
make -C "$BUILDERDIR" get-sources
make -C "$BUILDERDIR" install-deps remount iso sign-iso VERBOSE=0
