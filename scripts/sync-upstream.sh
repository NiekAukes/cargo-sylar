#!/usr/bin/env bash
# Pull upstream cargo-oxide changes from NVIDIA/cuda-rust into this fork.
#
#   1. fetch the monorepo's upstream branch
#   2. re-split cuda-oxide/crates/cargo-oxide (same history -> same hashes)
#   3. merge the split into the current branch
#   4. bump the `rev` of the NVIDIA/cuda-rust git dependencies to the same
#      monorepo commit, so cargo-oxide and its sibling crates stay in lockstep
#   5. cargo check, then commit the bump
#
# If the merge conflicts, resolve and commit it, then run this script again:
# the split and merge become no-ops and it continues with the rev bump.
#
# Environment overrides:
#   MONOREPO         path to the cuda-rust checkout   (default: ../cuda-rust)
#   UPSTREAM_REMOTE  remote in MONOREPO to fetch      (default: origin)
#   UPSTREAM_BRANCH  branch on that remote            (default: main)
#   SPLIT_BRANCH     local split branch in MONOREPO   (default: cargo-oxide-split)

set -euo pipefail

FORK=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
cd "$FORK"

MONOREPO=${MONOREPO:-$FORK/../cuda-rust}
UPSTREAM_REMOTE=${UPSTREAM_REMOTE:-origin}
UPSTREAM_BRANCH=${UPSTREAM_BRANCH:-main}
SPLIT_BRANCH=${SPLIT_BRANCH:-cargo-oxide-split}
PREFIX=cuda-oxide/crates/cargo-oxide
GIT_URL=https://github.com/NVIDIA/cuda-rust

die() { echo "error: $*" >&2; exit 1; }

[ -d "$MONOREPO/.git" ] || die "no monorepo checkout at $MONOREPO (set MONOREPO)"
[ -z "$(git status --porcelain)" ] || die "working tree is not clean"
[ ! -f "$(git rev-parse --git-path MERGE_HEAD)" ] || die "a merge is in progress; finish it first"

echo "==> fetching $UPSTREAM_REMOTE/$UPSTREAM_BRANCH in $MONOREPO"
git -C "$MONOREPO" fetch "$UPSTREAM_REMOTE" "$UPSTREAM_BRANCH"
REV=$(git -C "$MONOREPO" rev-parse "refs/remotes/$UPSTREAM_REMOTE/$UPSTREAM_BRANCH")
echo "    upstream is at $REV"

echo "==> splitting $PREFIX (slow on the first run)"
git -C "$MONOREPO" subtree split -q --prefix="$PREFIX" "$REV" -b "$SPLIT_BRANCH" >/dev/null

echo "==> merging $SPLIT_BRANCH"
git fetch --quiet monorepo "$SPLIT_BRANCH"
if ! git merge --no-edit -m "Merge upstream cargo-oxide at NVIDIA/cuda-rust@${REV:0:12}" \
        "monorepo/$SPLIT_BRANCH"; then
    echo >&2
    echo "Merge conflicts. Resolve them, 'git commit', then rerun $0." >&2
    exit 1
fi

if grep -nE '(\.workspace|workspace) = true' Cargo.toml; then
    echo >&2
    echo "Upstream added workspace-inherited entries (above). Replace them with" >&2
    echo "explicit values or { git = \"$GIT_URL\", rev = \"...\" }, commit, and rerun." >&2
    exit 1
fi

echo "==> pinning $GIT_URL dependencies to $REV"
sed -i -E "/git = \"${GIT_URL//\//\\/}\"/ s/rev = \"[0-9a-f]+\"/rev = \"$REV\"/" Cargo.toml
if git diff --quiet Cargo.toml; then
    echo "    already pinned"
else
    cargo update --quiet --workspace
    echo "==> cargo check"
    cargo check --all-targets
    git commit --quiet -m "Pin NVIDIA/cuda-rust dependencies to ${REV:0:12}" Cargo.toml Cargo.lock
    echo "    committed"
fi

channel() { sed -nE 's/^channel = "([^"]+)"/\1/p'; }
UPSTREAM_CHANNEL=$(git -C "$MONOREPO" show "$REV:cuda-oxide/rust-toolchain.toml" | channel)
FORK_CHANNEL=$(channel < rust-toolchain.toml)
if [ "$UPSTREAM_CHANNEL" != "$FORK_CHANNEL" ]; then
    echo "warning: upstream toolchain is $UPSTREAM_CHANNEL, rust-toolchain.toml pins $FORK_CHANNEL" >&2
fi

echo "==> done. Run 'cargo test' to validate."
