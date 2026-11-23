#!/bin/bash
# Makes the repositories a launch-time test copy of Roga lists in its sidebar.
#
#   Scripts/launch-time/fixture.sh <folder> <small repository> [<medium> [<large>]]
#
# Roga writes commit-graph files into the repositories it shows, so the test
# lists clones rather than the originals. `git clone` from a local folder
# links the objects rather than copying them, so even a clone of Linux takes
# only as long as checking out its files.
#
# The list is shaped like a sidebar that's been used for a while: 16
# repositories, three of them expanded, and the first with three linked
# worktrees, as agents would leave it.
#
#   roga          a clone of <small>, expanded, with worktrees agent-1 to agent-3
#   small-01..13  clones of <small>, collapsed except small-01 and small-02
#   medium        a clone of <medium>, if given, collapsed
#   large         a clone of <large>, if given, collapsed
#
# Every clone's origin is removed, so that nothing reaches the network. It
# writes <folder>/repositories.json, which measure.sh gives the test copy, and
# which selects the main worktree of roga. measure.sh can select another.
set -euo pipefail

folder=$1
small=$(cd "$2" && pwd)
medium=${3:+$(cd "$3" && pwd)}
large=${4:+$(cd "$4" && pwd)}

mkdir -p "$folder"
folder=$(cd "$folder" && pwd)

clone() {
    local from=$1 to=$2
    if [[ -d "$to" ]]; then return; fi
    echo "Cloning $from into $to"
    git clone --quiet "$from" "$to"
    git -C "$to" remote remove origin
}

clone "$small" "$folder/roga"
for n in 1 2 3; do
    if [[ ! -d "$folder/roga-worktrees/agent-$n" ]]; then
        git -C "$folder/roga" worktree add --quiet -b "agent-$n" "$folder/roga-worktrees/agent-$n"
    fi
done
for n in $(seq -w 1 13); do
    clone "$small" "$folder/small-$n"
done
if [[ -n $medium ]]; then clone "$medium" "$folder/medium"; fi
if [[ -n $large ]]; then clone "$large" "$folder/large"; fi

python3 - "$folder" <<'EOF'
import json, os, sys

folder = sys.argv[1]
names = ["roga"] + [f"small-{n:02d}" for n in range(1, 14)]
names += [name for name in ("medium", "large") if os.path.isdir(os.path.join(folder, name))]
expanded = {"roga", "small-01", "small-02"}
contents = {
    "version": 1,
    "repositories": [
        {"path": os.path.join(folder, name, ".git"), "isExpanded": name in expanded}
        for name in names
    ],
    "lastSelection": {
        "repository": os.path.join(folder, "roga", ".git"),
        "worktree": os.path.join(folder, "roga"),
    },
}
with open(os.path.join(folder, "repositories.json"), "w") as file:
    json.dump(contents, file, indent=2)
print(f"Wrote {os.path.join(folder, 'repositories.json')} with {len(names)} repositories")
EOF
