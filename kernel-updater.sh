#!/bin/bash
# vim: set ts=4 sw=4 sts=4 et :

set -e
set -o pipefail

[ "$DEBUG" = "1" ] && set -x

LOCALDIR="$(readlink -f "$(dirname "$0")")"
[[ "x$BUILDDIR" == "x" ]] && BUILDDIR="$LOCALDIR"

BUILDERDIR="$BUILDDIR/qubes-builder-kernel-${BRANCH_linux_kernel}"

GIT_UPSTREAM='QubesOS'
GIT_FORK='fepitre-bot'

GIT_BASEURL_UPSTREAM="https://github.com"
GIT_PREFIX_UPSTREAM="$GIT_UPSTREAM/qubes-"

GIT_BASEURL_FORK="git@github.com:"
GIT_PREFIX_FORK="$GIT_FORK/qubes-"

GITHUB_TOKEN_FILE="$HOME/.github_api_token"

if [ -e "$UPDATER_CONF" ]; then
    # shellcheck source=/dev/null
    source "$UPDATER_CONF"
fi

VARS='RELEASE BRANCH_linux_kernel GITHUB_TOKEN_FILE GIT_UPSTREAM GIT_BASEURL_UPSTREAM GIT_PREFIX_UPSTREAM GIT_FORK GIT_BASEURL_FORK GIT_PREFIX_FORK'

# Check if necessary variables are defined in the environnement
for var in $VARS
do
    if [ "x${!var}" = "x" ]; then
        echo "Please provide $var in env/conf: $CONF"
        exit 1
    fi
done

exit_launcher() {
    local exit_code=$?

    pushd "$BUILDERDIR"
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

LATEST_KERNEL_VERSION="$(python3 "$LOCALDIR/kernel-updater.py" --token "$GITHUB_TOKEN_FILE" --check-update --base "$GIT_UPSTREAM:${BRANCH_linux_kernel:-master}")"

if [ "x$LATEST_KERNEL_VERSION" == "x" ]; then
    echo "-> Current kernel version in branch ${BRANCH_linux_kernel} is up to date"
    exit 0
fi

if [ -e "$BUILDERDIR" ]; then
    "$LOCALDIR/umount_kill.sh" "$BUILDERDIR"
    sudo rm -rf "$BUILDERDIR"
fi

trap 'exit_launcher' 0 1 2 3 6 15

git clone "${GIT_BASEURL_UPSTREAM}/${GIT_PREFIX_UPSTREAM}builder" "$BUILDERDIR"
if [ "x$BUILDERCONF" == "x" ];  then
    cp "$LOCALDIR/qubes-builder.conf" "$BUILDERDIR/builder.conf"
fi

pushd "$BUILDERDIR"
make remount get-sources-git GIT_BASEURL="${GIT_BASEURL_UPSTREAM}" GIT_PREFIX="${GIT_PREFIX_UPSTREAM}"

pushd "$BUILDERDIR/qubes-src/linux-kernel"
HEAD_BRANCH="update-v$LATEST_KERNEL_VERSION"
git checkout -b "$HEAD_BRANCH"
echo "$LATEST_KERNEL_VERSION" > version
echo 1 > rel
make get-sources

if [ "$BRANCH_linux_kernel" == "master" ]; then
    FC_LATEST="$(curl -s -L https://dl.fedoraproject.org/pub/fedora/linux/releases | sed -e 's/<[^>]*>//g' | awk '{print $1}' | grep -o "[1-9][0-9]" | tail -1)"
    STABLE_KERNEL="$(dnf -q repoquery kernel --disablerepo=* --enablerepo=fedora --enablerepo=updates --releasever="$FC_LATEST" | sort -V | tail -1 | cut -d ':' -f2 | cut -d '-' -f1)"
    RAWHIDE_KERNEL="$(dnf -q repoquery kernel --disablerepo=* --enablerepo=fedora --enablerepo=updates --releasever=rawhide | grep -v "rc[0-9]*" | sort -V | tail -1 | cut -d ':' -f2 | cut -d '-' -f1 || true)"

    if distance_version "$STABLE_KERNEL" "$LATEST_KERNEL_VERSION"; then
        ./get-fedora-latest-config "$FC_LATEST"
        mv config-base-"$STABLE_KERNEL" config-base
    elif distance_version "$RAWHIDE_KERNEL" "$LATEST_KERNEL_VERSION"; then
        ./get-fedora-latest-config rawhide
        mv config-base-"$RAWHIDE_KERNEL" config-base
    else
        echo "-> Cannot determine latest config for kernel ${LATEST_KERNEL_VERSION}. Use the current existing config..."
    fi
fi
popd

make linux-kernel USE_QUBES_REPO_VERSION="$RELEASE" USE_QUBES_REPO_TESTING=1

pushd "$BUILDERDIR/qubes-src/linux-kernel"
git add version rel config-base
git commit -m "Update to kernel-$LATEST_KERNEL_VERSION"
git remote add fork "${GIT_BASEURL_FORK}${GIT_PREFIX_FORK}linux-kernel"
git push -u fork "$HEAD_BRANCH"
popd

"$LOCALDIR/kernel-updater.py" --token "$GITHUB_TOKEN_FILE" --create-pullrequest --base "$GIT_UPSTREAM:${BRANCH_linux_kernel:-master}" --head "$GIT_FORK:$HEAD_BRANCH"

# Sign kernel RPMs and update to repository
make sign-all update-repo-unstable
