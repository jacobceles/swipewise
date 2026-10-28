#!/usr/bin/env python3
"""Prepare and publish GitHub releases for SwipeWise.

Supports:
  1. Full release with Play universal APK + SHA256SUMS (default, starting v1.0.15)
  2. Release notes + Play Store link only (--no-apk, e.g. for v1.0.14)
  3. Safe preview mode by default (pass --publish to tag and create GitHub release)

Run from the repository root. See docs/github-releases.md for details.
"""

import argparse
import hashlib
import json
import os
import re
import subprocess
import sys
import tempfile
import zipfile
from pathlib import Path

PACKAGE = "com.appsoflife.swipewise"
# Public Play app-signing certificate, not the upload certificate. Changes need
# an explicit signing-key-rotation review, not an automatic Firebase lookup.
PLAY_CERT_SHA256 = "c4623ef13b216a35291add440ffef15ec408ada400465d697a440186ccb1525f"


def run(*args: str) -> str:
    return subprocess.check_output(args, text=True)


def require_production(releases: dict, version_code: int) -> None:
    for release in releases.get("releases", []):
        if release.get("releaseLifecycleState") == "RELEASE_LIFECYCLE_STATE_PUBLISHED":
            if any(
                int(a["versionCode"]) == version_code
                for a in release.get("activeArtifacts", [])
            ):
                return
    raise ValueError("Requested version is not an active published production release")


def select_universal(metadata: dict) -> dict:
    matches = [
        a for a in metadata.get("generatedApks", [])
        if a.get("certificateSha256Hash", "").replace(":", "").lower()
        == PLAY_CERT_SHA256 and a.get("generatedUniversalApk", {}).get("downloadId")
    ]
    if len(matches) != 1:
        raise ValueError("Expected exactly one universal APK signed by the pinned Play key")
    return matches[0]


def verify_identity(badging: str, certificates: str, version: str, code: int) -> None:
    identity = re.search(
        r"^package: name='([^']+)' versionCode='([^']+)' versionName='([^']+)'",
        badging, re.MULTILINE,
    )
    if not identity or identity.groups() != (PACKAGE, str(code), version):
        raise ValueError("Downloaded APK package/version does not match the source reference")
    signers = re.findall(
        r"^Signer #\d+ certificate SHA-256 digest: ([0-9a-f]+)$",
        certificates, re.MULTILINE,
    )
    if signers != [PLAY_CERT_SHA256]:
        raise ValueError("APK signature does not match the pinned Play app-signing certificate")


def has_play_licensing(apk: Path) -> bool:
    with zipfile.ZipFile(apk) as archive:
        return any(
            b"com/pairip/licensecheck" in archive.read(name)
            for name in archive.namelist() if re.fullmatch(r"classes\d*\.dex", name)
        )


