# Cambly-Realm-Binary

Cambly-owned distribution of [realm-swift](https://github.com/realm/realm-swift) release assets for Cambly's iOS apps. Each xcframework is re-signed with the team's Apple Distribution identity so App Store Connect's ITMS-91065 "Missing signature" check passes (upstream's release zips ship unsigned, see MOB-290).

## Why this exists

`Cambly-Swift`'s `LocalPackages/RealmBinary/realm-binaries.json` references zip URLs to download Realm `.xcframework` artifacts. Two reasons we don't point those URLs at `github.com/realm/realm-swift/releases/...` directly:

1. **Apple Distribution signature** — upstream ships unsigned xcframeworks. App Store Connect's ITMS-91065 check rejects any TestFlight submission that bundles an unsigned third-party SDK on Apple's "commonly used" list (Realm is on it). We re-sign each xcframework before publishing so consumer apps don't have to.
2. **Defensive mirror** — if upstream deletes a release, changes a URL pattern, has a GitHub outage, or rate-limits Cambly traffic, Cambly devs and CI all break. A Cambly-owned URL is only ever changed by Cambly.

## Release layout — one tag per (realm-version, xcode-version) pair

Each xcframework slice gets its own tagged release. This lets us re-roll a single Xcode toolchain (e.g. when a `26.4 → 26.4.1` bump invalidates the existing 26.4 slice) without disturbing the other slices' tags or shas.

| Tag | Asset | Source | Purpose |
|---|---|---|---|
| `v<realm>` | `Realm.spm.zip` | upstream mirror, signed | Objective-C core (shared across all Xcode versions) |
| `v<realm>-xcode<minor>` | `RealmSwift@<minor>.spm.zip` | upstream mirror, signed | Swift wrapper compiled against an Xcode RC toolchain (e.g. `26.4`) |
| `v<realm>-xcode<minor>.<patch>` | `RealmSwift@<minor>.<patch>.spm.zip` | Cambly-built from source, signed | Swift wrapper compiled against a GA toolchain (e.g. `26.4.1`) — use when the RC-built slice errors with "Compiled module was created by a different version of the compiler" |

Example for realm-swift v20.0.4:
- `v20.0.4` → `Realm.spm.zip`
- `v20.0.4-xcode26.1` → `RealmSwift@26.1.spm.zip` (upstream mirror)
- `v20.0.4-xcode26.2` → `RealmSwift@26.2.spm.zip` (upstream mirror)
- `v20.0.4-xcode26.3` → `RealmSwift@26.3.spm.zip` (upstream mirror)
- `v20.0.4-xcode26.4` → `RealmSwift@26.4.spm.zip` (upstream mirror)
- `v20.0.4-xcode26.4.1` → `RealmSwift@26.4.1.spm.zip` (Cambly-built — produced by `build-realm-swift.yml`)

Republishes that change the asset bytes (e.g. a new signing identity) append a suffix to the tag: `v20.0.4-xcode26.4.1-signed`.

Cambly devs only download `Realm.spm.zip` (~37 MB) + the `RealmSwift@<their-Xcode>.spm.zip` (~23 MB) ≈ 60 MB per machine, sha-keyed cache.

## Mirroring a new Realm version

Trigger the **Mirror Realm release** workflow under the Actions tab (or via CLI), passing the upstream version and (for re-publishes that change asset bytes, e.g. an updated signing identity) an optional `tag_suffix`:

```bash
gh workflow run mirror-and-release.yml \
  -f version=20.0.5 \
  -f tag_suffix=-signed \
  --repo Cambly/Cambly-Realm-Binary
gh run watch --repo Cambly/Cambly-Realm-Binary
```

The workflow:
1. Downloads the 5 expected assets from `realm-swift` upstream (1 ObjC core + 4 per-Xcode-version Swift slices)
2. Verifies each is non-empty
3. Unzips each `.spm.zip`, signs the enclosed `.xcframework` with the team's Apple Distribution identity (via fastlane match + the `setup-signing` composite action), and re-zips
4. Publishes one GitHub release per slice — see the [release layout](#release-layout--one-tag-per-realm-version-xcode-version-pair) above. With `tag_suffix=-signed` the tags are `v20.0.5-signed`, `v20.0.5-xcode26.1-signed`, `v20.0.5-xcode26.2-signed`, etc.

If `realm-swift` adds a new Xcode-version asset (e.g. `RealmSwift@26.5.spm.zip`), pass it via the `xcode_versions` input — no workflow edits required.

### Xcode pinning

Both workflows pin the runner's Xcode via [`maxim-lobanov/setup-xcode`](https://github.com/maxim-lobanov/setup-xcode) instead of trusting whatever the `macos-26` runner image's default happens to be. Inputs:

| Workflow | Input | Default | Why |
|---|---|---|---|
| `build-realm-swift.yml` | `xcode_version` | `26.5` | Drives the produced slice's tag and asset name — slice ABI is keyed on the full Swift compiler build, which differs even between Xcode point releases. |
| `mirror-and-release.yml` | `host_xcode_version` | `26.5` | Defense-in-depth so `codesign` + Command Line Tools behavior is reproducible across runs. Mirror doesn't compile anything, but CLT behavior can drift across Xcode versions. |

When GitHub eventually removes a pinned version from the runner image, both workflows fail loudly with `Xcode <ver> not found at /Applications/Xcode_<ver>.app` — preferred to silently producing a different artifact.

### Bumping the pin to a new Xcode

`scripts/upgrade-xcode.sh` walks through the upgrade. It fetches the [runner-image readme](https://github.com/actions/runner-images/blob/main/images/macos/macos-26-arm64-Readme.md), validates the requested version is actually installed, and rewrites the YAML defaults in both workflows:

```bash
# Show current pin + which Xcodes are installed on macos-26 today:
./scripts/upgrade-xcode.sh

# Bump both pins to 26.5 (validates 26.5 is on the image first):
./scripts/upgrade-xcode.sh --to 26.5

# Force a bump even if the readme is stale (rare; only when you're sure
# the image already has the version):
./scripts/upgrade-xcode.sh --to 27.0 --skip-availability-check
```

After running, commit the YAML diff, open a PR, and once merged dispatch the workflows with the new `xcode_version` to produce signed releases keyed to the new toolchain. Then update `LocalPackages/RealmBinary/realm-binaries.json` in Cambly-Swift.

### Required secrets

Both workflows require these repo secrets (configure under Settings → Secrets and variables → Actions):

| Secret | Purpose |
|---|---|
| `MATCH_GIT_SSH_PRIVATE_KEY` | SSH key with read access to `Cambly/Cambly-Swift-Signing` (cambly-machine-user-ios) |
| `MATCH_PASSWORD` | Decryption password for the Cambly-Swift-Signing repo |
| `SIGNING_IDENTITY` | Common-name of the Apple Distribution cert (e.g. `Apple Distribution: Cambly Inc. (ZNP9AYBP23)`) |

These mirror the secrets used by `Cambly-iOS-Vendor-Binaries`.

## Then in Cambly-Swift

Edit `LocalPackages/RealmBinary/realm-binaries.json` with the new URLs **and** new sha256s (the signed zip has different bytes than upstream). Each slice has its own per-Xcode-version tag:

```diff
 "realm_obj_c": {
-  "url": "https://github.com/Cambly/Cambly-Realm-Binary/releases/download/v20.0.5/Realm.spm.zip",
+  "url": "https://github.com/Cambly/Cambly-Realm-Binary/releases/download/v20.0.5-signed/Realm.spm.zip",
-  "checksum": "<upstream sha>"
+  "checksum": "<new sha from the v20.0.5-signed release notes>"
 },
 "realm_swift": {
   "26.1": {
-    "url": ".../v20.0.5/RealmSwift@26.1.spm.zip",
+    "url": ".../v20.0.5-xcode26.1-signed/RealmSwift@26.1.spm.zip",
     ...
   },
   "26.4.1": {
-    "url": ".../v20.0.5-xcode26.4.1/RealmSwift@26.4.1.spm.zip",
+    "url": ".../v20.0.5-xcode26.4.1-signed/RealmSwift@26.4.1.spm.zip",
     ...
   }
 }
```

Sha values change after signing — pull the new ones from each per-Xcode-version release's "Slice (sha256)" section.
