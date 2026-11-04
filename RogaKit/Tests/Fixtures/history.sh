#!/bin/sh
# Builds one history five times, with its commit-graph stored in different
# ways, for testing the commit-graph reader and history order against git.
#
# The history has a long straight run, merges, an octopus merge, a merged-in
# root with unrelated history, commits with the same time on several
# branches, a child older than its parent, and a commit dated 2100 whose
# child is dated 1973, which needs git's generation overflow chunk. It's
# imported in three parts with git fast-import, so that the chains can get one
# layer for each part. Every name and date is fixed, so the object IDs are the
# same on every run and with every git version.
#
# It makes these repositories in <folder>:
#   single  one commit-graph file
#   chain   a chain of three layers, one for each part
#   mixed   a chain whose middle layer has no corrected commit dates
#   stale   one file written before the third part, which is newer
#   sha256  one commit-graph file, in a repository that uses SHA-256
#
# Usage: history.sh <folder>
set -eu

folder="$1"
mkdir -p "$folder"
cd "$folder"

export GIT_CONFIG_NOSYSTEM=1
export GIT_CONFIG_GLOBAL=/dev/null

# 2026-01-01T00:00:00Z, and an hour.
start=1767225600
hour=3600
mark=0

# commit <ref> <time> <message> [<parent mark>...]
# Prints a commit for fast-import. Every commit names its parents, so that
# the parts can be imported separately. Marks count up across the parts.
commit() {
    ref=$1 time=$2 message=$3
    shift 3
    mark=$((mark + 1))
    printf 'commit %s\nmark :%d\n' "$ref" "$mark"
    printf 'author Ana Kovac <ana@example.com> %d +0000\n' "$time"
    printf 'committer Ana Kovac <ana@example.com> %d +0000\n' "$time"
    printf 'data %d\n%s\n' "${#message}" "$message"
    if [ $# -gt 0 ]; then
        printf 'from :%d\n' "$1"
        shift
        for parent in "$@"; do printf 'merge :%d\n' "$parent"; done
    fi
    printf '\n'
}

# at <hours>: the time that many hours after the start.
at() {
    echo $((start + $1 * hour))
}

# Part 1: a straight run of 300 commits on main, a branch that leaves it and
# isn't merged until part 3, and a second root on its own branch.
{
    commit refs/heads/main "$(at 0)" "Commit 1"
    i=2
    while [ $i -le 300 ]; do
        commit refs/heads/main "$(at $i)" "Commit $i" $((mark))
        if [ $i = 100 ]; then branch_point=$mark; fi
        i=$((i + 1))
    done
    main=$mark
    printf 'reset refs/tags/base\nfrom :%d\n\n' "$main"

    commit refs/heads/old-feature "$(at 101)" "Old feature 1" "$branch_point"
    commit refs/heads/old-feature "$(at 102)" "Old feature 2" $mark
    commit refs/heads/old-feature "$(at 103)" "Old feature 3" $mark
    old_feature=$mark

    commit refs/heads/pages "$(at 50)" "Pages 1"
    commit refs/heads/pages "$(at 150)" "Pages 2" $mark
    commit refs/heads/pages "$(at 250)" "Pages 3" $mark
    pages=$mark
} > part1

# Part 2: a topic branch merged back, three branches that commit at the same
# times as each other and as main, merged together in an octopus merge, and
# the second root merged in.
{
    commit refs/heads/main "$(at 301)" "Commit 301" "$main"
    fork=$mark
    commit refs/heads/main "$(at 303)" "Commit 302" $mark
    commit refs/heads/main "$(at 305)" "Commit 303" $mark
    main=$mark
    commit refs/heads/topic-a "$(at 302)" "Topic A 1" "$fork"
    commit refs/heads/topic-a "$(at 304)" "Topic A 2" $mark
    commit refs/heads/topic-a "$(at 306)" "Topic A 3" $mark
    commit refs/heads/main "$(at 307)" "Merge topic A" "$main" $mark
    main=$mark

    for topic in b c d; do
        commit "refs/heads/topic-$topic" "$(at 310)" "Topic $topic 1" "$main"
        commit "refs/heads/topic-$topic" "$(at 311)" "Topic $topic 2" $mark
        eval "topic_$topic=\$mark"
    done
    commit refs/heads/main "$(at 310)" "Commit 304" "$main"
    commit refs/heads/main "$(at 311)" "Commit 305" $mark
    commit refs/heads/main "$(at 312)" "Merge topics B, C and D" $mark "$topic_b" "$topic_c" "$topic_d"
    commit refs/heads/main "$(at 313)" "Merge the pages" $mark "$pages"
    main=$mark
} > part2

# Part 3: the old branch merged at last, a child older than its parent, and
# the branch dated 2100 and 1973.
{
    commit refs/heads/main "$(at 320)" "Merge the old feature" "$main" "$old_feature"
    commit refs/heads/main "$(at 322)" "Commit 306" $mark
    commit refs/heads/main "$(at 321)" "Commit 307, older than its parent" $mark
    commit refs/heads/main "$(at 323)" "Commit 308" $mark
    printf 'tag v1.0\nfrom :%d\ntagger Ana Kovac <ana@example.com> %d +0000\ndata 7\nRelease\n' $mark "$(at 324)"

    commit refs/heads/future 4102444800 "Dated 2100" 200
    commit refs/heads/future 100000000 "Dated 1973" $mark
    commit refs/heads/future "$(at 325)" "Dated 2026" $mark
} > part3

# import <repository> <part>
import() {
    marks="$PWD/$1.marks"
    touch "$marks"
    git -C "$1" fast-import --quiet --force --import-marks="$marks" --export-marks="$marks" < "$2"
}

new() {
    git init --quiet --initial-branch=main "$@"
}

new single
import single part1
import single part2
import single part3
git -C single commit-graph write --reachable --no-progress

new chain
import chain part1
git -C chain commit-graph write --reachable --split=no-merge --no-progress
import chain part2
git -C chain commit-graph write --reachable --split=no-merge --no-progress
import chain part3
git -C chain commit-graph write --reachable --split=no-merge --no-progress

new mixed
import mixed part1
git -C mixed commit-graph write --reachable --split=no-merge --no-progress
import mixed part2
git -C mixed -c commitGraph.generationVersion=1 commit-graph write --reachable --split=no-merge --no-progress
import mixed part3
git -C mixed commit-graph write --reachable --split=no-merge --no-progress

new stale
import stale part1
import stale part2
git -C stale commit-graph write --reachable --no-progress
import stale part3

new --object-format=sha256 sha256
import sha256 part1
import sha256 part2
import sha256 part3
git -C sha256 commit-graph write --reachable --no-progress

rm part1 part2 part3 ./*.marks
