#!/usr/bin/env python3
"""Deny emulator-internal device commands; the run owner is the only ADB driver."""

import os
import subprocess
import sys
from pathlib import Path


def main(args=None):
    args = sys.argv[1:] if args is None else args
    if args == ['version']:
        # Host-only query used to detect SDK compatibility. No device selector,
        # implicit -e/-d, server reset or shell command is ever forwarded.
        return subprocess.run([Path(os.environ['ANDROID_HOME']) / 'platform-tools/adb', 'version'],
                              timeout=5, check=False).returncode
    print('Automatic emulator ADB device commands are disabled; use the run-owned driver.', file=sys.stderr)
    return 1


if __name__ == '__main__':
    sys.exit(main())
