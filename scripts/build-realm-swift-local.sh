#!/usr/bin/env bash
#
# Build a signed RealmSwift.xcframework locally against your machine's Xcode.
#
# Mirrors what .github/workflows/build-realm-swift.yml does on the macos-26
# runner, but without GHA's slow Xcode-upgrade cadence — you get a slice keyed
# to whatever Xcode you currently have selected (xcode-select -p).
#
# Default behavior:
#   1. Resolves the realm-swift version (defaults to the latest mirror release
#      in this repo with tag shape vMAJOR.MINOR.PATCH).
#   2. Detects the active Xcode via `xcodebuild -version` (full major.minor.patch).
#   3. Clones realm/realm-swift at that version into build/realm-swift-src.
#   4. Builds Realm + RealmSwift xcframeworks for all platforms via `sh build.sh
#      xcframework` (default platforms: osx ios watchos tvos catalyst visionos).
#   5. Signs RealmSwift.xcframework as a whole bundle with the Apple Distribution
#      identity (auto-detected from keychain unless --signing-identity is given).
#   6. Zips to build/artifacts/RealmSwift@<xcode-ver>.spm.zip and prints sha256.
#
# Optional: pass --upload to publish a GitHub release tagged
# v<realm-ver>-xcode<xcode-ver>${--tag-suffix} with the produced zip.
#
# Usage:
#   ./scripts/build-realm-swift-local.sh
#   ./scripts/build-realm-swift-local.sh --realm-version 20.0.4 --tag-suffix -signed --upload
#   ./scripts/build-realm-swift-local.sh --skip-sdk-download   # if you already have all SDKs
#
# Prerequisites:
#   - macOS with Xcode and Command Line Tools
#   - `Apple Distribution: Cambly Inc.` in your keychain (run `security
#     find-identity -v -p codesigning` to verify; if missing, run fastlane
#     match against Cambly-Swift-Signing first)
#   - For --upload: `gh auth status` must succeed for this repo
#   - For the Realm build itself: ~10 GB free disk (clone + DerivedData + SDKs)

set -euo pipefail

# ─── Defaults / CLI ─────────────────────────────────────────────────────────

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$REPO_ROOT/build"
ARTIFACTS_DIR="$BUILD_DIR/artifacts"
SRC_DIR="$BUILD_DIR/realm-swift-src"

REALM_VERSION=""
TAG_SUFFIX=""
SIGNING_IDENTITY=""
UPLOAD=false
SKIP_SDK_DOWNLOAD=false
DRY_RUN=false

