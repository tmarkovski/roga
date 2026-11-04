#!/bin/bash
# Builds a release of git from source and installs it into a folder, so that
# the tests can run against the oldest git Roga supports (decision 8).
#
# Usage: Scripts/build-git.sh <version> <sha256 of the tarball> <install folder>
#
# kernel.org lists the checksum of every release in
# https://mirrors.edge.kernel.org/pub/software/scm/git/sha256sums.asc
set -euo pipefail

usage="usage: build-git.sh <version> <sha256> <install folder>"
version="${1:?$usage}"
checksum="${2:?$usage}"
prefix="${3:?$usage}"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

tarball="$work/git-$version.tar.xz"
curl -fsSL -o "$tarball" "https://mirrors.edge.kernel.org/pub/software/scm/git/git-$version.tar.xz"
echo "$checksum  $tarball" | shasum -a 256 -c -
tar -xJf "$tarball" -C "$work"

make -C "$work/git-$version" -j"$(sysctl -n hw.ncpu)" prefix="$prefix" \
    NO_GETTEXT=YesPlease NO_TCLTK=YesPlease NO_PERL=YesPlease NO_PYTHON=YesPlease \
    install
"$prefix/bin/git" version
