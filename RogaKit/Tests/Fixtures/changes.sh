#!/bin/sh
# Builds a repository whose commits change files in every way a commit can.
# Each commit has a tag that says what it does. Every name and date is fixed,
# so the object IDs are the same on every run and with every git version.
#
# Usage: changes.sh <folder>
set -eu

repo="$1"

# Keep the user's and the system's configuration out, so that settings such as
# commit signing can't change the objects.
export GIT_CONFIG_NOSYSTEM=1
export GIT_CONFIG_GLOBAL=/dev/null
export GIT_AUTHOR_NAME="Ana Kovač" GIT_AUTHOR_EMAIL=ana@example.com
export GIT_COMMITTER_NAME="Ana Kovač" GIT_COMMITTER_EMAIL=ana@example.com

at() {
    export GIT_AUTHOR_DATE="$1" GIT_COMMITTER_DATE="$1"
}

git init --quiet --initial-branch=main "$repo"
cd "$repo"

at 2026-02-01T10:00:00Z
printf 'one\ntwo\nthree\nfour\nfive\nsix\n' > moved.txt
printf 'keep\n' > 'with space.txt'
printf '\000\001\002' > image.bin
printf '#!/bin/sh\n' > run.sh
printf '*.opaque -diff\n' > .gitattributes
printf 'one\n' > notes.opaque
mkdir src
printf 'gone\n' > src/gone.txt
printf 'link target\n' > kind.txt
printf 'tab\n' > "src/a	tab.txt"
printf 'star\n' > 'star*.txt'
printf 'starry\n' > starry.txt
git add .
git commit --quiet --message "Add the files"
git tag root

at 2026-02-02T10:00:00Z
mkdir lib
git mv moved.txt lib/moved.txt
printf 'seven\n' >> lib/moved.txt
printf 'more\n' >> 'with space.txt'
printf '\003' >> image.bin
chmod +x run.sh
printf 'two\n' > notes.opaque
git rm --quiet src/gone.txt
printf 'new\nfile\n' > src/new.txt
rm kind.txt
ln -s run.sh kind.txt
git add .
git commit --quiet --message "Change files in every way"
git tag every-way

at 2026-02-03T10:00:00Z
git switch --quiet --create side root
printf 'side\n' > side.txt
git add .
git commit --quiet --message "Add a file on the side"

at 2026-02-04T10:00:00Z
git switch --quiet main
git merge --quiet --no-ff --no-edit side
git tag merge

at 2026-02-05T10:00:00Z
git commit --quiet --allow-empty --message "Change nothing"
git tag empty
