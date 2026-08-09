#!/usr/bin/env bash
set -euo pipefail

# Local build-and-install (iShrink Homebrew distribution plan, U1).
#
# Turns a checkout into a running /Applications/iShrink.app with one command
# and no Xcode GUI interaction. This is both the immediate escape hatch for
# a maintainer who does not want to drive Xcode, and the permanent fallback
# if the Homebrew route (U3/U4) ever stops being viable.
#
# The CI release workflow (U3) runs this same script with --no-install, so
# the local and released bundles are produced by one code path rather than
# two that quietly diverge.
#
# Signing note: the app is ad-hoc signed (`CODE_SIGN_IDENTITY=-`), not left
# unsigned. Apple Silicon refuses to execute arm64 code with no signature at
# all, so ad-hoc signing is the minimum for the app to launch — it is not an
# optional hardening step. An ad-hoc signature identifies exactly one build,
# which is why macOS re-asks for Photos permission after every rebuild: the
# privacy database keys the grant to the signing identity, and each build
# gets a fresh one. That is expected friction, not a bug in this script.
#
# Usage:
#   scripts/build-app.sh                 # build, verify, install to /Applications
#   scripts/build-app.sh --no-install    # build and verify only (used by CI)
#   scripts/build-app.sh --output-dir D  # place the built .app in D

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

PROJECT_PATH="${REPO_ROOT}/iShrink.xcodeproj"
ENTITLEMENTS_PATH="${REPO_ROOT}/App/iShrink.entitlements"
TARGET_NAME="iShrink"
CONFIGURATION="Release"
BUNDLE_ID="com.ishrink.app"
APP_NAME="iShrink.app"

BUILD_ROOT="${REPO_ROOT}/build/xcodebuild"
OUTPUT_DIR="${REPO_ROOT}/build/export"
INSTALL_DIR="/Applications"
DO_INSTALL=1

# --- Arguments --------------------------------------------------------------

while [ $# -gt 0 ]; do
  case "$1" in
    --no-install)
      DO_INSTALL=0
      shift
      ;;
    --output-dir)
      if [ $# -lt 2 ]; then
        echo "build-app: --output-dir requires a directory argument." >&2
        exit 2
      fi
      OUTPUT_DIR="$2"
      shift 2
      ;;
    -h|--help)
      sed -n '3,25p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *)
      echo "build-app: unknown argument '$1'. Try --help." >&2
      exit 2
      ;;
  esac
done

# --- Preconditions ----------------------------------------------------------
#
# Checked up front and loudly, so a missing tool surfaces as one clear line
# rather than as a confusing failure three hundred lines into a build log.

require_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "build-app: FAILED — required command '$1' not found. $2" >&2
    exit 1
  fi
}

require_command xcodebuild "Install Xcode and run: xcode-select --install"
require_command codesign "Ships with the Xcode command line tools."
require_command ditto "Ships with macOS."

if [ ! -d "${PROJECT_PATH}" ]; then
  echo "build-app: FAILED — no Xcode project at ${PROJECT_PATH}." >&2
  exit 1
fi

if [ ! -f "${ENTITLEMENTS_PATH}" ]; then
  echo "build-app: FAILED — no entitlements file at ${ENTITLEMENTS_PATH}." >&2
  echo "build-app: without it the app cannot be granted Photos access." >&2
  exit 1
fi

if [ ! -x "${SCRIPT_DIR}/verify-app.sh" ]; then
  echo "build-app: FAILED — ${SCRIPT_DIR}/verify-app.sh is missing or not executable." >&2
  exit 1
fi

# --- Build ------------------------------------------------------------------
#
# Signing settings are overridden per-invocation rather than changed in
# project.yml. project.yml keeps CODE_SIGN_STYLE: Automatic so opening the
# project in Xcode still works for a developer with an Apple account signed
# in; automatic signing would fail outright on a CI runner, which has no
# such account. Overriding here gives both paths an identical ad-hoc build.
#
# The entitlements file is NOT passed here — project.yml already sets
# CODE_SIGN_ENTITLEMENTS, and duplicating the path in two places is how the
# two get out of sync. scripts/verify-app.sh proves it actually landed.

