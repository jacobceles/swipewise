#!/usr/bin/env python3
"""Release gate: prove the published APK carries no aggregator credentials.

    flutter clean
    flutter build apk --release --dart-define-from-file=keys.free.json \
        --obfuscate --split-debug-info=build/symbols
    python3 tool/verify_release_apk.py [keys-file]

## What this claims

SwipeWise ships **one binary for both tiers**, because Pro is sold as an in-app
subscription — nobody subscribes in app A and installs app B. So the Pro code,
including the bank-sync engine and the aggregator's base URL, is *present and
dormant* in the app everyone installs. That is by design and not a fault.

What must never ship is the **credentials**. They arrive only through
`--dart-define-from-file`, so a release built from a keys file that has none is
a release that cannot carry them. The failure mode this exists to catch is a
one-word mistake — passing `keys.pro.json` to a release build — which produces a
perfectly working APK with every secret inside it and nothing about the artifact
looking wrong.

## Why it checks the input, not the secret values

An earlier version grepped the APK for the real credential strings, which meant
uploading them to CI so the check could run there. That is a bad trade: it puts
live credentials somewhere a bad workflow edit could read them, to catch a
mistake that is fully visible in the build *input*. A secret that does not exist
cannot leak.

So the primary check reads the keys file and refuses if it carries aggregator
credentials. Locally — where `keys.pro.json` legitimately exists — it *also*
greps the APK for the real values, which is strictly stronger and costs nothing
because the file is already on disk. In CI that half is skipped and says so.

## Why the Firebase key set is pinned

The APK scan needs an allowlist of keys that may legitimately ship, and takes it
from google-services.json. That file is not a fixed point: Firebase repoints an
app's `apiKeyId` when the key it named is deleted, which rewrites it — and the
scan would then declare the *new* key accounted for, against itself. So the
allowlist is pinned by digest. This catches our own silent config drift, not an
attacker; the keys are public by design and already committed twice over, which
is why a digest is pinned rather than the values.

## Two traps that produced confident wrong answers before this existed

1. **Both string encodings must be checked.** Dart stores a string one byte per
   character only when it is pure ASCII; any non-ASCII character (an em dash, a
   curly apostrophe) makes the whole string UTF-16. A one-byte-only scan reports
   such a string as absent — which reads as "we're clean" for an absence check
   and "the feature was stripped" for a presence check.
2. **The release build can serve a stale Dart snapshot.** Run `flutter clean`
   first, or this verifies an old binary and tells you nothing.

Exits non-zero on any failure.
"""

import hashlib
import json
import os
import re
import shutil
import sys
import zipfile

APK = "build/app/outputs/flutter-apk/app-release.apk"
EXTRACT_TO = "/tmp/swipewise-release-apk-scan"

# Any key whose presence in a release build's keys file is disqualifying.
#
# GOOGLE_PLACES_KEY joined this list on 2026-08-10, when Places moved behind the
# Worker. It is the likeliest regression of the lot: nearby search breaking for
# an unrelated reason looks exactly like a missing key, and putting it back
# "just to test" produces a working app that has quietly resumed shipping a
# credential. The proxy is the fix; the key never needs to return.
CREDENTIAL_KEYS = (
    "SOPHTRON_USER_ID",
    "SOPHTRON_ACCESS_KEY",
    "SOPHTRON_CUSTOMER_SALT",
    "GOOGLE_PLACES_KEY",
)

# Config the release cannot work without. Absence here is not a leak, but it
# ships an app whose Stores tab is dead, which is worth failing the build over.
REQUIRED_KEYS = ("PLACES_PROXY_URL", "R2_BASE_URL")

# Derived material — would only appear if credentials were used at build time.
MUST_BE_ABSENT = {"HMAC auth scheme": "FIApiAUTH"}

# Google API keys legitimately present in a release: the Firebase key the
# Gradle plugin bakes in from google-services.json. Any OTHER `AIza...` string
# is an unaccounted credential — most likely a Places key that came back.
GOOGLE_SERVICES_JSON = "android/app/google-services.json"
API_KEY_RE = re.compile(rb"AIza[0-9A-Za-z_\-]{35}")

# sha256 over the newline-joined, sorted key strings in google-services.json —
# stable across reformatting and client reordering. Update it deliberately, and
# only once you have confirmed the new key set is the one you meant to ship.
EXPECTED_KEYSET_SHA256 = "799b2b44f9efab5b3b4741632da90c0adf4efcd55dba6869a157cc1698f65d37"

# A binary that shipped nothing would pass every absence check, so pin the
# features that make this the app rather than an empty shell.
MUST_BE_PRESENT = {
    "wallet flow": "Pick the issuer of the card",
    "advisor empty state": "Add a card to see recommendations.",
    "Play background-location disclosure": "even when the app is closed or not in use",
    "cards empty state": "Add the cards you carry",
}


def load_blobs(apk: str) -> list[bytes]:
    shutil.rmtree(EXTRACT_TO, ignore_errors=True)
    with zipfile.ZipFile(apk) as z:
        z.extractall(EXTRACT_TO)
    blobs = []
    for root, _, files in os.walk(EXTRACT_TO):
        for name in files:
            with open(os.path.join(root, name), "rb") as fh:
                blobs.append(fh.read())
    return blobs


def google_services_keys() -> set[str]:
    gs = json.load(open(GOOGLE_SERVICES_JSON))
    return {k["current_key"] for c in gs.get("client", []) for k in c.get("api_key", [])}


