#!/usr/bin/env bash
#
# Walk through bumping the Xcode pin used by build-realm-swift.yml and
# mirror-and-release.yml.
#
# Apple ships new Xcode GA releases on their cadence; GitHub adds them to
# the macos-NN runner images days-to-weeks later. When you need a slice
# keyed to a newer Xcode in CI:
#
#   1. Verify the version is actually installed on the macos-26 runner
#      image (this script fetches actions/runner-images readme and parses
#      the Xcode table).
#   2. Bump the `xcode_version` (build-realm-swift.yml) and
#      `host_xcode_version` (mirror-and-release.yml) defaults to the new
#      version.
#   3. Open a PR with the bump, plus a note in the description about which
#      RealmSwift slices need to be re-produced under the new toolchain.
#   4. After merge, dispatch the workflows to produce signed releases for
#      the new Xcode key. Then update LocalPackages/RealmBinary/realm-
#      binaries.json in Cambly-Swift with the new URLs + sha256s.
#
# This script automates steps 1 + 2. Steps 3 + 4 still need a human.
#
# Usage:
#   ./scripts/upgrade-xcode.sh                 # show current pin + available Xcodes
#   ./scripts/upgrade-xcode.sh --to 26.5       # bump pin to 26.5
#   ./scripts/upgrade-xcode.sh --to 26.5 --runner-image macos-15
#                                              # check against a different image
#   ./scripts/upgrade-xcode.sh --to 26.5 --skip-availability-check
#                                              # bump without validating the image
#
# Required: gh CLI (only for --to availability check). No PR is opened —
# you commit + push the resulting YAML diff yourself.

set -euo pipefail

# ─── Defaults / CLI ─────────────────────────────────────────────────────────

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_YML="$REPO_ROOT/.github/workflows/build-realm-swift.yml"
MIRROR_YML="$REPO_ROOT/.github/workflows/mirror-and-release.yml"

TARGET_VERSION=""
RUNNER_IMAGE="macos-26"
SKIP_CHECK=false