echo "build-app: building ${TARGET_NAME} (${CONFIGURATION}, universal)…"

rm -rf "${BUILD_ROOT}"

# Build output is redirected with SYMROOT/OBJROOT rather than
# -derivedDataPath: xcodebuild rejects -derivedDataPath unless -scheme is
# also given, and this project has no shared scheme (XcodeGen only emits one
# when project.yml asks for it). -target avoids depending on a scheme
# existing, so the build settings do the redirection instead.
xcodebuild build \
  -project "${PROJECT_PATH}" \
  -target "${TARGET_NAME}" \
  -configuration "${CONFIGURATION}" \
  SYMROOT="${BUILD_ROOT}" \
  OBJROOT="${BUILD_ROOT}/Intermediates" \
  ARCHS="arm64 x86_64" \
  ONLY_ACTIVE_ARCH=NO \
  CODE_SIGN_STYLE=Manual \
  CODE_SIGN_IDENTITY="-" \
  CODE_SIGNING_REQUIRED=YES \
  CODE_SIGNING_ALLOWED=YES

BUILT_APP="${BUILD_ROOT}/${CONFIGURATION}/${APP_NAME}"

if [ ! -d "${BUILT_APP}" ]; then
  echo "build-app: FAILED — build reported success but ${BUILT_APP} does not exist." >&2
  exit 1
fi

# --- Export -----------------------------------------------------------------
#
# ditto rather than cp -R: it preserves the bundle's symlinks, extended
# attributes, and — critically — the code signature. cp -R can invalidate a
# signature, which would be caught by verify-app.sh but only after wasting a
# full build.

mkdir -p "${OUTPUT_DIR}"
OUTPUT_DIR="$(cd "${OUTPUT_DIR}" && pwd)"
EXPORTED_APP="${OUTPUT_DIR}/${APP_NAME}"

rm -rf "${EXPORTED_APP}"
ditto "${BUILT_APP}" "${EXPORTED_APP}"

# A locally built app was never downloaded, so it carries no quarantine
# attribute to begin with. Clearing it is a defensive no-op that keeps this
# script correct if the bundle is ever produced by some other route.
xattr -dr com.apple.quarantine "${EXPORTED_APP}" 2>/dev/null || true

# --- Verify -----------------------------------------------------------------

"${SCRIPT_DIR}/verify-app.sh" "${EXPORTED_APP}"

echo "build-app: built ${EXPORTED_APP}"

# --- Install ----------------------------------------------------------------

if [ "${DO_INSTALL}" -eq 0 ]; then
  echo "build-app: --no-install given; leaving the bundle in ${OUTPUT_DIR}."
  exit 0
fi

INSTALLED_APP="${INSTALL_DIR}/${APP_NAME}"

# Never blindly delete something in /Applications. If a bundle with our name
# is already there but is not our app, stop and let a human look at it.
if [ -d "${INSTALLED_APP}" ]; then
  existing_id="$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" \
    "${INSTALLED_APP}/Contents/Info.plist" 2>/dev/null || echo "")"
  if [ "${existing_id}" != "${BUNDLE_ID}" ]; then
    echo "build-app: FAILED — ${INSTALLED_APP} already exists but its bundle" >&2
    echo "build-app: identifier is '${existing_id:-unreadable}', not '${BUNDLE_ID}'." >&2
    echo "build-app: refusing to replace an application this script did not install." >&2
    exit 1
  fi
  rm -rf "${INSTALLED_APP}"
fi

if ! ditto "${EXPORTED_APP}" "${INSTALLED_APP}"; then
  echo "build-app: FAILED — could not write to ${INSTALL_DIR}." >&2
  echo "build-app: retry with: sudo ditto '${EXPORTED_APP}' '${INSTALLED_APP}'" >&2
  exit 1
fi

echo
echo "build-app: installed ${INSTALLED_APP}"
echo "build-app: open it with:  open '${INSTALLED_APP}'"
echo "build-app: macOS will ask for Photos access on first launch. It asks again"
echo "build-app: after every rebuild, because each build is signed with a new"
echo "build-app: ad-hoc identity that macOS treats as a different app."
exit 0
