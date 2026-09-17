# SwiftMaestro Release Runbook

This is the single canonical release instruction set for SwiftMaestro. All agents and maintainers must follow it exactly.

## 1. Who decides the release

- **Version and build numbers are the user's decision and must be explicitly stated.**
- If the user has not provided the exact `CFBundleShortVersionString` and `CFBundleVersion`, stop and ask.
- Never assume a major/minor/patch bump or invent a version.

## 2. Pre-release checks

- Confirm the exact version and build number with the user.
- Confirm whether to upload (`UPLOAD=1`) and whether to notarize (`NOTARIZE=1`).
- Ensure the working tree is clean. If it is not, ask the user whether to commit or stash.
- Do not bypass `release-check.sh` unless the user explicitly says you are retrying after a failure.

## 3. Release steps

```bash
# 1. Bump Sources/Resources/Info.plist with the EXACT version/build the user gave.
#    (CFBundleShortVersionString and CFBundleVersion)

# 2. Commit the version bump.
git add Sources/Resources/Info.plist
git commit -m "chore(release): bump version to X.Y.Z (build N)"

# 3. Push to the active remotes (origin and beta; private only if instructed).
git push origin main
git push beta main

# 4. Run the release pipeline.
#    Use UPLOAD=1 only if the user asked to upload.
./scripts/release.sh            # build + sign + package + appcast
UPLOAD=1 ./scripts/release.sh   # same + upload
```

## 4. During the release

- Report progress at each milestone:
  - Build started
  - Packaging started
  - Appcast generation started
  - Upload started
  - Upload complete
- Check in proactively if any step takes longer than 60 minutes.
- Do not make unilateral decisions. If something fails or is unclear, report it and ask for instructions.

## 5. Upload verification

Before declaring the upload stalled, verify it is actually moving:

```bash
# Watch outgoing bytes (column 10, Obytes)
netstat -ibn

# Or run mc in debug mode and count partNumber=... 200 OK lines
mc --debug cp ...

# Server-side incomplete multipart sessions
mc ls --incomplete onidel/swiftmaestro-releases/
```

Expected rate on the user's fibre: ~5 MB/s (28 GB ≈ 90–100 min).

## 6. Tagging

- Create and push the git tag **only after the upload succeeds**.

```bash
git tag -a vX.Y.Z -m "Release vX.Y.Z"
git push origin vX.Y.Z
git push beta vX.Y.Z
```

## 7. If something goes wrong

- If the release script fails, report the exact error and ask the user for instructions before retrying.
- If an `mc` upload fails, retry `mc` — do not switch upload methods.
- Do not invent a "light/beta" installer variant to dodge upload size.
- Do not bypass `release-check.sh` with `SKIP_RELEASE_CHECK=1` unless the user explicitly says you are retrying after a failure.

## 8. Notes

- The only sanctioned release path is `./scripts/release.sh`.
- The only sanctioned upload method for the ~28 GB full installer is `mc` via `upload-to-onidel.sh` (wired into `release.sh`).
- Never upload via curl/single-PUT, presigned URLs, SFTP/lftp, rclone, or the Onidel web UI.
- PKG first, appcast second. A live appcast pointing at a missing installer breaks every updater.
- Do not launch the app as part of the release process.
