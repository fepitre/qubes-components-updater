#!/usr/bin/bash

set -e
set -o pipefail

[ "$DEBUG" = "1" ] && set -x

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

if ! [ -e "${BUILDERDIR}" ]; then
    echo "ERROR: Cannot find builder directory."
    exit 1
fi

if [ "${RELEASE}" == "4.2" ]; then
    cd "$BUILDERDIR"
    ARTIFACTS_DIR="$(./qb config get-var artifacts-dir 2>/dev/null)"
    if [ -z "${ARTIFACTS_DIR}" ] || [ ! -d "${ARTIFACTS_DIR}" ]; then
        echo "ERROR: Cannot find artifacts directory."
        exit 1
    fi
fi

exit_launcher() {
    local exit_code=$?
#    if [ ${exit_code} -eq 0 ]; then
#        if [ "${RELEASE}" == "4.2" ]; then
#            rm -rf "$ARTIFACTS_DIR"
#        elif [ "${RELEASE}" == "4.1" ]; then
#            make -C "$BUILDERDIR" distclean || true
#        fi
#    elif [ ${exit_code} -ge 1 ]; then
    if [ ${exit_code} -ge 1 ]; then
        echo "ERROR: An error occurred during build. Manual update is required."
    fi
    exit "${exit_code}"
}

trap 'exit_launcher' 0 1 2 3 6 15

# We must not have more than one ISO but prevent any issue.
if [ "${RELEASE}" == "4.2" ]; then
    ISO="$(find "$ARTIFACTS_DIR"/iso -name "*.iso" | head -1)"
    ISO_LOG="$BUILDERDIR"/installer-qubes-os-iso-fc37.log
    if [ -n "$ISO_FLAVOR" ]; then
        ISO_TIMESTAMP="$(cat "$ARTIFACTS_DIR/installer/latest_fc37_iso_${ISO_FLAVOR}_timestamp" 2>/dev/null)"
    else
        ISO_TIMESTAMP="$(cat "$ARTIFACTS_DIR"/installer/latest_fc37_iso_timestamp 2>/dev/null)"
    fi
    ISO_VERSION="${RELEASE}.${ISO_TIMESTAMP}"
elif [ "${RELEASE}" == "4.1" ]; then
    ISO="$(find "$BUILDERDIR"/iso -name "*.iso" | head -1)"
    ISO_TIMESTAMP="$(cat "$BUILDERDIR"/qubes-src/installer-qubes-os/build/ISO/qubes-x86_64/iso/build_latest 2>/dev/null)"
    ISO_LOG="$BUILDERDIR"/build-logs/installer-qubes-os-iso-fc32.log
fi

if [ -z "${ISO}" ]; then
    echo "ERROR: Cannot determine ISO location."
    exit 1
fi

if [ -z "${ISO_TIMESTAMP}" ]; then
    echo "ERROR: Cannot determine ISO_TIMESTAMP."
    exit 1
fi

# Upload ISO
if [ "${RELEASE}" == "4.2" ]; then
    cd "$BUILDERDIR" && ./qb -o iso:version="${ISO_VERSION}" installer upload
elif [ "${RELEASE}" == "4.1" ]; then
    make -C "$BUILDERDIR" upload-iso
fi

ISO_NAME="$(basename "$ISO")"
ISO_BASE="${ISO_NAME%%.iso}"

# Upload log
if [ -n "${HOST}" ] && [ -n "${HOST_ISO_BASEDIR}" ] && [ -n "${ISO_BASE}" ]; then
    rsync "${ISO_LOG}" "$HOST:$HOST_ISO_BASEDIR/$ISO_BASE$ISO_SUFFIX.log"
fi

# Trigger openQA test
BUILD="$ISO_TIMESTAMP"
if [ -n "$ISO_FLAVOR" ]; then
    BUILD="${BUILD}-${ISO_FLAVOR}"
fi
BUILD="${BUILD}-${RELEASE}"
python3 "$LOCALDIR/openqa-trigger-iso-test.py" "${RELEASE}" "${BUILD}" "${ISO_NAME}"
