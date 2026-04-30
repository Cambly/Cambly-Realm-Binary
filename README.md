# Cambly-Realm-Binary

Defensive mirror of [realm-swift](https://github.com/realm/realm-swift) release assets for Cambly's iOS apps. **No re-packaging** — the zips published here are byte-for-byte identical to the upstream `realm-swift` releases (sha256 unchanged).

## Why this exists

`Cambly-Swift`'s `LocalPackages/RealmBinary/realm-binaries.json` references zip URLs to download Realm `.xcframework` artifacts. By default those URLs point at `github.com/realm/realm-swift/releases/...`. If upstream:
- Deletes a release
- Changes a URL pattern
- Has a temporary GitHub outage / rate-limits Cambly traffic

…Cambly devs and CI all break. Mirroring to a Cambly-owned repo gives us a stable URL that's only ever changed by Cambly.

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

Trigger the **Mirror Realm release** workflow under the Actions tab (or via CLI), passing the upstream version:

```bash
gh workflow run mirror-and-release.yml -f version=20.0.5 \
  --repo Cambly/Cambly-Realm-Binary
gh run watch --repo Cambly/Cambly-Realm-Binary
```

The workflow:
1. Downloads the 5 expected assets from `realm-swift` upstream
2. Verifies each is non-empty
3. Uploads them as-is to a new Cambly release `vX.Y.Z`
4. The shas remain identical to upstream (no re-packaging)

If `realm-swift` adds a new Xcode-version asset (e.g. `RealmSwift@26.5.spm.zip`), edit the workflow's asset list to include it.

## Then in Cambly-Swift

Edit `LocalPackages/RealmBinary/realm-binaries.json`:

```diff
 "realm_obj_c": {
-  "url": "https://github.com/realm/realm-swift/releases/download/v20.0.5/Realm.spm.zip",
+  "url": "https://github.com/Cambly/Cambly-Realm-Binary/releases/download/v20.0.5/Realm.spm.zip",
   "checksum": "<unchanged — same sha as upstream>"
 }
```

Sha values stay identical because the assets are byte-for-byte mirrors.
