#!/usr/bin/bash

set -e
set -o pipefail

LOCALDIR="$(readlink -f "$(dirname "$0")")"
RELEASE="$1"
if [ "$RELEASE" != "4.1" ] && [ "$RELEASE" != "4.2" ]; then
    echo "ERROR: Please provide supported Qubes OS release."
    exit 1
fi
BUILDERDIR="/home/user/iso/builder-r${RELEASE}"
if [ -n "${ISO_FLAVOR}" ]; then
    BUILDERDIR="${BUILDERDIR}-${ISO_FLAVOR}"
fi

ISO_TIMESTAMP="$(date +%Y%m%d%H%M)"
ISO_VERSION="${RELEASE}.${ISO_TIMESTAMP}"
export ISO_VERSION

[ "$DEBUG" = "1" ] && set -x

exit_launcher() {
    local exit_code=$?
    if [ ${exit_code} -ge 1 ]; then
        echo "ERROR: An error occurred during build. Manual update is required."
    fi
    exit "${exit_code}"
}

trap 'exit_launcher' 0 1 2 3 6 15

if [ -d "${BUILDERDIR}" ]; then
    if [ "${RELEASE}" == "4.1" ]; then
        make -C "$BUILDERDIR" distclean || true
    fi
    sudo rm -rf "$BUILDERDIR"
fi

if [ "${RELEASE}" == "4.2" ]; then
    # Clone and verify qubes-builderv2 source
    "${LOCALDIR}"/get-qubes-builder.sh "${BUILDERDIR}" "https://github.com/QubesOS/qubes-builderv2"
    # Generate docker from scratch
    "${BUILDERDIR}"/tools/generate-container-image.sh docker fedora-37-x86_64
    # Start the build
    cd "${BUILDERDIR}"
    cp "${LOCALDIR}"/builder-r4.2.yml "$BUILDERDIR"/builder.yml
    ./qb package fetch
    ./qb --log-file "${BUILDERDIR}"/installer-qubes-os-iso-fc37.log -o use-qubes-repo:testing=true -o sign-key:iso=1C8714D640F30457EC953050656946BA873DDEC1 -o iso:version="${ISO_VERSION}" installer init-cache prep --iso-timestamp "${ISO_TIMESTAMP}" build sign
elif [ "${RELEASE}" == "4.1" ]; then
    # Clone and verify qubes-builder source
    "${LOCALDIR}"/get-qubes-builder.sh "${BUILDERDIR}" "https://github.com/QubesOS/qubes-builder"
    # Start the build
    make -C "$BUILDERDIR" get-sources BUILDERCONF= COMPONENTS="release-configs" GIT_URL_release_configs=https://github.com/qubesos/qubes-release-configs
    cp "$BUILDERDIR/qubes-src/release-configs/R${RELEASE}/qubes-os-iso-full-online.conf" "$BUILDERDIR"/builder.conf
    echo "USE_QUBES_REPO_TESTING=1" >> "$BUILDERDIR"/builder.conf
    make -C "$BUILDERDIR" get-sources
    make -C "$BUILDERDIR" install-deps remount iso sign-iso VERBOSE=0
fi