def find_build_tools() -> Path | None:
    env = os.environ.get("ANDROID_HOME") or os.environ.get("ANDROID_SDK_ROOT")
    paths = []
    if env:
        paths.append(Path(env) / "build-tools")
    paths.append(Path("/opt/homebrew/share/android-commandlinetools/build-tools"))
    for base in paths:
        if base.is_dir():
            versions = sorted([p for p in base.iterdir() if p.is_dir()], reverse=True)
            if versions:
                return versions[0]
    return None


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--version-code", type=int, help="Version code (default: read from pubspec.yaml)")
    parser.add_argument("--source-ref", default="HEAD", help="Source commit or tag (default: HEAD)")
    parser.add_argument("--build-tools", type=Path, help="Android SDK build-tools directory (default: auto-detected)")
    parser.add_argument("--output", type=Path, help="Output directory (default: auto-created temporary directory)")
    parser.add_argument("--no-apk", action="store_true", help="Release changelog and Play Store link only, without attaching an APK")
    parser.add_argument("--publish", action="store_true", help="Publish the GitHub release and tag (default: prepare and preview only)")
    args = parser.parse_args()

    root = Path(__file__).resolve().parents[1]
    if Path.cwd().resolve() != root:
        raise ValueError("Run from the repository root")

    commit = run("git", "rev-parse", "--verify", f"{args.source_ref}^{{commit}}").strip()
    pubspec = run("git", "show", f"{commit}:pubspec.yaml")
    match = re.search(r"^version: (\d+\.\d+\.\d+)\+(\d+)\s*$", pubspec, re.MULTILINE)
    if not match:
        raise ValueError(f"Could not parse version from pubspec.yaml in {commit}")

    version = match[1]
    version_code = args.version_code or int(match[2])
    if int(match[2]) != version_code:
        raise ValueError(f"Source commit version code ({match[2]}) does not match requested code ({version_code})")

    notes = json.loads(run("git", "show", f"{commit}:release-notes.json"))
    changelog = next(n["text"] for n in notes if n["language"] == "en-US")

    tag_name = f"v{version}"

    if args.output:
        output = args.output.resolve()
        if output.is_relative_to(root):
            raise ValueError("Keep release artifacts outside the source checkout")
        if output.exists():
            raise ValueError("Output directory already exists; choose a new directory")
        output.mkdir(parents=True)
    else:
        output = Path(tempfile.mkdtemp(prefix=f"swipewise-release-{version}-"))

    if args.no_apk:
        release_notes = (
            f"# SwipeWise {version}\n\n{changelog}\n\n"
            "## Download\n\n"
            "[Google Play](https://play.google.com/store/apps/details?id=com.appsoflife.swipewise) "
            "is the official distribution channel for SwipeWise.\n"
        )
        (output / "RELEASE_NOTES.md").write_text(release_notes)
        manifest = {
            "package": PACKAGE,
            "version": version,
            "version_code": version_code,
            "tag": tag_name,
            "commit": commit,
            "no_apk": True,
            "publication_status": "ready" if args.publish else "preview",
        }
        (output / "verification.json").write_text(json.dumps(manifest, indent=2) + "\n")
        print(json.dumps(manifest, indent=2))
        print(f"Notes prepared at: {output / 'RELEASE_NOTES.md'}")

        if args.publish:
            print(f"Publishing GitHub release {tag_name}...")
            run("git", "tag", "-a", tag_name, commit, "-m", f"SwipeWise {version}")
            run("git", "push", "origin", tag_name)
            run(
                "gh", "release", "create", tag_name,
                "--title", f"SwipeWise {version}",
                "--notes-file", str(output / "RELEASE_NOTES.md"),
            )
            print(f"Published GitHub release {tag_name}!")
        else:
            print("Preview only. Pass --publish to create tag and release.")
        return 0

    build_tools = args.build_tools or find_build_tools()
    if not build_tools:
        raise ValueError("Could not auto-detect Android build-tools; pass --build-tools")
    for tool_name in ("aapt", "apksigner"):
        if not (build_tools / tool_name).is_file():
            raise ValueError(f"Missing Android build tool: {tool_name} in {build_tools}")

    releases = json.loads(run("gplay", "tracks", "releases", "list", "--package", PACKAGE, "--track", "production"))
    require_production(releases, version_code)
    metadata = json.loads(run("gplay", "generated-apks", "list", "--package", PACKAGE, "--version-code", str(version_code)))
    artifact = select_universal(metadata)

    download = json.loads(run(
        "gplay", "generated-apks", "download", "--package", PACKAGE,
        "--version-code", str(version_code), "--download-id",
        artifact["generatedUniversalApk"]["downloadId"], "--output", str(output),
    ))
    downloaded = Path(download["path"]).resolve()
    if not downloaded.is_relative_to(output) or not download.get("downloaded"):
        raise ValueError("Unexpected download result")

    apk = output / f"SwipeWise-{version}-{version_code}.apk"
    downloaded.rename(apk)
    certificates = run(str(build_tools / "apksigner"), "verify", "--print-certs", str(apk))
    badging = run(str(build_tools / "aapt"), "dump", "badging", str(apk))
    verify_identity(badging, certificates, version, version_code)
    scan = run(sys.executable, "tool/verify_release_apk.py", "--apk", str(apk))
    licensing = has_play_licensing(apk)
    with apk.open("rb") as file:
        digest = hashlib.file_digest(file, "sha256").hexdigest()
    (output / "SHA256SUMS").write_text(f"{digest}  {apk.name}\n")
    (output / "verification.txt").write_text(certificates + "\n" + badging + "\n" + scan)

    manifest = {
        "package": PACKAGE,
        "version": version,
        "version_code": version_code,
        "tag": tag_name,
        "commit": commit,
        "apk": apk.name,
        "sha256": digest,
        "signing_certificate_sha256": PLAY_CERT_SHA256,
        "play_licensing_detected": licensing,
        "publication_status": "blocked-play-licensing" if licensing else ("ready" if args.publish else "preview"),
    }
    (output / "verification.json").write_text(json.dumps(manifest, indent=2) + "\n")

    release_notes = (
        f"# SwipeWise {version}\n\n{changelog}\n\n"
        "## Download\n\n"
        "[Google Play](https://play.google.com/store/apps/details?id=com.appsoflife.swipewise) "
        "is the recommended way to install and receive automatic updates.\n\n"
        f"For manual installation, download `{apk.name}` below. Android 7.0+ is required. "
        "This is Google's signed universal APK from the same production release, not a separate GitHub build.\n\n"
        "GitHub downloads do not include an automatic updater. Install newer APKs over the existing app; "
        "do not uninstall first, because that removes local data.\n\n"
        "`SHA256SUMS` contains the APK checksum.\n"
    )
    (output / "RELEASE_NOTES.md").write_text(release_notes)

    print(json.dumps(manifest, indent=2))
    print(f"Artifacts prepared at: {output}")

    if licensing and args.publish:
        raise ValueError("Cannot publish: Play licensing check is detected in the APK. Make sure Automatic Protection is off in Play Console for this release.")

    if args.publish:
        print(f"Publishing GitHub release {tag_name}...")
        run("git", "tag", "-a", tag_name, commit, "-m", f"SwipeWise {version}")
        run("git", "push", "origin", tag_name)
        run(
            "gh", "release", "create", tag_name,
            str(apk), str(output / "SHA256SUMS"),
            "--title", f"SwipeWise {version}",
            "--notes-file", str(output / "RELEASE_NOTES.md"),
        )
        print(f"Published GitHub release {tag_name} with APK!")
    else:
        print("Preview only. Pass --publish to create tag and release.")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (ValueError, subprocess.CalledProcessError) as exc:
        sys.exit(str(exc))
