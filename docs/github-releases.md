# GitHub releases

Google Play remains the primary distribution channel. GitHub releases mirror
Google's **signed universal APK** for an already-published production version.
Do not rebuild or re-sign an APK for GitHub, publish CI's debug-signed APK, or
publish an internal-testing version as a stable public release.

## Release workflow (single script)

Requirements: authenticated `gplay`, `gh` CLI, Git, Python 3.11+, and Android SDK build-tools.
No signing keystore or Google credential needs to be uploaded to GitHub.

### 1. Releasing 1.0.14 (Changelog & Play link, no APK)

Because Google baked Automatic Protection into version 24 when it was uploaded to Play,
1.0.14 is published as a tagged release with notes and a link to Google Play:

```bash
python3 tool/prepare_github_release.py \
  --source-ref ad8784065714a3eb03cc483cc42ee36bfcba7004 \
  --no-apk \
  --publish
```

This creates and pushes the Git tag `v1.0.14` pointing to commit `ad87840`, and creates
the GitHub release. To preview the release without publishing, omit `--publish`.

### 2. Releasing 1.0.15+ (With official Play-signed Universal APK)

With Automatic Protection turned off in Play Console, every new release upload produces
an unencumbered, Play-signed universal APK.

After deploying the AAB to Play via `gplay` and seeing it published on the production track:

```bash
# Preview and verify:
python3 tool/prepare_github_release.py

# Publish when verified:
python3 tool/prepare_github_release.py --publish
```

The script automatically:
1. Reads the current version and version code from `pubspec.yaml`.
2. Verifies the release is active on Google Play's production track.
3. Downloads the official Play-signed universal APK via `gplay`.
4. Verifies the package, version, signature against Google's pinned cert, and runs the credential gate.
5. Verifies that no injected Play licensing check exists in the APK.
6. Computes the SHA-256 checksum and saves `SHA256SUMS`.
7. Tags the Git commit (e.g. `v1.0.15`) and pushes the tag to `origin`.
8. Publishes the GitHub release with the APK and `SHA256SUMS` attached.

## Publication gates

1. **Source:** confirm the candidate source commit actually built the uploaded AAB.
2. **Fresh sideload:** install without claiming Play as the installer, without a
   pre-existing Play licence, and without an App Check debug token. Launch and
   exercise wallet, recommendations, nearby search, and optional sign-in/backup.
3. **Play protection:** verify Google's injected licensing does not prevent normal
   sideloading or force a Play install. Do not patch the downloaded APK. Review
   Play Console's automatic-protection configuration if it blocks distribution;
   changing production protection requires the owner's explicit approval.
4. **App Check:** prove protected requests succeed with the production provider.
   Firebase supports Play + external distribution; keep Play recognition required
   and Play licensing not required. Never disable enforcement or ship debug tokens.
5. **Updates:** test Play -> newer GitHub APK and GitHub -> newer Play release,
   retaining wallet data. ADB replacement alone does not prove Play Store updates.
6. **Approval:** show the owner the exact APK checksum, source tag/commit, release
   notes, test results and limitations. Publish only after explicit approval.

An emulator without a licensed Play Store cannot prove the Play-install/update or
all attestation paths. Report those checks as blocked, not passed. Official
unprotected split APKs can help diagnose a protection failure, but passing tests
on them does **not** validate a protected universal APK for GitHub distribution.

## Historical note: 1.0.14 (24)

Version 1.0.14 was uploaded to Google Play while Automatic Integrity Protection
was enabled, baking an installer check into its universal APK. It was published
to GitHub as a tagged release (`v1.0.14`) with release notes and a link to Google Play.
Subsequent releases (1.0.15+) upload with Automatic Protection turned off, allowing
clean, unencumbered universal APK downloads directly on GitHub.

## After approval

Create a release tag at the confirmed source commit and a **draft** GitHub release
containing only the APK and `SHA256SUMS`, with `RELEASE_NOTES.md` as its description.
Review the draft, then publish after the owner approves the exact result. Do not
attach AABs, service-account credentials, keystores, debug tokens, or local reports.

GitHub downloads initially use manual updates; no in-app updater is included.
Users should install newer signed APKs over the existing app, not uninstall it:
uninstalling deletes local wallet data. Matching signatures and increasing version
codes are prerequisites for moving between channels, not a guarantee that Play
will automatically adopt every sideloaded installation.

References: [Google's signed universal APK instructions](https://support.google.com/googleplay/android-developer/answer/9844279?hl=en),
[Firebase Play Integrity distribution settings](https://firebase.google.com/docs/app-check/android/play-integrity-provider).
