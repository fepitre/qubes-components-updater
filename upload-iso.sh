#!/usr/bin/bash

set -e
set -o pipefail

LOCALDIR="$(readlink -f "$(dirname "$0")")"
RELEASE="$1"
if [ -z "$RELEASE" ]; then
    echo "-> Please provide Qubes OS release."
    exit 1
fi
BUILDERDIR="/home/user/iso/builder-${RELEASE}"
if [ -n "${ISO_FLAVOR}" ]; then
    BUILDERDIR="${BUILDERDIR}-${ISO_FLAVOR}"
fi

# Hide sensitive info
[ "$DEBUG" = "1" ] && set -x

exit_launcher() {
    local exit_code=$?
    if [ ${exit_code} -eq 0 ]; then
        make -C "$BUILDERDIR" distclean || true
    elif [ ${exit_code} -ge 1 ]; then
        echo "-> An error occurred during build. Manual update is required."
    fi
    exit "${exit_code}"
}

trap 'exit_launcher' 0 1 2 3 6 15

if ! [ -e "${BUILDERDIR}" ]; then
    echo "-> Cannot find artifacts."
fi

make -C "$BUILDERDIR" upload-iso

# We must not have more than one ISO but prevent any issue.
ISO="$(find "$BUILDERDIR"/iso -name "*.iso" | head -1)"
ISO_NAME="$(basename "$ISO")"
ISO_BASE="${ISO_NAME%%.iso}"
ISO_DATE="$(cat "$BUILDERDIR"/qubes-src/installer-qubes-os/build/ISO/qubes-x86_64/iso/build_latest)"

# Upload log
rsync "$BUILDERDIR"/build-logs/installer-qubes-os-iso-fc32.log "$HOST:$HOST_ISO_BASEDIR/$ISO_BASE$ISO_SUFFIX.log"

# Trigger openQA test
BUILD="$ISO_DATE"
if [ -n "$ISO_FLAVOR" ]; then
    BUILD="${BUILD}-${ISO_FLAVOR}"
fi
BUILD="${BUILD}-${RELEASE}"
python3 "$LOCALDIR/openqa-trigger-iso-test.py" "${RELEASE}" "${BUILD}" "${ISO_NAME}"
