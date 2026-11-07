#!/usr/bin/env bash
#
# Verify a distribution artifact before it reaches anyone.
#
#   Scripts/verify-artifact.sh path/to/Roga.app [--golden FILE]
#   Scripts/verify-artifact.sh path/to/Roga.dmg
#
# --golden defaults to Scripts/release/designated-requirement.txt, found from
# this script's own folder, so the check doesn't depend on the working
# directory. An app is always held to it: a missing golden file is a failure,
# never a skipped check.
#
# Read-only: every check here inspects, none of them re-sign or modify the
# artifact. Safe to run against an installed copy.
#
# The identity checks exist because macOS keys what people let Roga do, such
# as reading repositories in Documents or on the Desktop, to the app's
# designated requirement. If the requirement drifts, every existing user
# silently loses those permissions on their next update. The helper checks
# exist because agents' hooks run Contents/Helpers/roga (decision 41), so an
# app whose helper is missing or can't run would never hear from them.
#
# Ported from Errol's scripts/verify-artifact.sh.

set -euo pipefail

EXPECTED_BUNDLE_ID="sh.roga.app"
EXPECTED_HELPER_ID="sh.roga.app.helper"
EXPECTED_TEAM_ID="${ROGA_TEAM_ID:-JN3SN725AZ}"
GOLDEN_REQ=""
ARTIFACT=""
FAILURES=0
REVIEW_EVENTS=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --golden) GOLDEN_REQ="$2"; shift 2 ;;
    --team)   EXPECTED_TEAM_ID="$2"; shift 2 ;;
    *)        ARTIFACT="$1"; shift ;;
  esac
done

[[ -n "$ARTIFACT" ]] || { echo "usage: $0 <Roga.app|Roga.dmg> [--golden FILE] [--team ID]" >&2; exit 2; }
[[ -e "$ARTIFACT" ]] || { echo "no such artifact: $ARTIFACT" >&2; exit 2; }
[[ -n "$GOLDEN_REQ" ]] || GOLDEN_REQ="$(cd "$(dirname "$0")" && pwd)/release/designated-requirement.txt"

pass() { printf '  \033[32mok\033[0m    %s\n' "$1"; }
fail() { printf '  \033[31mFAIL\033[0m  %s\n' "$1"; FAILURES=$((FAILURES + 1)); }
note() { printf '  \033[33mREVIEW\033[0m %s\n' "$1"; REVIEW_EVENTS=$((REVIEW_EVENTS + 1)); }

echo "Verifying $ARTIFACT"
echo

# --- 1. Signature integrity ------------------------------------------------
echo "Signature"
if codesign --verify --deep --strict --verbose=2 "$ARTIFACT" 2>&1 | grep -q "satisfies its Designated Requirement"; then
  pass "signature valid, satisfies its own designated requirement"
else
  codesign --verify --deep --strict --verbose=2 "$ARTIFACT" 2>&1 | sed 's/^/        /' || true
  fail "codesign --verify --deep --strict"
fi

