#!/bin/bash
# Writes history.js, the commits that index.html replays, from a repository's
# history. Run it with no arguments for this repository's main branch, or name
# another repository and branch:
#
#   prototypes/history-replay/export-history.sh ~/src/some-repo main
set -euo pipefail

repo="${1:-$(git rev-parse --show-toplevel)}"
ref="${2:-main}"
out="$(cd "$(dirname "$0")" && pwd)/history.js"
name="$(basename "$(git -C "$repo" rev-parse --show-toplevel)")"
tip="$(git -C "$repo" rev-parse --short "$ref")"
sep="$(printf '\037')"
end="$(printf '\036')"

{
  printf 'window.HISTORY = {\n  "name": "%s",\n  "ref": "%s",\n  "tip": "%s",\n' "$name" "$ref" "$tip"
  printf '  // Newest first: short hash, parents, commit time, author, subject, and for\n'
  printf '  // a merge, the first line of its body, where GitHub puts the title of the pull request.\n  "commits": [\n'
  git -C "$repo" log --format="%h${sep}%p${sep}%ct${sep}%an${sep}%s${sep}%b${end}" "$ref" | awk -v RS="$end" -v FS="$sep" '
    function esc(s) { gsub(/\\/, "\\\\", s); gsub(/"/, "\\\"", s); gsub(/\t/, " ", s); return s }
    {
      sub(/^\n+/, "", $1)
      if ($1 == "") next
      body = ""
      if (index($2, " ")) { body = $6; sub(/^\n+/, "", body); sub(/\n.*/, "", body) }
      printf "%s    [\"%s\", \"%s\", %s, \"%s\", \"%s\", \"%s\"]", (n++ ? ",\n" : ""), $1, $2, $3, esc($4), esc($5), esc(body)
    }
    END { printf "\n" }'
  printf '  ]\n};\n'
} > "$out"

echo "Wrote $(git -C "$repo" rev-list --count "$ref") commits from $name $ref to $out"
