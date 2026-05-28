# Cambly-Realm-Binary

Cambly-owned distribution of [realm-swift](https://github.com/realm/realm-swift) release assets for Cambly's iOS apps. Each xcframework is re-signed with the team's Apple Distribution identity so App Store Connect's ITMS-91065 "Missing signature" check passes (upstream's release zips ship unsigned, see MOB-290).

## Why this exists

`Cambly-Swift`'s `LocalPackages/RealmBinary/realm-binaries.json` references zip URLs to download Realm `.xcframework` artifacts. Two reasons we don't point those URLs at `github.com/realm/realm-swift/releases/...` directly:

1. **Apple Distribution signature** — upstream ships unsigned xcframeworks. App Store Connect's ITMS-91065 check rejects any TestFlight submission that bundles an unsigned third-party SDK on Apple's "commonly used" list (Realm is on it). We re-sign each xcframework before publishing so consumer apps don't have to.
2. **Defensive mirror** — if upstream deletes a release, changes a URL pattern, has a GitHub outage, or rate-limits Cambly traffic, Cambly devs and CI all break. A Cambly-owned URL is only ever changed by Cambly.

## What's mirrored per release

For each upstream `realm-swift` version (e.g. `v20.0.4`), we mirror:

| Asset | Size | Purpose |
|---|---:|---|
| `Realm.spm.zip` | ~37 MB | Objective-C core (shared across all Xcode versions) |
| `RealmSwift@26.1.spm.zip` | ~23 MB | Swift wrapper, Xcode 26.1 swiftmodule |
| `RealmSwift@26.2.spm.zip` | ~23 MB | Swift wrapper, Xcode 26.2 swiftmodule |
| `RealmSwift@26.3.spm.zip` | ~23 MB | Swift wrapper, Xcode 26.3 swiftmodule |
| `RealmSwift@26.4.spm.zip` | ~23 MB | Swift wrapper, Xcode 26.4 swiftmodule |

Total ~129 MB per release. Cambly devs only download `Realm.spm.zip` (37 MB) + the `RealmSwift@<their-Xcode>.spm.zip` (23 MB) ≈ 60 MB per machine, sha-keyed cache.

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
1. Downloads the 5 expected assets from `realm-swift` upstream
2. Verifies each is non-empty
3. Unzips each `.spm.zip`, signs the enclosed `.xcframework` with the team's Apple Distribution identity (via fastlane match + the `setup-signing` composite action), and re-zips
4. Publishes a Cambly release `vX.Y.Z<tag_suffix>` with the signed assets

If `realm-swift` adds a new Xcode-version asset (e.g. `RealmSwift@26.5.spm.zip`), edit the workflow's asset list to include it.

### Required secrets

Both workflows require these repo secrets (configure under Settings → Secrets and variables → Actions):

| Secret | Purpose |
|---|---|
| `MATCH_GIT_SSH_PRIVATE_KEY` | SSH key with read access to `Cambly/Cambly-Swift-Signing` (cambly-machine-user-ios) |
| `MATCH_PASSWORD` | Decryption password for the Cambly-Swift-Signing repo |
| `SIGNING_IDENTITY` | Common-name of the Apple Distribution cert (e.g. `Apple Distribution: Cambly Inc. (ZNP9AYBP23)`) |

These mirror the secrets used by `Cambly-iOS-Vendor-Binaries`.

## Then in Cambly-Swift

Edit `LocalPackages/RealmBinary/realm-binaries.json` with the new URL **and** new sha256 (the signed zip has different bytes than upstream):

```diff
 "realm_obj_c": {
-  "url": "https://github.com/realm/realm-swift/releases/download/v20.0.5/Realm.spm.zip",
+  "url": "https://github.com/Cambly/Cambly-Realm-Binary/releases/download/v20.0.5-signed/Realm.spm.zip",
-  "checksum": "<upstream sha>"
+  "checksum": "<new sha from the workflow's release notes>"
 }
```

Sha values change after signing — pull the new ones from the workflow's release-notes section "Signed assets (sha256)".