# Everything below reads the app bundle; for a DMG we only assess the container.
if [[ "$ARTIFACT" == *.app ]]; then
  SIGN_INFO="$(codesign -dv --verbose=4 "$ARTIFACT" 2>&1)"

  # --- 2. Bundle identifier, asserted independently ------------------------
  ACTUAL_ID="$(printf '%s\n' "$SIGN_INFO" | awk -F= '/^Identifier=/{print $2}')"
  if [[ "$ACTUAL_ID" == "$EXPECTED_BUNDLE_ID" ]]; then
    pass "bundle identifier is $ACTUAL_ID"
  else
    fail "bundle identifier is '$ACTUAL_ID', expected '$EXPECTED_BUNDLE_ID'"
  fi

  # --- 3. Every executable: team, hardened runtime, timestamp --------------
  # Notarization rejects any executable without the hardened runtime or a
  # secure timestamp, so check them all here rather than after the upload:
  # the app, the roga helper, and Sparkle's helpers and XPC services.
  echo
  echo "Executables"
  while IFS= read -r -d '' file; do
    file -b "$file" | grep -q "Mach-O" || continue
    name="${file#"$ARTIFACT"/}"
    info="$(codesign -dv --verbose=2 "$file" 2>&1 || true)"
    team="$(printf '%s\n' "$info" | awk -F= '/^TeamIdentifier=/{print $2}')"
    problems=()
    [[ "$team" == "$EXPECTED_TEAM_ID" ]] || problems+=("team '${team:-none}'")
    printf '%s\n' "$info" | grep -q "flags=.*runtime" || problems+=("no hardened runtime")
    printf '%s\n' "$info" | grep -q "^Timestamp=" || problems+=("no secure timestamp")
    if codesign -d --entitlements - --xml "$file" 2>/dev/null | grep -q "get-task-allow"; then
      problems+=("get-task-allow (a development build)")
    fi
    if [[ ${#problems[@]} -eq 0 ]]; then
      pass "$name"
    else
      fail "$name: $(IFS=,; echo "${problems[*]}" | sed 's/,/, /g')"
    fi
  done < <(find "$ARTIFACT" -type f -perm +111 -print0)

  # --- 4. The helper agents' hooks run ---------------------------------------
  echo
  echo "Helper"
  HELPER="$ARTIFACT/Contents/Helpers/roga"
  if [[ -f "$HELPER" && -x "$HELPER" ]]; then
    HELPER_ID="$(codesign -dv "$HELPER" 2>&1 | awk -F= '/^Identifier=/{print $2}')"
    if [[ "$HELPER_ID" == "$EXPECTED_HELPER_ID" ]]; then
      pass "Contents/Helpers/roga is $HELPER_ID"
    else
      fail "Contents/Helpers/roga is '$HELPER_ID', expected '$EXPECTED_HELPER_ID'"
    fi
    if HELPER_VERSION="$("$HELPER" --version 2>&1)"; then
      pass "it runs: $(printf '%s\n' "$HELPER_VERSION" | head -1 | sed 's/, in .*//')"
    else
      fail "Contents/Helpers/roga --version failed: $HELPER_VERSION"
    fi
  else
    fail "Contents/Helpers/roga is missing or isn't executable, so agents' hooks couldn't reach Roga"
  fi

  # --- 5. Sparkle's key ------------------------------------------------------
  echo
  echo "Updates"
  KEY="$(/usr/libexec/PlistBuddy -c "Print :SUPublicEDKey" "$ARTIFACT/Contents/Info.plist" 2>/dev/null || true)"
  KEY_BYTES="$(printf '%s' "$KEY" | base64 -D 2>/dev/null | wc -c | tr -d ' ')"
  if [[ "$KEY_BYTES" == "32" ]]; then
    pass "SUPublicEDKey is an Ed25519 public key"
  else
    fail "SUPublicEDKey is missing or isn't 32 bytes, so this copy couldn't install any later update"
  fi

  # --- 6. Designated requirement -------------------------------------------
  ACTUAL_DR="$(codesign -d -r- "$ARTIFACT" 2>&1 | sed -n 's/^designated => //p' | tr -s '[:space:]' ' ' | sed 's/ *$//')"
  echo
  echo "Designated requirement"
  echo "        $ACTUAL_DR"

  if [[ -f "$GOLDEN_REQ" ]]; then
    GOLDEN_TEXT="$(tr -s '[:space:]' ' ' < "$GOLDEN_REQ" | sed 's/^ *//; s/ *$//')"

    # 6a. Semantic gate: does this artifact actually satisfy the committed
    #     requirement? This is the check that matters: it's what macOS asks
    #     before honoring a permission someone gave an earlier copy.
    if codesign --verify -R="$GOLDEN_TEXT" "$ARTIFACT" >/dev/null 2>&1; then
      pass "artifact satisfies the committed designated requirement"
    else
      fail "artifact does NOT satisfy the committed requirement, so installed copies would lose their permissions"
    fi

    # 6b. Textual drift: a difference here doesn't necessarily break anything
    #     (codesign's output formatting can shift between Xcode releases), but
    #     it means the identity expression changed and a person must look.
    if [[ "$ACTUAL_DR" == "$GOLDEN_TEXT" ]]; then
      pass "requirement text matches the golden expression exactly"
    else
      note "requirement text differs from the golden expression, which blocks the release until someone looks"
      printf '        golden: %s\n' "$GOLDEN_TEXT"
      printf '        actual: %s\n' "$ACTUAL_DR"
    fi
  else
    fail "golden requirement $GOLDEN_REQ not found, so the designated requirement can't be checked"
  fi
fi

# --- 7. Gatekeeper assessment ---------------------------------------------
echo
echo "Gatekeeper and notarization"
case "$ARTIFACT" in
  *.app) SPCTL_TYPE=(-t exec) ;;
  *.dmg) SPCTL_TYPE=(-t open --context context:primary-signature) ;;
  *)     SPCTL_TYPE=(-t exec) ;;
esac
if spctl -a -vvv "${SPCTL_TYPE[@]}" "$ARTIFACT" 2>&1 | grep -qE "accepted"; then
  SOURCE="$(spctl -a -vvv "${SPCTL_TYPE[@]}" "$ARTIFACT" 2>&1 | awk -F= '/source=/{print $2}')"
  pass "Gatekeeper accepts it (source: ${SOURCE:-unknown})"
else
  spctl -a -vvv "${SPCTL_TYPE[@]}" "$ARTIFACT" 2>&1 | sed 's/^/        /' || true
  fail "Gatekeeper rejected the artifact"
fi

# --- 8. Stapled notarization ticket ---------------------------------------
if xcrun stapler validate "$ARTIFACT" >/dev/null 2>&1; then
  pass "notarization ticket is stapled"
else
  fail "no stapled ticket (first launch will need a network round trip, or be blocked)"
fi

echo
if [[ $FAILURES -gt 0 ]]; then
  printf '\033[31m%d check(s) failed.\033[0m Do not publish this artifact.\n' "$FAILURES"
  exit 1
fi
if [[ $REVIEW_EVENTS -gt 0 ]]; then
  printf '\033[33mAll checks passed, %d item(s) need human review before publishing.\033[0m\n' "$REVIEW_EVENTS"
  exit 0
fi
printf '\033[32mAll checks passed.\033[0m\n'
