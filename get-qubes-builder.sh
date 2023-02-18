#!/bin/bash -e

# Originally from QubesOS/qubes-builderv2-github

LOCALDIR="$(readlink -f "$(dirname "$0")")"

if [ "$DEBUG" == 1 ]; then
    set -x
fi

keyring_path="$LOCALDIR/builder-maintainers-keyring"

usage() {
    echo "Usage: $0 builder-dir" >&2
}

verify_git_obj() {
    local content newsig_number
    export GNUPGHOME="$keyring_path"
    content=$(git -c gpg.program=gpg -c gpg.minTrustLevel=fully "verify-$1" --raw -- "$2" 2>&1 >/dev/null) &&
        newsig_number=$(printf %s\\n "$content" | grep -c '^\[GNUPG:] NEWSIG') &&
        [ "$newsig_number" = 1 ] && {
        printf %s\\n "$content" |
            grep '^\[GNUPG:] TRUST_\(FULLY\|ULTIMATE\) 0 pgp$' >/dev/null
    }
}

if [ $# -lt 1 ]; then
    usage
    exit 1
fi

set -e

BUILDER_DIR="$1"
BUILDER_URL="$2"
BUILDER_BRANCH="${3:-main}"

if [ -z "${BUILDER_DIR}" ]; then
    echo "ERROR: Please provide builder directory destination."
    exit 1
fi

if [ -z "${BUILDER_URL}" ]; then
    echo "ERROR: Please provide builder source URL."
    exit 1
fi

git clone -b "${BUILDER_BRANCH}" "$BUILDER_URL" "$BUILDER_DIR"

cd "$BUILDER_DIR" || {
    echo "ERROR: Invalid builder directory."
    exit 1
}

cur_branch="$(git branch --show-current)"
git fetch origin "$cur_branch"
if ! verify_git_obj commit FETCH_HEAD; then
    rm .git/FETCH_HEAD
    exit 1
fi

git merge --ff-only FETCH_HEAD
git submodule update --init --recursive
