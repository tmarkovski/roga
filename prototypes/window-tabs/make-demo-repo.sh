#!/bin/bash
# Creates a small repository whose worktrees look like several coding agents at
# work, some with uncommitted changes. It deletes and recreates the repository.
#
#   make-demo-repo.sh <folder>
set -euo pipefail

folder="$(cd "${1:?usage: make-demo-repo.sh <folder>}" && pwd)"
repo="$folder/agents-demo"
trees="$folder/agents-demo-worktrees"
rm -rf "$repo" "$trees"
mkdir -p "$repo" "$trees"

# Ignore the user's signing and hook settings, which could prompt or fail here.
git() { command git -c commit.gpgsign=false -c core.hooksPath=/dev/null "$@"; }

time=1767225600 # 2026-01-01
commit() {
    local where="$1" author="$2" file="$3" message="$4"
    mkdir -p "$where/$(dirname "$file")"
    echo "// $message" >> "$where/$file"
    git -C "$where" add "$file"
    GIT_AUTHOR_NAME="$author" GIT_AUTHOR_EMAIL="$(echo "$author" | tr -cd 'a-zA-Z').example@yaga.build" \
    GIT_COMMITTER_NAME="$author" GIT_COMMITTER_EMAIL="$(echo "$author" | tr -cd 'a-zA-Z').example@yaga.build" \
    GIT_AUTHOR_DATE="@$time +0000" GIT_COMMITTER_DATE="@$time +0000" \
        git -C "$where" commit -q -m "$message"
    time=$((time + 5400))
}

git -C "$repo" init -q -b main
commit "$repo" "Ana Kovač" README.md "Start the project"
commit "$repo" "Ana Kovač" Sources/App/main.swift "Add the app entry point"
commit "$repo" "Sam Lee" Sources/Parser/Lexer.swift "Add a lexer for the config format"
commit "$repo" "Sam Lee" Sources/Parser/Parser.swift "Parse sections and keys"
commit "$repo" "Ana Kovač" Sources/App/Login.swift "Add the login screen"
commit "$repo" "Priya Raman" Sources/Network/Client.swift "Add an HTTP client"
commit "$repo" "Priya Raman" Sources/Network/Client.swift "Retry requests that time out"
git -C "$repo" update-ref refs/tags/v0.1 HEAD
commit "$repo" "Sam Lee" Sources/Parser/Parser.swift "Report the line number in parse errors"
commit "$repo" "Ana Kovač" Sources/App/Login.swift "Remember the last user name"
commit "$repo" "Priya Raman" Sources/Network/Session.swift "Store the session token in the keychain"
commit "$repo" "Sam Lee" Sources/Parser/Lexer.swift "Handle escaped quotes"
commit "$repo" "Ana Kovač" Sources/App/Settings.swift "Add a settings window"
git -C "$repo" remote add origin https://example.com/agents-demo.git
git -C "$repo" update-ref refs/remotes/origin/main HEAD
commit "$repo" "Priya Raman" Sources/Network/Client.swift "Log slow requests"
commit "$repo" "Ana Kovač" Sources/App/Login.swift "Show an error when the password is wrong"
git -C "$repo" update-ref refs/tags/v0.2 HEAD
commit "$repo" "Sam Lee" Tests/ParserTests.swift "Add parser tests"
commit "$repo" "Ana Kovač" CHANGELOG.md "Update the changelog"

# Agent worktrees, each on its own branch.
git -C "$repo" worktree add -q -b agent/fix-login "$trees/fix-login" main~2
commit "$trees/fix-login" "Agent: fix-login" Sources/App/Login.swift "Fix the login button staying disabled"
commit "$trees/fix-login" "Agent: fix-login" Sources/App/Login.swift "Clear the password after a failed attempt"
commit "$trees/fix-login" "Agent: fix-login" Tests/LoginTests.swift "Add login tests"
echo "// Work in progress" >> "$trees/fix-login/Sources/App/Login.swift"
echo "// Work in progress" >> "$trees/fix-login/Tests/LoginTests.swift"
echo "notes" > "$trees/fix-login/NOTES.md"

git -C "$repo" worktree add -q -b agent/refactor-parser "$trees/refactor-parser" main
for step in "Split the parser into smaller functions" "Rename tokens for clarity" \
    "Remove the unused lookahead buffer" "Make parse errors a typed enum" "Update the parser tests"; do
    commit "$trees/refactor-parser" "Agent: refactor-parser" Sources/Parser/Parser.swift "$step"
done

git -C "$repo" worktree add -q -b agent/add-tests "$trees/add-tests" main
commit "$trees/add-tests" "Agent: add-tests" Tests/NetworkTests.swift "Add network client tests"
for file in Tests/NetworkTests.swift Tests/SessionTests.swift Tests/SettingsTests.swift Sources/Network/Client.swift; do
    mkdir -p "$trees/add-tests/$(dirname "$file")"
    echo "// Work in progress" >> "$trees/add-tests/$file"
done

echo "Created $repo with worktrees in $trees"
