#!/usr/bin/env bash
set -euo pipefail

# Read-only invariant guard (iShrink Phase 1 plan, U1 / Key Technical
# Decisions: "Read-only invariant is enforced, not just asserted").
#
# iShrinkCore requests PHAccessLevel.readWrite (the only macOS access level
# that grants full-library read), but must never actually mutate the Apple
# Photos library. This script fails the build if any PhotoKit mutation API
# shows up under Core/Sources/iShrinkCore, so that guarantee can't quietly
# erode as later units (U2+) add real code to the package.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
SEARCH_DIR="${REPO_ROOT}/Core/Sources/iShrinkCore"

FORBIDDEN_PATTERNS=(
  "PHAssetChangeRequest"
  "PHAssetCreationRequest"
  "PHAssetCollectionChangeRequest"
  "performChanges"
)

if [ ! -d "${SEARCH_DIR}" ]; then
  echo "check-readonly: ${SEARCH_DIR} does not exist yet; nothing to check." >&2
  exit 0
fi

found_violation=0

for pattern in "${FORBIDDEN_PATTERNS[@]}"; do
  matches="$(grep -rn --include='*.swift' -- "${pattern}" "${SEARCH_DIR}" || true)"
  if [ -n "${matches}" ]; then
    echo "check-readonly: FORBIDDEN mutation API '${pattern}' referenced in iShrinkCore:" >&2
    echo "${matches}" >&2
    echo >&2
    found_violation=1
  fi
done

if [ "${found_violation}" -ne 0 ]; then
  echo "check-readonly: FAILED — iShrinkCore must stay read-only against the Photos library." >&2
  echo "See plan Key Technical Decisions: 'Read-only invariant is enforced, not just asserted.'" >&2
  exit 1
fi

echo "check-readonly: OK — no PhotoKit mutation APIs found under ${SEARCH_DIR}."
exit 0
