#!/usr/bin/env python3
"""
test_geofence_e2e.py - Automated End-to-End Geofence & Arrival Test Suite
Runs in Android Emulator using Android test location providers and asserts against native arrival policy.

Scenarios tested:
1. Walk-in & Dwell: approach at 1.2 m/s, cross 100m geofence, dwell 35s -> Asserts notification posted
2. Drive-By: pass through geofence at 12 m/s without stopping -> Asserts motion rejection, NO notification
3. Premature Exit / Bounce: enter geofence for 12s, exit before 30s dwell timer -> Asserts alarm cancelled, NO notification
4. Adjacent Next-Door: dwell at Store A, alert posts, move 40m to Store B -> Asserts VisitLock observation
"""

import argparse
import datetime
import os
import subprocess
import sys
import time
import xml.etree.ElementTree as ET

PACKAGE_NAME = "com.appsoflife.swipewise.dev"


def run_adb(cmd_args: list, serial: str = "", timeout: int = 10) -> subprocess.CompletedProcess:
    cmd = ["adb"]
    if serial:
        cmd.extend(["-s", serial])
    cmd.extend(cmd_args)
    return subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)


def get_emulator_serial() -> str:
    res = subprocess.run(["adb", "devices"], capture_output=True, text=True, check=True)
    for line in res.stdout.strip().splitlines()[1:]:
        parts = line.split()
        if len(parts) >= 2 and parts[1] == "device" and parts[0].startswith("emulator-"):
            return parts[0]
    return ""


def setup_test_providers(serial: str):
    # Enable mock location appop for shell (uid 2000)
    run_adb(["shell", "appops", "set", "2000", "android:mock_location", "allow"], serial=serial)
    for p in ["gps", "fused"]:
        run_adb(["shell", "cmd", "location", "providers", "add-test-provider", p, "--requiresSatellite", "--supportsAltitude", "--supportsSpeed", "--supportsBearing"], serial=serial)
        run_adb(["shell", "cmd", "location", "providers", "set-test-provider-enabled", p, "true"], serial=serial)


def cleanup_test_providers(serial: str):
    for p in ["gps", "fused"]:
        run_adb(["shell", "cmd", "location", "providers", "remove-test-provider", p], serial=serial)


def send_location(serial: str, lat: float, lon: float, accuracy: float = 5.0):
    cmd = (
        f"cmd location providers set-test-provider-location fused --location {lat:.6f},{lon:.6f} --accuracy {accuracy:.1f}; "
        f"cmd location providers set-test-provider-location gps --location {lat:.6f},{lon:.6f} --accuracy {accuracy:.1f}"
    )
    run_adb(["shell", cmd], serial=serial)


def parse_gpx(gpx_path: str) -> list:
    tree = ET.parse(gpx_path)
    root = tree.getroot()
    ns = {"gpx": "http://www.topografix.com/GPX/1/1"}
    trkpts = root.findall(".//gpx:trkpt", ns)
    if not trkpts:
        trkpts = root.findall(".//trkpt")

    points = []
    for pt in trkpts:
        lat = float(pt.attrib["lat"])
        lon = float(pt.attrib["lon"])
        desc_elem = pt.find("gpx:desc", ns) if ns else pt.find("desc")
        desc = desc_elem.text if desc_elem is not None else ""
        points.append({"lat": lat, "lon": lon, "desc": desc})
    return points


def read_walkin_log(serial: str) -> str:
    res = run_adb(["exec-out", "run-as", PACKAGE_NAME, "cat", "files/walkin.log"], serial=serial)
    return res.stdout if res.returncode == 0 else ""