usage() {
  cat <<EOF
Build a signed RealmSwift.xcframework against your local Xcode.

USAGE
  $0 [options]

OPTIONS
  --realm-version <ver>     realm-swift tag to clone (default: latest mirror
                            release in this repo, e.g. 20.0.4). Pass without
                            the "v" prefix.
  --signing-identity <name> Apple Distribution cert common name. Default:
                            auto-detect first "Apple Distribution: Cambly Inc."
                            in your keychain.
  --tag-suffix <suffix>     Optional suffix on the release tag, e.g. -signed.
                            Used when republishing the same realm/Xcode pair
                            (mirrors the convention in build-realm-swift.yml).
  --upload                  After signing+zipping, create a GitHub release
                            tagged v<realm>-xcode<xcode>\${tag_suffix} with
                            the zip. Requires \`gh\` authenticated.
  --skip-sdk-download       Skip \`xcodebuild -downloadAllPlatforms\` (saves
                            time if you already have visionOS/watchOS SDKs).
  --dry-run                 Print what would happen, don't actually build.
  -h, --help                Show this help.

EXAMPLES
  # Just produce a signed zip + sha (no upload):
  $0

  # Produce + publish as v20.0.4-xcode26.4.1-signed:
  $0 --tag-suffix -signed --upload

  # Override the realm-swift version:
  $0 --realm-version 20.1.0 --tag-suffix -signed --upload
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --realm-version)     REALM_VERSION="$2"; shift 2 ;;
    --signing-identity)  SIGNING_IDENTITY="$2"; shift 2 ;;
    --tag-suffix)        TAG_SUFFIX="$2"; shift 2 ;;
    --upload)            UPLOAD=true; shift ;;
    --skip-sdk-download) SKIP_SDK_DOWNLOAD=true; shift ;;
    --dry-run)           DRY_RUN=true; shift ;;
    -h|--help)           usage; exit 0 ;;
    *) echo "❌ Unknown argument: $1"; echo ""; usage; exit 2 ;;
  esac
done

# ─── Pretty printing ────────────────────────────────────────────────────────

bold()  { printf '\033[1m%s\033[0m\n' "$*"; }
green() { printf '\033[32m%s\033[0m\n' "$*"; }
red()   { printf '\033[31m%s\033[0m\n' "$*" >&2; }
step()  { echo ""; bold "▶▶▶ $*"; }
run()   { if $DRY_RUN; then echo "[dry-run] $*"; else eval "$@"; fi; }

# ─── Prerequisites ──────────────────────────────────────────────────────────

step "Checking prerequisites"

if [[ "$(uname)" != "Darwin" ]]; then
  red "This script must run on macOS (codesign + xcodebuild)."
  exit 1
fi

if ! command -v xcodebuild >/dev/null 2>&1; then
  red "xcodebuild not found. Install Xcode + Command Line Tools."
  exit 1
fi

if ! command -v codesign >/dev/null 2>&1; then
  red "codesign not found. Install Command Line Tools: xcode-select --install"
  exit 1
fi

if $UPLOAD && ! command -v gh >/dev/null 2>&1; then
  red "--upload requires the GitHub CLI (gh). brew install gh"
  exit 1
fi

# ─── Resolve realm-swift version ────────────────────────────────────────────

if [[ -z "$REALM_VERSION" ]]; then
  step "Resolving realm-swift version (latest mirror tag)"
  if ! command -v gh >/dev/null 2>&1; then
    red "Need --realm-version or the gh CLI to auto-resolve. brew install gh"
    exit 1
  fi
  REALM_VERSION=$(gh release list --repo Cambly/Cambly-Realm-Binary --limit 50 --json tagName \
    --jq '.[] | select(.tagName | test("^v[0-9]+\\.[0-9]+\\.[0-9]+$")) | .tagName' \
    | head -n 1 | sed 's/^v//')
  if [[ -z "$REALM_VERSION" ]]; then
    red "Could not find a vMAJOR.MINOR.PATCH mirror release. Pass --realm-version."
    exit 1
  fi
  green "Resolved realm-swift v$REALM_VERSION"
else
  green "Using realm-swift v$REALM_VERSION (explicit)"
fi

# ─── Detect active Xcode version ────────────────────────────────────────────

step "Detecting active Xcode"
# Capture full output before parsing — xcodebuild writes via NSFileHandle and
# `head -n 1` can SIGPIPE-crash it (exit 134). Mirrors the workflow's logic.
XCODE_OUTPUT=$(xcodebuild -version)
XCODE_VERSION=$(awk 'NR==1 {print $2}' <<<"$XCODE_OUTPUT")
if [[ -z "$XCODE_VERSION" ]]; then
  red "Could not parse Xcode version from \`xcodebuild -version\`:"
  echo "$XCODE_OUTPUT"
  exit 1
fi
echo "$XCODE_OUTPUT"
xcrun swift --version || true
green "Active Xcode: $XCODE_VERSION (will produce RealmSwift@$XCODE_VERSION.spm.zip)"

# ─── Resolve signing identity ───────────────────────────────────────────────

if [[ -z "$SIGNING_IDENTITY" ]]; then
  step "Auto-detecting Apple Distribution identity"
  # Pick the first "Apple Distribution: Cambly" identity in keychain. If you
  # have multiple (renewals, old certs), explicitly pass --signing-identity
  # with the SHA1 fingerprint to disambiguate — codesign will refuse otherwise.
  SIGNING_IDENTITY=$(security find-identity -v -p codesigning \
    | awk -F\" '/Apple Distribution: Cambly/ {print $2; exit}')
  if [[ -z "$SIGNING_IDENTITY" ]]; then
    red "No \"Apple Distribution: Cambly\" identity in keychain."
    red "Run fastlane match against Cambly-Swift-Signing, or pass --signing-identity."
    exit 1
  fi
fi

# Pre-flight: if the keychain has multiple identities with the same common
# name, codesign errors out with "ambiguous". Refuse to start the long build
# before failing at the signing step.
ambiguity_count=$(security find-identity -v -p codesigning \
  | awk -v ident="$SIGNING_IDENTITY" -F\" '$2 == ident' \
  | wc -l | tr -d ' ')
if [[ "$ambiguity_count" -gt 1 ]]; then
  red "Multiple identities match \"$SIGNING_IDENTITY\" — codesign will fail with ambiguous."
  red "Run \`security find-identity -v -p codesigning\` and pass --signing-identity \"<SHA1>\""
  red "(SHA1 fingerprints are unambiguous; common names may not be)."
  exit 1
fi
green "Signing identity: $SIGNING_IDENTITY"

# ─── Clone realm-swift ──────────────────────────────────────────────────────

step "Cloning realm/realm-swift @ v$REALM_VERSION"
mkdir -p "$BUILD_DIR"
if [[ -d "$SRC_DIR/.git" ]]; then
  # Existing checkout — make sure it's at the right tag. If it's already at
  # the requested tag we re-use it (saves a fresh clone + submodule fetch);
  # otherwise wipe and re-clone to avoid stale submodule state.
  current_tag=$(git -C "$SRC_DIR" describe --tags --exact-match 2>/dev/null || echo "")
  if [[ "$current_tag" == "v$REALM_VERSION" ]]; then
    green "$SRC_DIR already at v$REALM_VERSION — reusing"
  else
    echo "Existing checkout is at '${current_tag:-detached}', wanted v$REALM_VERSION — re-cloning"
    run rm -rf "$SRC_DIR"
    run git clone --depth 1 --branch "v$REALM_VERSION" \
      --recurse-submodules --shallow-submodules \
      https://github.com/realm/realm-swift.git "$SRC_DIR"
  fi
else
  run git clone --depth 1 --branch "v$REALM_VERSION" \
    --recurse-submodules --shallow-submodules \
    https://github.com/realm/realm-swift.git "$SRC_DIR"
fi

# ─── Download Apple platform SDKs ───────────────────────────────────────────

if $SKIP_SDK_DOWNLOAD; then
  echo ""
  echo "Skipping \`xcodebuild -downloadAllPlatforms\` (--skip-sdk-download)."
else
  step "Downloading Apple platform SDKs (visionOS, watchOS may be missing)"
  # The Realm xcframework target builds for all platforms. simctl list first to
  # wait out any in-progress simulator setup that would race with
  # -downloadAllPlatforms (mirrors the workflow).
  run xcrun simctl list > /dev/null || true
  run xcodebuild -downloadAllPlatforms
fi

# ─── Build the xcframework ──────────────────────────────────────────────────

step "Building RealmSwift.xcframework (sh build.sh xcframework)"
# build.sh sets DERIVED_DATA based on GITHUB_WORKSPACE if set, but the build
# uses a *relative* -IDECustomDerivedDataLocation=build/DerivedData. When
# DERIVED_DATA and pwd diverge, xcodebuild -create-xcframework can't find the
# per-platform .frameworks. unset GITHUB_WORKSPACE so build.sh computes
# DERIVED_DATA from pwd (matches the workflow's fix).
if [[ -n "${GITHUB_WORKSPACE:-}" ]]; then
  echo "Unsetting GITHUB_WORKSPACE to keep DerivedData path consistent."
  unset GITHUB_WORKSPACE
fi

if $DRY_RUN; then
  echo "[dry-run] cd $SRC_DIR && sh build.sh xcframework"
else
  ( cd "$SRC_DIR" && sh build.sh xcframework )
fi

XCFRAMEWORK="$SRC_DIR/build/Release/RealmSwift.xcframework"
if ! $DRY_RUN && [[ ! -d "$XCFRAMEWORK" ]]; then
  red "Expected $XCFRAMEWORK after build, but it doesn't exist. Build failed?"
  ls -la "$SRC_DIR/build/" 2>/dev/null || true
  exit 1
fi

# Sanity-check the compiler version embedded in a .swiftmodule.
if ! $DRY_RUN; then
  mod=$(find "$XCFRAMEWORK" -name "*.swiftmodule" -type f | head -n 1)
  if [[ -n "$mod" ]]; then
    compiler=$(strings "$mod" | grep -E "Apple Swift version" | head -n 1 || true)
    [[ -n "$compiler" ]] && green "Built with: $compiler"
  fi
fi

# ─── Sign ───────────────────────────────────────────────────────────────────

step "Signing RealmSwift.xcframework with: $SIGNING_IDENTITY"
# Sign the bundle as a whole (Apple's documented path; writes _CodeSignature/
# at the bundle root). --force lets us re-run over an already-signed bundle,
# --timestamp embeds Apple's TSA timestamp so the signature survives cert
# expiry.
run codesign --force --timestamp -vvvv --sign "'$SIGNING_IDENTITY'" "$XCFRAMEWORK"
if ! $DRY_RUN; then
  echo "Verification:"
  codesign -dv "$XCFRAMEWORK" 2>&1 || true
fi

# ─── Zip ────────────────────────────────────────────────────────────────────

step "Zipping to RealmSwift@$XCODE_VERSION.spm.zip"
mkdir -p "$ARTIFACTS_DIR"
ASSET_NAME="RealmSwift@$XCODE_VERSION.spm.zip"
ASSET_PATH="$ARTIFACTS_DIR/$ASSET_NAME"
run rm -f "$ASSET_PATH"
if $DRY_RUN; then
  echo "[dry-run] cd $(dirname "$XCFRAMEWORK") && zip -qry $ASSET_PATH $(basename "$XCFRAMEWORK")"
else
  ( cd "$(dirname "$XCFRAMEWORK")" && zip -qry "$ASSET_PATH" "$(basename "$XCFRAMEWORK")" )
fi

# ─── Checksum + summary ─────────────────────────────────────────────────────

if ! $DRY_RUN; then
  SHA=$(shasum -a 256 "$ASSET_PATH" | awk '{print $1}')
  size=$(stat -f%z "$ASSET_PATH")
  echo ""
  bold "✅ Built signed RealmSwift slice"
  echo "  path:   $ASSET_PATH"
  echo "  size:   $((size/1024/1024)) MB"
  echo "  sha256: $SHA"

  TAG="v$REALM_VERSION-xcode$XCODE_VERSION$TAG_SUFFIX"
  echo ""
  bold "📋 Paste into LocalPackages/RealmBinary/realm-binaries.json:"
  cat <<EOF
    "$XCODE_VERSION": {
      "url": "https://github.com/Cambly/Cambly-Realm-Binary/releases/download/$TAG/$ASSET_NAME",
      "checksum": "$SHA"
    }
EOF
fi

# ─── Upload (optional) ──────────────────────────────────────────────────────

if $UPLOAD; then
  step "Publishing GitHub release $TAG"
  notes=$(mktemp)
  trap 'rm -f "$notes"' EXIT
  {
    echo "Locally-built RealmSwift xcframework for Xcode $XCODE_VERSION, source: [realm-swift v$REALM_VERSION](https://github.com/realm/realm-swift/releases/tag/v$REALM_VERSION)."
    echo ""
    echo "Produced by \`scripts/build-realm-swift-local.sh\` on $(scutil --get LocalHostName 2>/dev/null || hostname) against the developer's locally-installed Xcode toolchain. Use this when GitHub-hosted runners haven't yet upgraded to the Xcode version you need."
    echo ""
    echo "Signed with \`$SIGNING_IDENTITY\`. Verify with \`codesign -dv RealmSwift.xcframework\`."
    echo ""
    echo "### Slice (sha256)"
    echo ""
    echo "<pre>"
    printf "  %s  %s\n" "$SHA" "$ASSET_NAME"
    echo "</pre>"
  } > "$notes"

  if gh release view "$TAG" --repo Cambly/Cambly-Realm-Binary >/dev/null 2>&1; then
    run gh release upload "$TAG" "$ASSET_PATH" --repo Cambly/Cambly-Realm-Binary --clobber
  else
    run gh release create "$TAG" "$ASSET_PATH" --repo Cambly/Cambly-Realm-Binary \
      --title "$TAG" --notes-file "$notes"
  fi

  echo ""
  green "✅ Published https://github.com/Cambly/Cambly-Realm-Binary/releases/tag/$TAG"
fi
