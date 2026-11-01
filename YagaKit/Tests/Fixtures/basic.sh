#!/bin/sh
# Builds a small repository: three commits on main, a feature branch that
# leaves main after the second commit, and an annotated tag on the first.
# Every name and date is fixed, so the object IDs are the same on every run
# and with every git version.
#
# Usage: basic.sh <folder>
set -eu

repo="$1"

# Keep the user's and the system's configuration out, so that settings such as
# commit signing can't change the objects.
export GIT_CONFIG_NOSYSTEM=1
export GIT_CONFIG_GLOBAL=/dev/null

as() {
    export GIT_AUTHOR_NAME="$1" GIT_AUTHOR_EMAIL="$2"
    export GIT_COMMITTER_NAME="$1" GIT_COMMITTER_EMAIL="$2"
}

at() {
    export GIT_AUTHOR_DATE="$1" GIT_COMMITTER_DATE="$1"
}

git init --quiet --initial-branch=main "$repo"
cd "$repo"

as "Ana Kovač" ana@example.com
at 2026-01-01T10:00:00Z
printf 'yaga\n' > README.md
git add README.md
git commit --quiet --message "Add the readme"
git tag --annotate v0.1 --message "First release"

at 2026-01-02T10:00:00Z
mkdir src
printf 'one\n' > src/app.txt
git add src/app.txt
git commit --quiet --message "Add the app"
git branch feature

at 2026-01-03T10:00:00Z
printf 'one\ntwo\n' > src/app.txt
git commit --quiet --all --message "Change the app" --message "The body says why."

git switch --quiet feature
as "Sam Lee" sam@example.com
at 2026-01-04T10:00:00Z
printf 'notes\n' > NOTES.md
git add NOTES.md
git commit --quiet --message "Add notes"
git switch --quiet main
