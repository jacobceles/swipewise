"""Offline regression tests: python3 -m unittest discover -s tool -p 'test_*.py'."""

import contextlib
import io
import json
import sys
import tempfile
import unittest
import zipfile
from pathlib import Path
from unittest.mock import patch

import prepare_github_release as prepare
import verify_release_apk as gate


class PrepareReleaseTest(unittest.TestCase):
    def test_only_published_production_version_is_accepted(self):
        release = {
            "releaseLifecycleState": "RELEASE_LIFECYCLE_STATE_PUBLISHED",
            "activeArtifacts": [{"versionCode": 24}],
        }
        prepare.require_production({"releases": [release]}, 24)
        for data in ({}, {"releases": [release | {"activeArtifacts": []}]},
                     {"releases": [release | {"activeArtifacts": [{"versionCode": 23}]}]},
                     {"releases": [release | {"releaseLifecycleState": "DRAFT"}]}):
            with self.subTest(data=data), self.assertRaises(ValueError):
                prepare.require_production(data, 24)

    def test_universal_requires_exactly_one_pinned_signer(self):
        artifact = {"certificateSha256Hash": prepare.PLAY_CERT_SHA256,
                    "generatedUniversalApk": {"downloadId": "example"}}
        self.assertEqual(prepare.select_universal({"generatedApks": [artifact]}), artifact)
        for artifacts in ([], [artifact, artifact], [artifact | {"certificateSha256Hash": "wrong"}],
                          [artifact | {"generatedUniversalApk": {}}]):
            with self.subTest(artifacts=artifacts), self.assertRaises(ValueError):
                prepare.select_universal({"generatedApks": artifacts})

    def test_apk_identity_and_actual_signer_are_checked(self):
        badging = f"package: name='{prepare.PACKAGE}' versionCode='24' versionName='1.0.14'"
        signer = f"Signer #1 certificate SHA-256 digest: {prepare.PLAY_CERT_SHA256}"
        prepare.verify_identity(badging, signer, "1.0.14", 24)
        for text, cert in ((badging.replace(prepare.PACKAGE, 'wrong'), signer),
                           (badging.replace("'24'", "'23'"), signer),
                           (badging.replace('1.0.14', '1.0.13'), signer),
                           (badging, signer.replace(prepare.PLAY_CERT_SHA256, 'bad')),
                           (badging, signer + "\nSigner #2 certificate SHA-256 digest: bad")):
            with self.subTest(text=text, cert=cert), self.assertRaises(ValueError):
                prepare.verify_identity(text, cert, "1.0.14", 24)

    def test_detects_injected_play_licensing(self):
        with tempfile.TemporaryDirectory() as directory:
            apk = Path(directory) / "app.apk"
            for dex, expected in ((b"normal app", False), (b"com/pairip/licensecheck/LicenseClient", True)):
                with zipfile.ZipFile(apk, "w") as archive:
                    archive.writestr("classes2.dex", dex)
                self.assertEqual(prepare.has_play_licensing(apk), expected)

    def test_find_build_tools_locates_sdk(self):
        tools = prepare.find_build_tools()
        if tools:
            self.assertTrue((tools / "apksigner").exists())


class ReleaseGateTest(unittest.TestCase):
    def run_gate(self, directory, overrides=None, blobs=None, input_only=False):
        keys = Path(directory) / "keys.json"
        keys.write_text(json.dumps({"PLACES_PROXY_URL": "https://example.com/places",
                                    "R2_BASE_URL": "https://example.com", **(overrides or {})}))
        apk = Path(directory) / "downloaded.apk"
        with zipfile.ZipFile(apk, "w") as archive:
            for index, blob in enumerate(blobs or ["\n".join(gate.MUST_BE_PRESENT.values()).encode()]):
                archive.writestr(f"lib/{index}.so", blob)
        argv = ["verify_release_apk.py", str(keys), "--apk", str(apk)]
        if input_only:
            argv.append("--input-only")
        with patch.object(sys, "argv", argv), patch.object(gate, "google_services_keys", return_value=set()), \
                patch.object(gate, "EXPECTED_KEYSET_SHA256", gate.keyset_digest(set())), \
                patch.object(gate.os.path, "exists", side_effect=lambda p: p != "keys.pro.json" and Path(p).exists()), \
                contextlib.redirect_stdout(io.StringIO()):
            return gate.main()

    def test_external_apk_path_is_scanned(self):
        with tempfile.TemporaryDirectory() as directory:
            self.assertEqual(self.run_gate(directory), 0)
            for needle in ("FIApiAUTH", "AIza" + "x" * 35):
                blobs = [("\n".join(gate.MUST_BE_PRESENT.values()) + needle).encode()]
                self.assertEqual(self.run_gate(directory, blobs=blobs), 1)

    def test_empty_binary_fails_presence_checks(self):
        with tempfile.TemporaryDirectory() as directory:
            self.assertNotEqual(self.run_gate(directory, blobs=[b"empty"]), 0)

    def test_rejects_debug_tokens_pro_override_and_credentials(self):
        with tempfile.TemporaryDirectory() as directory:
            for key in ("SOPHTRON_USER_ID", "SOPHTRON_ACCESS_KEY", "SOPHTRON_CUSTOMER_SALT",
                        "GOOGLE_PLACES_KEY", "APP_CHECK_DEBUG_TOKEN", "SWIPEWISE_PRO"):
                with self.subTest(key=key):
                    self.assertEqual(self.run_gate(directory, {key: "true"}, input_only=True), 1)
            self.assertEqual(self.run_gate(directory, {"SWIPEWISE_PRO": "false"}, input_only=True), 0)

    def test_utf16_strings_are_scanned(self):
        with tempfile.TemporaryDirectory() as directory:
            text = "\n".join(gate.MUST_BE_PRESENT.values())
            self.assertEqual(self.run_gate(directory, blobs=[text.encode('utf-16-le')]), 0)
            self.assertEqual(self.run_gate(directory, blobs=[(text + 'FIApiAUTH').encode('utf-16-le')]), 1)


if __name__ == "__main__":
    unittest.main()