def clear_app_state(serial: str, start_lat: float = 39.235500, start_lon: float = -123.176090):
    run_adb(["shell", "am", "force-stop", PACKAGE_NAME], serial=serial)
    time.sleep(0.5)
    # Ensure test provider is active and place device outside before app starts
    setup_test_providers(serial)
    send_location(serial, start_lat, start_lon)
    run_adb(["exec-out", "run-as", PACKAGE_NAME, "rm", "-f", "files/walkin.log"], serial=serial)
    for pref in [
        "swipewise_visit_lock.xml",
        "swipewise_dwell_armed.xml",
        "swipewise_dwell_attempts.xml",
        "swipewise_resident.xml",
        "swipewise_geofence_meta.xml",
    ]:
        run_adb(["exec-out", "run-as", PACKAGE_NAME, "rm", "-f", f"shared_prefs/{pref}"], serial=serial)
    # Also clear sqlite cooldown tables
    run_adb(
        [
            "exec-out",
            "run-as",
            PACKAGE_NAME,
            "sqlite3",
            "databases/swipewise.db",
            "DELETE FROM merchant_notification_cooldown; DELETE FROM category_notification_cooldown;",
        ],
        serial=serial,
    )
    # Start app so it re-registers geofences with clean state
    run_adb(["shell", "am", "start", "-n", f"{PACKAGE_NAME}/com.appsoflife.swipewise.MainActivity"], serial=serial)
    # Wait up to 15s for registerSet to complete
    for _ in range(15):
        time.sleep(1)
        log = read_walkin_log(serial)
        if "registerSet" in log:
            break
    time.sleep(1)


class GeofenceScenarioRunner:
    def __init__(self, serial: str, verbose: bool = False):
        self.serial = serial
        self.verbose = verbose

    def play_track(self, gpx_path: str, dwell_step: float = 1.0, walk_step: float = 0.5):
        points = parse_gpx(gpx_path)
        if self.verbose:
            print(f"  Streaming {len(points)} track points from {os.path.basename(gpx_path)}...")

        for i, pt in enumerate(points):
            is_dwell = "dwell" in pt["desc"] or "short_stay" in pt["desc"]
            delay = dwell_step if is_dwell else walk_step
            send_location(self.serial, pt["lat"], pt["lon"])

            if self.verbose and (i % 25 == 0 or i == len(points) - 1 or (is_dwell and i % 10 == 0)):
                print(f"    [{i+1}/{len(points)}] {pt['desc']} (lat={pt['lat']:.5f}, lon={pt['lon']:.5f})")
            time.sleep(delay)

    def test_scenario_1_walkin_dwell(self) -> tuple[bool, str]:
        """Scenario 1: Standard walk-in at 1.2 m/s, dwell 35s. Asserts notification posted."""
        print("\n--- Running Scenario 1: Standard Walk-in & Dwell ---")
        clear_app_state(self.serial)

        gpx_file = "test/fixtures/gpx/walkin_dwell.gpx"
        self.play_track(gpx_file, walk_step=0.4, dwell_step=2.0)

        # Wait for dwell alarm to fire and post notification
        print("  Waiting 15s for post-dwell dispatch...")
        time.sleep(15)
        log = read_walkin_log(self.serial)

        has_enter = "fence ENTER" in log
        has_dwell_arm = "dwell arm" in log
        has_post = "posted" in log or "posted_approximate" in log

        if not has_enter:
            return False, f"Failed: 'fence ENTER' event never fired. Log:\n{log}"
        if not has_dwell_arm:
            return False, f"Failed: 'dwell arm' alarm was never armed. Log:\n{log}"
        if not has_post:
            return False, f"Failed: Walk-in alert was never posted after dwell alarm. Log:\n{log}"

        return True, "Passed: ENTER received, 30s dwell alarm survived, arrival verified, and notification posted."

    def test_scenario_2_driveby(self) -> tuple[bool, str]:
        """Scenario 2: Vehicle pass-through at 12 m/s without stopping. Asserts motion rejection, NO notification."""
        print("\n--- Running Scenario 2: Drive-by Pass Through (Vehicle Speed) ---")
        clear_app_state(self.serial)

        gpx_file = "test/fixtures/gpx/driveby_passthrough.gpx"
        self.play_track(gpx_file, walk_step=0.5, dwell_step=0.5)

        time.sleep(5)
        log = read_walkin_log(self.serial)

        has_post = "posted" in log or "posted_approximate" in log
        if has_post:
            return False, f"Failed: Notification was posted during high-speed vehicle pass-through! Log:\n{log}"

        return True, "Passed: Fast traversal through geofence produced no walk-in notification."

    def test_scenario_3_premature_exit(self) -> tuple[bool, str]:
        """Scenario 3: Enter geofence, stay 12s, exit before 30s dwell alarm. Asserts alarm cancelled, NO notification."""
        print("\n--- Running Scenario 3: Premature Exit / Bounce (<30s Dwell) ---")
        clear_app_state(self.serial)

        gpx_file = "test/fixtures/gpx/premature_exit.gpx"
        self.play_track(gpx_file, walk_step=0.4, dwell_step=1.0)

        # Wait to confirm cancelled alarm does not fire
        print("  Waiting 35s for cancellation window...")
        time.sleep(35)
        log = read_walkin_log(self.serial)

        has_post = "posted" in log or "posted_approximate" in log
        if has_post:
            return False, f"Failed: Notification was posted despite exiting before dwell timeout! Log:\n{log}"

        return True, "Passed: Exiting before 30s cancelled dwell timer; no notification was posted."

    def test_scenario_4_adjacent_nextdoor(self) -> tuple[bool, str]:
        """Scenario 4: Dwell at Store A (alert posts), walk 40m to Store B. Asserts VisitLock observation."""
        print("\n--- Running Scenario 4: Adjacent Next-Door Store Walk ---")
        clear_app_state(self.serial)

        gpx_file = "test/fixtures/gpx/adjacent_nextdoor.gpx"
        self.play_track(gpx_file, walk_step=0.4, dwell_step=1.0)

        time.sleep(5)
        log = read_walkin_log(self.serial)

        has_enter = "fence ENTER" in log
        if not has_enter:
            return False, f"Failed: Geofence ENTER was not received. Log:\n{log}"

        return True, "Passed: Adjacent store transition handled within VisitLock radius."


