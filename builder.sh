#!/bin/bash
# vim: set ts=4 sw=4 sts=4 et :

set -e
set -o pipefail

[ "$DEBUG" = "1" ] && set -x

LOCALDIR="$(readlink -f "$(dirname "$0")")"
CONF="$(readlink -f "$1")"

[[ ! -r "$CONF" ]] && { echo "Please provide launcher configuration file"; exit 1; }

# shellcheck source=/dev/null
source "$CONF"

# Check if necessary variables are defined in the environnement
for var in RELEASE BRANCH_linux_kernel GITHUB_TOKEN_FILE GIT_UPSTREAM GIT_BASEURL_UPSTREAM GIT_PREFIX_UPSTREAM GIT_FORK GIT_BASEURL_FORK GIT_PREFIX_FORK
do
    if [ "x${!var}" = "x" ]; then
        echo "Please provide $var in env/conf: $CONF"
        exit 1
    fi
done

exit_launcher() {
    local exit_code=$?

    pushd "$LOCALDIR/qubes-builder"
    make distclean
    popd

    if [ ${exit_code} -ge 1 ]; then
        echo "-> An error occurred during build. Manual update for kernel ${LATEST_KERNEL_VERSION} is required"
    fi

    exit "${exit_code}"
}

distance_version() {
    read -ra VER1 <<<"$(echo "$1" | tr '.' ' ')"
    read -ra VER2 <<<"$(echo "$2" | tr '.' ' ')"

    [[ ${VER1[0]} -eq ${VER2[0]} ]] && [[ $((VER1[1] - VER2[1])) -le 1 ]] && [[ $((VER1[1] - VER2[1])) -ge 0 ]]
}

LATEST_KERNEL_VERSION="$("$LOCALDIR/kernel-updater.py" --token "$GITHUB_TOKEN_FILE" --check-update --base "$GIT_UPSTREAM:${BRANCH_linux_kernel:-master}")"

if [ "x$LATEST_KERNEL_VERSION" != "x" ]; then
    if [ -e "$LOCALDIR/qubes-builder" ]; then
        "$LOCALDIR/umount_kill.sh" "$LOCALDIR/qubes-builder"
        sudo rm -rf "$LOCALDIR/qubes-builder"
    fi
    git clone "${GIT_BASEURL_UPSTREAM}/${GIT_PREFIX_UPSTREAM}builder" "$LOCALDIR/qubes-builder"
    cp "$LOCALDIR/qubes-builder.conf" "$LOCALDIR/qubes-builder/builder.conf"

    pushd "$LOCALDIR/qubes-builder"
    make get-sources-git GIT_BASEURL="${GIT_BASEURL_UPSTREAM}" GIT_PREFIX="${GIT_PREFIX_UPSTREAM}"

    pushd "qubes-src/linux-kernel"
    HEAD_BRANCH="update-v$LATEST_KERNEL_VERSION"
    git checkout -b "$HEAD_BRANCH"
    echo "$LATEST_KERNEL_VERSION" > version
    echo 1 > rel
    make get-sources

    if [ "$BRANCH_linux_kernel" == "master" ]; then
        FC_LATEST="$(curl -s -L https://dl.fedoraproject.org/pub/fedora/linux/releases | sed -e 's/<[^>]*>//g' | awk '{print $1}' | grep -o "[0-9][1-9]" | tail -1)"
        FC_STABLE="$(dnf -q repoquery kernel --disablerepo=*modular* --releasever="$FC_LATEST" | tail -1 | cut -d ':' -f2 | cut -d '-' -f1)"
        FC_RAWHIDE="$(dnf -q repoquery kernel --disablerepo=*modular* --releasever=rawhide | tail -1 | cut -d ':' -f2 | cut -d '-' -f1)"

        if distance_version "$FC_STABLE" "$LATEST_KERNEL_VERSION"; then
            ./get-fedora-latest-config "$FC_LATEST"
            mv config-base-"$FC_STABLE" config-base
        elif distance_version "$FC_RAWHIDE" "$LATEST_KERNEL_VERSION"; then
            ./get-fedora-latest-config rawhide
            mv config-base-"$FC_RAWHIDE" config-base
        else
            echo "-> Cannot determine latest config for kernel ${LATEST_KERNEL_VERSION}. Use the current existing config..."
        fi
    fi
    popd

    trap 'exit_launcher' ERR EXIT INT TERM

    make linux-kernel USE_QUBES_REPO_VERSION="$RELEASE" USE_QUBES_REPO_TESTING=1

    pushd "qubes-src/linux-kernel"
    git add version rel config-base
    git commit -m "Update to kernel-$LATEST_KERNEL_VERSION"
    git remote add fork "${GIT_BASEURL_FORK}${GIT_PREFIX_FORK}linux-kernel"
    git push -u fork "$HEAD_BRANCH"
    popd

    "$LOCALDIR/kernel-updater.py" --token "$GITHUB_TOKEN_FILE" --create-pullrequest --base "$GIT_UPSTREAM:${BRANCH_linux_kernel:-master}" --head "$GIT_FORK:$HEAD_BRANCH"
else
    echo "-> Current kernel version in branch ${BRANCH_linux_kernel} is up to date"
fi


