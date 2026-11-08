#!/bin/sh
# Builds a history with the shapes a replay has to work out, for testing it
# against something where the right answer is known: a run with no branches, a
# merged pull request, a back-merge of main into a branch, a squashed pull
# request, GitLab's and Bitbucket's merge messages, and two "foxtrot" merges
# where main is the second parent, one that says so and one that doesn't. Every
# name and date is fixed, so the object IDs are the same on every run.
#
# Usage: replay.sh <folder>
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

# commit <variable> <ref> <hours> <message> [<parent mark>...]
# Prints a commit for fast-import and sets <variable> to its mark.
commit() {
    variable=$1 ref=$2 time=$((start + $3 * hour)) message=$4
    shift 4
    mark=$((mark + 1))
    eval "$variable=$mark"
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

body='
'

{
    # A flat run, with no branch open.
    commit m1 refs/heads/main 0 "Initial commit"
    commit m2 refs/heads/main 1 "Add the readme" "$m1"
    commit m3 refs/heads/main 2 "Add a license" "$m2"
    commit m4 refs/heads/main 3 "Add the build script" "$m3"
    commit m5 refs/heads/main 4 "Add the tests" "$m4"
    commit m6 refs/heads/main 5 "Set up CI" "$m5"
    commit m7 refs/heads/main 6 "Add the docs" "$m6"
    printf 'reset refs/tags/flat\nfrom :%d\n\n' "$m7"

    # A pull request, merged while main moved on.
    commit login1 refs/heads/add-login 7 "Start the login page" "$m7"
    commit login2 refs/heads/add-login 8 "Finish the login page" "$login1"
    commit m8 refs/heads/main 9 "Tidy the config" "$m7"
    commit pr1 refs/heads/main 10 "Merge pull request #1 from ana/add-login$body${body}Add a login page" "$m8" "$login2"

    # A branch that merges main into itself before its pull request lands.
    commit refactor1 refs/heads/refactor 11 "Split the router" "$pr1"
    commit m9 refs/heads/main 12 "Bump the version" "$pr1"
    commit back refs/heads/refactor 13 "Merge branch 'main' into refactor" "$refactor1" "$m9"
    commit refactor2 refs/heads/refactor 14 "Finish the router" "$back"
    commit pr2 refs/heads/main 15 "Merge pull request #2 from ana/refactor$body${body}Refactor the router" "$m9" "$refactor2"

    # A squashed pull request, and the other forges' merges.
    commit squash refs/heads/main 16 "Fix the header (#3)" "$pr2"
    commit search refs/heads/search 17 "Start the search" "$squash"
    commit gitlab refs/heads/main 18 "Merge branch 'search' into 'main'" "$squash" "$search"
    commit export refs/heads/export 19 "Start the export" "$gitlab"
    commit bitbucket refs/heads/main 20 "Merged in export (pull request #12)" "$gitlab" "$export"

    # Someone pulled main into their branch and pushed the result, so main is
    # the second parent, and the message says so.
    commit sidebar refs/heads/sidebar 21 "Work on the sidebar" "$bitbucket"
    commit m10 refs/heads/main 22 "Update the changelog" "$bitbucket"
    commit fox refs/heads/main 23 "Merge branch 'main' of github.com:ana/app" "$sidebar" "$m10"

    # The same again, with a message that doesn't say, but with the pull
    # requests on the second parent's side.
    commit layout1 refs/heads/layout 24 "Try a new layout" "$fox"
    commit layout2 refs/heads/layout 25 "Polish the layout" "$layout1"
    commit avatars refs/heads/avatars 24 "Add avatars" "$fox"
    commit pr4 refs/heads/main 25 "Merge pull request #4 from ana/avatars$body${body}Show avatars" "$fox" "$avatars"
    commit themes refs/heads/main 26 "Add themes (#5)" "$pr4"
    commit sync refs/heads/main 27 "Sync the layout work" "$layout2" "$themes"

    commit m11 refs/heads/main 28 "Release 1.0" "$sync"

    # A repository's worth of squashes, on a branch of their own.
    commit s1 refs/heads/squashes 0 "First (#1)"
    commit s2 refs/heads/squashes 1 "Second (#2)" "$s1"
    commit s3 refs/heads/squashes 2 "Third (#3)" "$s2"

    # Commits from a machine whose clock was far behind, on top of recent ones.
    # Walking newest first reaches them before the recent commit under them.
    commit q0 refs/heads/skewed 1000 "Older work"
    commit q1 refs/heads/skewed 1100 "Recent base" "$q0"
    commit q2 refs/heads/skewed 1101 "Recent follow-up" "$q1"
    commit o1 refs/heads/old-clock 200 "Old clock 1" "$q1"
    commit o2 refs/heads/old-clock 201 "Old clock 2" "$o1"
    commit o3 refs/heads/old-clock 202 "Old clock 3" "$o2"
    commit o4 refs/heads/old-clock 203 "Old clock 4" "$o3"
    commit o5 refs/heads/old-clock 204 "Old clock 5" "$o4"
    commit o6 refs/heads/old-clock 205 "Old clock 6" "$o5"
    commit q3 refs/heads/skewed 1110 "Merge branch 'old-clock'" "$q2" "$o6"

    # A merge whose first parent is older than a range and whose second isn't.
    commit a0 refs/heads/lost 300 "Old main"
    commit b0 refs/heads/side 1100 "Side work"
    commit b1 refs/heads/side 1101 "More side work" "$b0"
    commit x0 refs/heads/lost 1102 "Merge branch 'side'" "$a0" "$b1"
    commit y0 refs/heads/lost 1103 "After the merge" "$x0"
} > commits

git init --quiet --initial-branch=main .
git fast-import --quiet --force < commits
rm commits
git commit-graph write --reachable --no-progress
