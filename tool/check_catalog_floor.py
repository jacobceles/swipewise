#!/usr/bin/env python3
"""Fail CI unless the bundled catalog version matches a verified live version.

The API is an intentional dependency of this check. Retry transient failures,
but never turn inability to verify freshness into a passing check.
"""

import json
from pathlib import Path
import subprocess
import time
from urllib.parse import urlparse


def data_version(raw: str) -> int:
    catalog = json.loads(raw)
    version = catalog.get("dataVersion") if isinstance(catalog, dict) else None
    if type(version) is not int or version <= 0:
        raise ValueError("catalog dataVersion must be a positive integer")
    return version


def live_version(url: str) -> int:
    for attempt in range(1, 4):
        try:
            response = subprocess.run(
                [
                    "curl",
                    "--fail",
                    "--silent",
                    "--show-error",
                    "--location",
                    "--connect-timeout",
                    "5",
                    "--max-time",
                    "15",
                    url,
                ],
                capture_output=True,
                text=True,
                check=True,
                timeout=20,
            )
            return data_version(response.stdout)
        except (OSError, subprocess.SubprocessError, ValueError):
            if attempt == 3:
                break
            print(
                f"::warning::Catalog verification attempt {attempt}/3 failed; retrying."
            )
            time.sleep(2)
    raise RuntimeError("Could not fetch a valid live catalog after 3 attempts.")


def main(
    *,
    keys_file: Path = Path("keys.free.json"),
    catalog_file: Path = Path("assets/catalog/free.json"),
) -> int:
    try:
        bundled = data_version(catalog_file.read_text())
        keys = json.loads(keys_file.read_text())
        base = keys.get("R2_BASE_URL") if isinstance(keys, dict) else None
        if (
            not isinstance(base, str)
            or urlparse(base).scheme != "https"
            or not urlparse(base).hostname
        ):
            raise ValueError("keys.free.json must contain a valid HTTPS R2_BASE_URL")
        live = live_version(base.rstrip("/") + "/catalog.json")
    except (OSError, ValueError, RuntimeError) as exc:
        print(f"::error::Cannot verify the bundled catalog: {exc}")
        return 1

    print(f"bundled={bundled} live={live}")
    if bundled != live:
        print(
            "::error::Bundled catalog version differs from the published catalog. "
            "Refresh assets/catalog/free.json from the authoritative build and commit it."
        )
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