usage() {
  cat <<EOF
Walk through bumping the Xcode pin used by the build + mirror workflows.

USAGE
  $0                              # show current state + available Xcodes
  $0 --to <version>               # bump the pin
  $0 --to <version> [options]

OPTIONS
  --to <version>            Xcode version to pin (e.g. 26.5, 26.4.1).
                            Must be a value that \`xcodebuild -version\`
                            would emit — usually the Version column from
                            the runner-image readme (so "26.5" not
                            "26.5.0"; "26.4.1" with patch).
  --runner-image <name>     Runner image to check availability against
                            (default: macos-26).
  --skip-availability-check Don't validate against the runner-image readme;
                            just rewrite the YAML defaults. Use when the
                            readme is stale or you're testing offline.
  -h, --help                Show this help.

EXAMPLES
  # See current pin + which Xcodes the macos-26 runner image has installed:
  $0

  # Bump to 26.5 (validates 26.5 is on macos-26 first):
  $0 --to 26.5

  # Bump to 27.0 the day Apple ships it, even if the image readme hasn't
  # been updated yet — caveat emptor, build will fail loudly if the runner
  # doesn't actually have 27.0:
  $0 --to 27.0 --skip-availability-check
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --to)                      TARGET_VERSION="$2"; shift 2 ;;
    --runner-image)            RUNNER_IMAGE="$2"; shift 2 ;;
    --skip-availability-check) SKIP_CHECK=true; shift ;;
    -h|--help)                 usage; exit 0 ;;
    *) echo "❌ Unknown argument: $1"; echo ""; usage; exit 2 ;;
  esac
done

bold()  { printf '\033[1m%s\033[0m\n' "$*"; }
green() { printf '\033[32m%s\033[0m\n' "$*"; }
yellow(){ printf '\033[33m%s\033[0m\n' "$*"; }
red()   { printf '\033[31m%s\033[0m\n' "$*" >&2; }
step()  { echo ""; bold "▶▶▶ $*"; }

# ─── Read current pin ───────────────────────────────────────────────────────

step "Reading current pin"
# Workflow defaults look like:
#       xcode_version:
#         …
#         default: "26.5"
# We grep for the line, then the *next* default: line within the same input
# block. Tolerates either single or double quotes.
extract_default() {
  local file="$1" key="$2"
  awk -v key="$key" '
    $0 ~ "^[[:space:]]+"key":[[:space:]]*$" { found=1; next }
    found && $0 ~ /^[[:space:]]+default:/ {
      gsub(/^[[:space:]]+default:[[:space:]]*/, "")
      gsub(/^["'\'']|["'\'']$/, "")
      print; exit
    }
  ' "$file"
}

CURRENT_BUILD=$(extract_default "$BUILD_YML" "xcode_version")
CURRENT_MIRROR=$(extract_default "$MIRROR_YML" "host_xcode_version")
echo "build-realm-swift.yml  xcode_version       = $CURRENT_BUILD"
echo "mirror-and-release.yml host_xcode_version  = $CURRENT_MIRROR"

# ─── Fetch runner-image installed-Xcode list ───────────────────────────────

show_available_xcodes() {
  local image="$1"
  if ! command -v gh >/dev/null 2>&1; then
    yellow "gh CLI not found — skipping runner-image availability lookup."
    return 0
  fi
  step "Fetching installed Xcodes on $image (actions/runner-images)"
  # The arm64 readme is the authoritative list for arm64 macOS runners.
  # actions/runner-images publishes per-image readmes at:
  #   images/macos/<image>-arm64-Readme.md   (arm64)
  #   images/macos/<image>-Readme.md         (x86_64; macOS 14 and earlier only)
  # macOS-26+ is arm64-only on hosted runners, so always use the arm64 readme.
  local path="images/macos/${image}-arm64-Readme.md"
  local readme
  if ! readme=$(gh api "repos/actions/runner-images/contents/$path" \
                  --jq '.content' 2>/dev/null | base64 -d 2>/dev/null); then
    yellow "Could not fetch $path (image may not exist or readme path may have moved)."
    return 1
  fi

  # The Xcode section is a markdown table:
  #   | Version | Build | Path | Symlinks |
  #   |---|---|---|---|
  #   | 26.5 | 17F42 | /Applications/Xcode_26.5.app | /Applications/Xcode_26.5.0.app |
  #   | 26.4.1 (default) | … |
  # Pluck Version + Build from each table row by parsing the lines that look
  # like "| <version> | <build> | …". Skip the header divider.
  echo ""
  printf "  %-20s  %s\n" "Version" "Build"
  printf "  %-20s  %s\n" "-------" "-----"
  echo "$readme" \
    | awk '/^###?#? Xcode$/{inx=1; next} inx && /^#/{exit} inx' \
    | awk -F'|' '
        NF >= 4 && $2 !~ /Version/ && $2 !~ /^[[:space:]]*-+[[:space:]]*$/ {
          v=$2; b=$3
          gsub(/^[[:space:]]+|[[:space:]]+$/, "", v)
          gsub(/^[[:space:]]+|[[:space:]]+$/, "", b)
          if (v != "" && b != "") printf "  %-20s  %s\n", v, b
        }
      '
  echo ""
}

show_available_xcodes "$RUNNER_IMAGE" || true

# ─── If no --to, stop after showing current state ───────────────────────────

if [[ -z "$TARGET_VERSION" ]]; then
  echo ""
  yellow "No --to specified. Pass --to <version> to bump the pin."
  exit 0
fi

# ─── Validate target version is available on the runner image ───────────────

if ! $SKIP_CHECK; then
  step "Validating $TARGET_VERSION is installed on $RUNNER_IMAGE"
  if ! command -v gh >/dev/null 2>&1; then
    red "gh CLI required for availability check. Install (brew install gh) or pass --skip-availability-check."
    exit 1
  fi
  path="images/macos/${RUNNER_IMAGE}-arm64-Readme.md"
  readme=$(gh api "repos/actions/runner-images/contents/$path" \
             --jq '.content' | base64 -d)
  # Parse the Xcode section's Version column. Strip the " (default)" suffix
  # before comparing.
  installed=$(echo "$readme" \
    | awk '/^###?#? Xcode$/{inx=1; next} inx && /^#/{exit} inx' \
    | awk -F'|' '
        NF >= 4 && $2 !~ /Version/ && $2 !~ /^[[:space:]]*-+[[:space:]]*$/ {
          v=$2
          gsub(/^[[:space:]]+|[[:space:]]+$/, "", v)
          gsub(/[[:space:]]*\(default\)[[:space:]]*$/, "", v)
          if (v != "") print v
        }
      ')
  if grep -Fxq "$TARGET_VERSION" <<<"$installed"; then
    green "✓ Xcode $TARGET_VERSION is installed on $RUNNER_IMAGE"
  else
    red "✗ Xcode $TARGET_VERSION is NOT listed as installed on $RUNNER_IMAGE."
    red "  Installed versions:"
    echo "$installed" | sed 's/^/    /' >&2
    red ""
    red "  Either pick a listed version, or pass --skip-availability-check if you"
    red "  believe the readme is stale (the workflow will fail loudly at setup-xcode"
    red "  time if you're wrong, so this is safe to do at your own risk)."
    exit 1
  fi
fi

# ─── Rewrite the YAML defaults ──────────────────────────────────────────────

step "Updating workflow YAML defaults"

# Use awk to find the input block for the key and rewrite its `default:` line.
# Tolerates the surrounding indentation level of GHA workflow inputs.
rewrite_default() {
  local file="$1" key="$2" new="$3"
  local tmp="$file.tmp"
  awk -v key="$key" -v new="$new" '
    BEGIN { found=0 }
    {
      if ($0 ~ "^[[:space:]]+"key":[[:space:]]*$") { found=1; print; next }
      if (found && $0 ~ /^[[:space:]]+default:[[:space:]]*/) {
        match($0, /^[[:space:]]+/)
        indent = substr($0, RSTART, RLENGTH)
        printf "%sdefault: \"%s\"\n", indent, new
        found=0
        next
      }
      print
    }
  ' "$file" > "$tmp"
  mv "$tmp" "$file"
}

rewrite_default "$BUILD_YML"  "xcode_version"      "$TARGET_VERSION"
rewrite_default "$MIRROR_YML" "host_xcode_version" "$TARGET_VERSION"

# Verify we actually changed something
NEW_BUILD=$(extract_default "$BUILD_YML" "xcode_version")
NEW_MIRROR=$(extract_default "$MIRROR_YML" "host_xcode_version")
echo "build-realm-swift.yml  xcode_version       = $NEW_BUILD"
echo "mirror-and-release.yml host_xcode_version  = $NEW_MIRROR"
if [[ "$NEW_BUILD" != "$TARGET_VERSION" || "$NEW_MIRROR" != "$TARGET_VERSION" ]]; then
  red "rewrite_default failed to bump one or both files. Check the YAML manually."
  exit 1
fi

# ─── Next steps ─────────────────────────────────────────────────────────────

green "✓ Pinned both workflows to Xcode $TARGET_VERSION on $RUNNER_IMAGE"

cat <<EOF

Next steps:

  1. Review + commit the diff:
     $ git diff .github/workflows/
     $ git add .github/workflows/
     $ git commit -m "Bump Xcode pin to $TARGET_VERSION"

  2. Open a PR. Mention which Xcode versions of RealmSwift slices need to be
     re-produced under the new toolchain so the same realm-binaries.json key
     in Cambly-Swift points at a slice built with the new compiler.

  3. After merge, dispatch the workflows to produce signed releases keyed to
     the new Xcode (\`v<realm>-xcode$TARGET_VERSION-signed\`):

     gh workflow run build-realm-swift.yml \\
       -f xcode_version=$TARGET_VERSION \\
       -f tag_suffix=-signed \\
       --repo Cambly/Cambly-Realm-Binary

  4. Update LocalPackages/RealmBinary/realm-binaries.json in Cambly-Swift
     with the new URL + sha256 under the matching xcode key.

EOF
