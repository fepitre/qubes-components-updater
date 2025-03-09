#!/bin/bash
# vim: set ts=4 sw=4 sts=4 et :

set -e
set -o pipefail

LOCALDIR="$(readlink -f "$(dirname "$0")")"
BUILDDIR="$(mktemp -d -p /home/user)"
KERNELDIR="$BUILDDIR/linux-kernel-${BRANCH_linux_kernel}"
BUILDERRPMDIR="$BUILDDIR/builder-rpm"

GIT_UPSTREAM='QubesOS'
GIT_FORK='fepitre-bot'
GIT_BASEURL_UPSTREAM="https://github.com"
GIT_PREFIX_UPSTREAM="$GIT_UPSTREAM/qubes-"
GIT_BASEURL_FORK="git@github.com:"
GIT_PREFIX_FORK="$GIT_FORK/qubes-"

VARS='BRANCH_linux_kernel GITHUB_API_TOKEN'

# Check if necessary variables are defined in the environment
for var in $VARS; do
    if [ "x${!var}" = "x" ]; then
        echo "Please provide $var in env"
        exit 1
    fi
done

# Filter allowed branches
if [[ ! "${BRANCH_linux_kernel}" =~ ^stable-[0-9]+\.[0-9]+$ ]] && [ "${BRANCH_linux_kernel}" != "main" ]; then
    echo "Cannot determine kernel branch to use."
    exit 1
fi

distance_version() {
    read -ra VER1 <<<"$(echo "$1" | tr '.' ' ')"
    read -ra VER2 <<<"$(echo "$2" | tr '.' ' ')"

    [[ ${VER1[0]} -eq ${VER2[0]} ]] && [[ $((VER1[1] - VER2[1])) -le 1 ]] && [[ $((VER1[1] - VER2[1])) -ge 0 ]]
}

# Hide sensitive info
[ "$DEBUG" = "1" ] && set -x

exit_launcher() {
    local exit_code=$?
    sudo rm -rf "$BUILDDIR"
    if [ ${exit_code} -ge 1 ]; then
        echo "-> An error occurred during build. Manual update for kernel ${BRANCH_linux_kernel} is required"
    fi
    exit "${exit_code}"
}

trap 'exit_launcher' 0 1 2 3 6 15

QUBES_VERSION_TO_UPDATE="$("$LOCALDIR"/github-updater.py --repo qubes-linux-kernel --check-update --base "$GIT_UPSTREAM:${BRANCH_linux_kernel:-master}")"
if [ -n "$QUBES_VERSION_TO_UPDATE" ]; then
    FC_LATEST="$(git ls-remote --heads https://src.fedoraproject.org/rpms/fedora-release | grep -Po "refs/heads/f[0-9][1-9]*" | sed 's#refs/heads/f##g' | sort -g | tail -1)"

    git clone "${GIT_BASEURL_UPSTREAM}/${GIT_PREFIX_UPSTREAM}builder-rpm" "$BUILDERRPMDIR"
    git clone -b "${BRANCH_linux_kernel}" "${GIT_BASEURL_UPSTREAM}/${GIT_PREFIX_UPSTREAM}linux-kernel" "$KERNELDIR"
    cd "$KERNELDIR"

    echo "$QUBES_VERSION_TO_UPDATE" > version
    make get-sources

    STABLE_KERNEL="$(dnf -q repoquery kernel --disablerepo=* --enablerepo=fedora --enablerepo=updates --releasever="$FC_LATEST" | sort -V | tail -1 | cut -d ':' -f2 | cut -d '-' -f1)"
    if [ "$BRANCH" == "main" ]; then
        TESTING_KERNEL="$(dnf -q repoquery kernel --disablerepo=* --enablerepo=fedora --enablerepo=updates --enablerepo=updates-testing --releasever="$FC_LATEST" | sort -V | tail -1 | cut -d ':' -f2 | cut -d '-' -f1)"
        RAWHIDE_KERNEL="$(dnf -q repoquery kernel --disablerepo=* --enablerepo=fedora --enablerepo=updates --releasever=rawhide | grep -v "rc[0-9]*" | sort -V | tail -1 | cut -d ':' -f2 | cut -d '-' -f1 || true)"
    fi

    if [ "$BRANCH" == "main" ] && { distance_version "$TESTING_KERNEL" "$QUBES_VERSION_TO_UPDATE"; }; then
        "$KERNELDIR/get-fedora-latest-config" --releasever "$FC_LATEST" --include-testing
        mv config-base-"$TESTING_KERNEL" config-base
    elif [ "$BRANCH" == "main" ] && { distance_version "$RAWHIDE_KERNEL" "$QUBES_VERSION_TO_UPDATE"; }; then
        "$KERNELDIR/get-fedora-latest-config" --releasever rawhide
        mv config-base-"$RAWHIDE_KERNEL" config-base
    elif distance_version "$STABLE_KERNEL" "$QUBES_VERSION_TO_UPDATE"; then
        "$KERNELDIR/get-fedora-latest-config" --releasever "$FC_LATEST"
        mv config-base-"$STABLE_KERNEL" config-base
    else
        echo "Cannot determine latest config for kernel ${LATEST_KERNEL_VERSION}. Use the current existing config..."
    fi

    if [ -n "$(git -C "$KERNELDIR" diff version)" ]; then
        LATEST_KERNEL_VERSION="$(cat version)"
        HEAD_BRANCH="update-v$QUBES_VERSION_TO_UPDATE"
        git checkout -b "$HEAD_BRANCH"
        echo 1 >rel
        git add version rel config-base
        git commit -m "Update to kernel-$QUBES_VERSION_TO_UPDATE"
        git remote add fork "${GIT_BASEURL_FORK}${GIT_PREFIX_FORK}linux-kernel"
        git push -f -u fork "$HEAD_BRANCH"

        # use local git for changelog
        if [ ! -e ~/linux ]; then
            git -C ~/ clone https://git.kernel.org/pub/scm/linux/kernel/git/stable/linux.git
        fi
        git -C ~/linux remote set-url origin https://git.kernel.org/pub/scm/linux/kernel/git/stable/linux.git
        git -C ~/linux pull --all
#        printf "<details>\n\n[Changes since previous version](https://github.com/gregkh/linux/compare/v%s...v%s):\n" "${QUBES_VERSION_TO_UPDATE}" "${LATEST_KERNEL_VERSION}" > changelog
        printf "<details>\n\nChanges since previous version:\n" > changelog
        git -C ~/linux log --oneline "v${QUBES_VERSION_TO_UPDATE}..v${LATEST_KERNEL_VERSION}" --pretty='format:gregkh/linux@%h %s' >> changelog
        printf "\n\n</details>" >> changelog

        "$LOCALDIR/github-updater.py" \
            --create-pullrequest \
            --repo qubes-linux-kernel \
            --base "$GIT_UPSTREAM:${BRANCH_linux_kernel:-master}" \
            --head "$GIT_FORK:$HEAD_BRANCH" \
            --changelog changelog
    fi
fi
