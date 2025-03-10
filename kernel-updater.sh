#!/bin/bash
# vim: set ts=4 sw=4 sts=4 et :

set -e
set -o pipefail

LOCALDIR="$(readlink -f "$(dirname "$0")")"
BUILDDIR="$(mktemp -d -p /home/user)"

GIT_UPSTREAM='QubesOS'
GIT_FORK='fepitre-bot'
GIT_BASEURL_UPSTREAM="https://github.com"
GIT_PREFIX_UPSTREAM="$GIT_UPSTREAM/qubes-"
GIT_BASEURL_FORK="git@github.com:"
GIT_PREFIX_FORK="$GIT_FORK/qubes-"

VARS='BRANCH_linux_kernel GITHUB_API_TOKEN'

# Check if necessary variables are defined in the environment
for var in $VARS; do
    if [ -z "${!var}" ]; then
        echo "Please provide $var in env"
        exit 1
    fi
done

KERNELDIR="$BUILDDIR/linux-kernel-${BRANCH_linux_kernel}"
BUILDERRPMDIR="$BUILDDIR/builder-rpm"

# Filter allowed branches
if [[ ! "${BRANCH_linux_kernel}" =~ ^stable-[0-9]+\.[0-9]+$ ]] && [ "${BRANCH_linux_kernel}" != "main" ]; then
    echo "Cannot determine kernel branch to use."
    exit 1
fi

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
    git clone "${GIT_BASEURL_UPSTREAM}/${GIT_PREFIX_UPSTREAM}builder-rpm" "$BUILDERRPMDIR"
    git clone -b "${BRANCH_linux_kernel}" "${GIT_BASEURL_UPSTREAM}/${GIT_PREFIX_UPSTREAM}linux-kernel" "$KERNELDIR"
    cd "$KERNELDIR"

    echo "$QUBES_VERSION_TO_UPDATE" > version
    make get-sources

    get_config_opts=("--keysdir=$BUILDERRPMDIR/keys" "--kerneldir=$KERNELDIR")
    if [ "$BRANCH" == "main" ]; then
        get_config_opts+=("--include-testing")
    fi

    "$LOCALDIR/get-fedora-latest-config.py" "${get_config_opts[@]}"

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
