#!/usr/bin/env bash
set -euo pipefail

# Built-artifact verifier (iShrink Homebrew distribution plan, U1).
#
# Asserts the properties of a built iShrink.app that silently break
# distribution if they regress. Every one of these has the same symptom for
# an end user — "the app doesn't work" — and none of them are visible by
# looking at the bundle, so they are checked mechanically instead:
#
#   1. The bundle has a valid code signature. Apple Silicon refuses to
#      execute arm64 code with no signature at all, so an unsigned bundle is
#      a bundle that cannot launch.
#   2. The *signed* binary carries the App Sandbox and Photos-library
#      entitlements. Entitlements live in the signature, not in the bundle,
#      so a build that drops them produces an app that launches fine and is
#      then permanently blind to the Photos library.
#   3. Both arm64 and x86_64 slices are present, so one artifact serves both
#      Apple Silicon and Intel Macs.
#
# Deliberately split out of scripts/build-app.sh so the CI release workflow
# (U3) can run the identical assertions against the artifact it produced,
# rather than re-implementing them in YAML and letting the two drift.
#
# Usage: scripts/verify-app.sh /path/to/iShrink.app

APP_PATH="${1:-}"

if [ -z "${APP_PATH}" ]; then
  echo "verify-app: usage: $0 /path/to/iShrink.app" >&2
  exit 2
fi

# Normalise to an absolute path with no trailing slash, so codesign and lipo
# both see the same bundle and error messages are unambiguous.
APP_PATH="${APP_PATH%/}"
if [ ! -d "${APP_PATH}" ]; then
  echo "verify-app: FAILED — no bundle at '${APP_PATH}'." >&2
  exit 1
fi
APP_PATH="$(cd "${APP_PATH}" && pwd)"

APP_NAME="$(basename "${APP_PATH}")"
INFO_PLIST="${APP_PATH}/Contents/Info.plist"

# The executable name comes from CFBundleExecutable, not from the bundle's
# filename. They usually match, but a bundle that has been renamed on disk
# (which is exactly what happens when someone downloads a second copy) would
# otherwise be reported as "missing its executable" when it is fine.
BINARY_NAME="$(/usr/libexec/PlistBuddy -c "Print :CFBundleExecutable" \
  "${INFO_PLIST}" 2>/dev/null || echo "")"
if [ -z "${BINARY_NAME}" ]; then
  BINARY_NAME="${APP_NAME%.app}"
fi
BINARY_PATH="${APP_PATH}/Contents/MacOS/${BINARY_NAME}"

REQUIRED_ENTITLEMENTS=(
  "com.apple.security.app-sandbox"
  "com.apple.security.personal-information.photos-library"
  # Powerbox access for the output-folder picker. Dropping this produces an
  # app whose "Choose Folder…" button silently does nothing, which is how it
  # was originally shipped — hence checking for it here.
  "com.apple.security.files.user-selected.read-write"
)

# Entitlements that must NOT be present in a bundle we hand to anyone else.
# get-task-allow lets any process attach a debugger to the running app and
# read its memory. Xcode injects it automatically for locally-signed builds,
# which is fine on your own machine and not fine in a published release, so
# build-app.sh disables the injection and this asserts it worked.
FORBIDDEN_ENTITLEMENTS=(
  "com.apple.security.get-task-allow"
)

REQUIRED_ARCHS=(
  "arm64"
  "x86_64"
)

failures=0

fail() {
  echo "verify-app: FAILED — $1" >&2
  failures=$((failures + 1))
}

echo "verify-app: checking ${APP_PATH}"

# Report the version the bundle actually claims. In a CI log this is the
# difference between "a release was published" and knowing *which* version
# was published, and it catches a version override that silently didn't take.
bundle_version="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" \
  "${APP_PATH}/Contents/Info.plist" 2>/dev/null || echo "unknown")"
bundle_build="$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" \
  "${APP_PATH}/Contents/Info.plist" 2>/dev/null || echo "unknown")"
echo "verify-app: version ${bundle_version} (build ${bundle_build})"

# --- 1. The bundle is structurally an app -----------------------------------

if [ ! -f "${INFO_PLIST}" ]; then
  fail "no Contents/Info.plist — '${APP_NAME}' is not an application bundle."
fi

if [ ! -x "${BINARY_PATH}" ]; then
  fail "no executable at Contents/MacOS/${BINARY_NAME}."
  # Nothing below can run without the binary, so stop here rather than
  # emitting a cascade of confusing follow-on errors.
  echo "verify-app: FAILED with ${failures} problem(s)." >&2
  exit 1
fi

# --- 2. Code signature ------------------------------------------------------

if codesign --verify --deep --strict "${APP_PATH}" >/dev/null 2>&1; then
  signing_identity="$(codesign --display --verbose=2 "${APP_PATH}" 2>&1 \
    | grep -E '^(Authority|Signature)=' | head -1 || true)"
  echo "verify-app: OK — valid code signature (${signing_identity:-ad-hoc})."
else
  codesign_error="$(codesign --verify --deep --strict "${APP_PATH}" 2>&1 || true)"
  fail "code signature is missing or invalid: ${codesign_error}"
fi

# --- 3. Entitlements, read back out of the signature ------------------------

# `codesign -d --entitlements` reads what was actually embedded at signing
# time. Reading App/iShrink.entitlements from disk instead would prove
# nothing — that file is the input, and the whole failure mode being guarded
# against is the input not making it into the output.
entitlements="$(codesign -d --entitlements - --xml "${APP_PATH}" 2>/dev/null \
  || codesign -d --entitlements :- "${APP_PATH}" 2>/dev/null || true)"

if [ -z "${entitlements}" ]; then
  fail "signed binary carries no entitlements at all; expected ${#REQUIRED_ENTITLEMENTS[@]}."
else
  for entitlement in "${REQUIRED_ENTITLEMENTS[@]}"; do
    if printf '%s' "${entitlements}" | grep -q -- "${entitlement}"; then
      echo "verify-app: OK — entitlement present: ${entitlement}"
    else
      fail "signed binary is missing entitlement '${entitlement}'."
    fi
  done

  for entitlement in "${FORBIDDEN_ENTITLEMENTS[@]}"; do
    if printf '%s' "${entitlements}" | grep -q -- "${entitlement}"; then
      fail "signed binary carries forbidden entitlement '${entitlement}'."
    else
      echo "verify-app: OK — entitlement absent, as required: ${entitlement}"
    fi
  done
fi

# --- 4. Architectures -------------------------------------------------------

archs="$(lipo -archs "${BINARY_PATH}" 2>/dev/null || true)"

if [ -z "${archs}" ]; then
  fail "could not read architectures from ${BINARY_PATH}."
else
  for arch in "${REQUIRED_ARCHS[@]}"; do
    # Space-pad both sides so 'arm64' cannot match inside 'arm64e'.
    if printf ' %s ' "${archs}" | grep -q -- " ${arch} "; then
      echo "verify-app: OK — architecture present: ${arch}"
    else
      fail "binary is missing the '${arch}' architecture (found: ${archs})."
    fi
  done
fi

# --- Result -----------------------------------------------------------------

if [ "${failures}" -ne 0 ]; then
  echo >&2
  echo "verify-app: FAILED with ${failures} problem(s) — this bundle must not be released." >&2
  exit 1
fi

echo "verify-app: OK — ${APP_NAME} is signed, entitled, and universal."
exit 0