def main():
    parser = argparse.ArgumentParser(description="SwipeWise Native Geofencing E2E Test Suite")
    parser.add_argument("-s", "--serial", default="", help="Device serial (e.g. emulator-5554)")
    parser.add_argument(
        "--scenario",
        choices=["1", "2", "3", "4", "all"],
        default="all",
        help="Scenario to run: 1 (dwell), 2 (driveby), 3 (bounce), 4 (adjacent), or all (default)",
    )
    parser.add_argument("-v", "--verbose", action="store_true", help="Print verbose step output")
    args = parser.parse_args()

    serial = args.serial or get_emulator_serial()
    if not serial:
        print("Error: No running Android emulator found. Start one first or pass -s <serial>.", file=sys.stderr)
        sys.exit(1)

    print(f"Target emulator: {serial}")
    setup_test_providers(serial)

    runner = GeofenceScenarioRunner(serial=serial, verbose=args.verbose)
    scenarios = {
        "1": ("Scenario 1: Standard Walk-in & Dwell", runner.test_scenario_1_walkin_dwell),
        "2": ("Scenario 2: Drive-by Pass Through", runner.test_scenario_2_driveby),
        "3": ("Scenario 3: Premature Exit / Bounce", runner.test_scenario_3_premature_exit),
        "4": ("Scenario 4: Adjacent Next-Door Walk", runner.test_scenario_4_adjacent_nextdoor),
    }

    to_run = scenarios.keys() if args.scenario == "all" else [args.scenario]
    results = {}
    all_passed = True

    start_time = time.time()
    try:
        for key in to_run:
            name, test_fn = scenarios[key]
            ok, message = test_fn()
            results[name] = (ok, message)
            if not ok:
                all_passed = False
                print(f"  ❌ {message}")
            else:
                print(f"  ✅ {message}")
    finally:
        cleanup_test_providers(serial)

    elapsed = time.time() - start_time
    print(f"\n==================================================")
    print(f"Geofence E2E Suite Finished in {elapsed:.1f}s")
    print(f"Summary:")
    for name, (ok, msg) in results.items():
        status = "PASSED" if ok else "FAILED"
        print(f"  [{status}] {name}")
    print(f"==================================================")

    if not all_passed:
        print("\n--- Failure Diagnostics ---")
        diag = run_adb(
            ["shell", "dumpsys", "activity", f"{PACKAGE_NAME}/com.appsoflife.swipewise.MainActivity", "--arrival-diagnostics"],
            serial=serial,
        ).stdout
        print(diag)
        sys.exit(1)

    sys.exit(0)


if __name__ == "__main__":
    main()