def keyset_digest(keys: set[str]) -> str:
    return hashlib.sha256("\n".join(sorted(keys)).encode()).hexdigest()


def occurrences(blobs: list[bytes], needle: str) -> int:
    return sum(
        any(needle.encode(enc) in blob for enc in ("utf-8", "utf-16-le"))
        for blob in blobs
    )


def main() -> int:
    args = [a for a in sys.argv[1:] if a != "--input-only"]
    input_only = "--input-only" in sys.argv
    keys_path = args[0] if args else "keys.free.json"
    failures = 0

    # ── 1. The build input. This is the check that catches the real mistake.
    print(f"build input — {keys_path}:")
    try:
        keys = json.load(open(keys_path))
    except (OSError, json.JSONDecodeError) as exc:
        print(f"  FAIL  unreadable ({exc}) — cannot verify what the build used")
        return 1

    present = [k for k in CREDENTIAL_KEYS if keys.get(k)]
    if present:
        print(f"  FAIL  carries credentials that must not ship: {present}")
        print("        A release must be built from a keys file without them.")
        failures += 1
    else:
        print(f"  ok    no disqualifying credentials in {keys_path}")

    missing = [k for k in REQUIRED_KEYS if not keys.get(k)]
    if missing:
        print(f"  FAIL  missing required config: {missing}")
        print("        The build would ship with a dead Stores tab.")
        failures += 1
    else:
        print(f"  ok    required config present: {list(REQUIRED_KEYS)}")

    # ── 1b. Pin the allowlist that step 3b trusts. Reads one committed file, so
    #     it runs on the pre-commit path too — the earliest point a repoint shows up.
    print("\nFirebase key set — android/app/google-services.json:")
    try:
        gs_keys = google_services_keys()
    except (OSError, json.JSONDecodeError, KeyError) as exc:
        print(f"  FAIL  unreadable ({exc}) — cannot trust the APK key allowlist")
        gs_keys = set()
        failures += 1
    else:
        digest = keyset_digest(gs_keys)
        if digest == EXPECTED_KEYSET_SHA256:
            print(f"  ok    {len(gs_keys)} key(s), digest matches")
        else:
            print(f"  FAIL  key set changed — {digest[:16]}...")
            print(f"        expected              {EXPECTED_KEYSET_SHA256[:16]}...")
            print("        Firebase repoints an app's key when the one it named is")
            print("        deleted. Confirm the new set is what you meant to ship,")
            print("        then update EXPECTED_KEYSET_SHA256 in this file.")
            failures += 1

    if input_only:
        # Pre-commit path: the keys file is checkable in milliseconds and is
        # where a credential would first appear. The APK half needs a release
        # build and stays in CI.
        print(f"\n{'ALL CLEAR (input only)' if not failures else f'{failures} FAILURE(S)'}")
        return 1 if failures else 0

    if not os.path.exists(APK):
        print(f"\nNo APK at {APK} — build it first (see this file's docstring).")
        return 2
    blobs = load_blobs(APK)

    # ── 2. Derived material that would betray credentials used at build time.
    print("\nabsent in the APK:")
    for label, needle in MUST_BE_ABSENT.items():
        n = occurrences(blobs, needle)
        failures += bool(n)
        print(f"  {'FAIL' if n else 'ok  '}  {label:<34}{n}")

    # ── 3. Deep scan, only where the reference values already live on disk.
    #     Never uploaded anywhere; absent in CI, and said so rather than
    #     quietly passing.
    if os.path.exists("keys.pro.json"):
        print("\ndeep scan (keys.pro.json found locally):")
        try:
            ref = json.load(open("keys.pro.json"))
        except (OSError, json.JSONDecodeError) as exc:
            print(f"  FAIL  keys.pro.json unreadable ({exc})")
            failures += 1
            ref = {}
        for k in CREDENTIAL_KEYS:
            v = ref.get(k)
            if not v:
                continue
            n = occurrences(blobs, v)
            failures += bool(n)
            print(f"  {'FAIL' if n else 'ok  '}  {k:<34}{n}")
    else:
        print("\ndeep scan: SKIPPED — keys.pro.json not present (expected in CI).")
        print("  The input check above is what guards this build.")

    # ── 3b. No Google API key in the binary beyond the ones Firebase bakes in.
    #     This is the check that would catch GOOGLE_PLACES_KEY coming back: the
    #     Gradle plugin emits only google-services.json's api_key[0], so any
    #     other AIza... string arrived some other way and is unaccounted for.
    print("\nGoogle API keys in the APK:")
    allowed = gs_keys  # pinned in step 1b

    seen: set[str] = set()
    for blob in blobs:
        for m in API_KEY_RE.findall(blob):
            seen.add(m.decode())
        for m in API_KEY_RE.findall(blob.decode("utf-16-le", "ignore").encode()):
            seen.add(m.decode())
    unaccounted = sorted(seen - allowed)
    for k in sorted(seen & allowed):
        print(f"  ok    {k[:14]}... (declared in google-services.json)")
    for k in unaccounted:
        print(f"  FAIL  {k[:14]}... UNACCOUNTED — not in google-services.json")
    failures += len(unaccounted)
    if not seen:
        print("  ok    none found")

    # ── 4. Prove it is still the app.
    print("\npresent in the APK:")
    for label, needle in MUST_BE_PRESENT.items():
        n = occurrences(blobs, needle)
        failures += not n
        print(f"  {'ok  ' if n else 'FAIL'}  {label:<34}{n}")

    print(f"\n{'ALL CLEAR' if not failures else f'{failures} FAILURE(S)'}")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
