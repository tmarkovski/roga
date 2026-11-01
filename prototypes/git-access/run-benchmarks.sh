#!/usr/bin/env bash
# Runs every git-bench benchmark against one repository and prints a combined report.
#
# Usage: run-benchmarks.sh <repo> <diff-from> <diff-to>
#
# This deletes and rewrites the repository's commit-graph file, which is a cache that git
# can always rebuild. Point it at a clone made for benchmarking, not at your own work.
set -euo pipefail

repo="$(cd "${1:?usage: run-benchmarks.sh <repo> <diff-from> <diff-to>}" && pwd)"
from="${2:?missing diff-from}"
to="${3:?missing diff-to}"
here="$(cd "$(dirname "$0")" && pwd)"

swift build -c release --package-path "$here" -q 2>/dev/null
bench="$here/.build/release/git-bench"
git_dir="$(git -C "$repo" rev-parse --absolute-git-dir)"
graph="$git_dir/objects/info/commit-graph"

echo "machine: $(sysctl -n machdep.cpu.brand_string), $(($(sysctl -n hw.memsize) / 1073741824)) GB, macOS $(sw_vers -productVersion)"
echo "git: $(git --version), libgit2: $(pkg-config --modversion libgit2)"
echo "repository: $(basename "$repo") at $(git -C "$repo" rev-parse --short HEAD), $(git -C "$repo" ls-files | wc -l | tr -d ' ') tracked files"
echo

echo "# History without a commit-graph file"
echo
rm -f "$graph"
rm -rf "$git_dir/objects/info/commit-graphs"
"$bench" log-cli --repo "$repo" --order default
"$bench" log-cli --repo "$repo" --order date
"$bench" log-libgit2 --repo "$repo"

echo "# Writing the commit-graph file"
echo
TIMEFORMAT="   git commit-graph write --reachable took %R s"
time git -C "$repo" commit-graph write --reachable 2>/dev/null
echo "   size: $(du -h "$graph" | cut -f1)"
echo
"$bench" verify-graph --repo "$repo" | sed 's/^/   /'
echo

echo "# History with a commit-graph file"
echo
"$bench" log-cli --repo "$repo" --order default
"$bench" log-cli --repo "$repo" --order date
"$bench" log-cli --repo "$repo" --order topo
"$bench" log-libgit2 --repo "$repo"
"$bench" log-graph --repo "$repo" --meta cat-file
"$bench" log-graph --repo "$repo" --meta libgit2

echo "# Status of a clean working tree"
echo
"$bench" status --repo "$repo" --engine cli --runs 5
"$bench" status --repo "$repo" --engine cli-fsmonitor --runs 5
git -C "$repo" fsmonitor--daemon stop >/dev/null 2>&1 || true
"$bench" status --repo "$repo" --engine libgit2 --runs 5

echo "# Full patch from $from to $to"
echo
"$bench" diff --repo "$repo" --engine cli "$from" "$to"
"$bench" diff --repo "$repo" --engine libgit2 "$from" "$to"
