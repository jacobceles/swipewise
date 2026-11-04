#!/usr/bin/env python3
"""
play_gpx_route.py - Play a GPX route into an Android Emulator via adb emu geo nmea or geo fix.
Streams coordinates point-by-point to simulate realistic movement and dwell.
"""

import argparse
import datetime
import subprocess
import sys
import time
import xml.etree.ElementTree as ET


def parse_gpx(gpx_path: str):
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
        ele_elem = pt.find("gpx:ele", ns) if ns else pt.find("ele")
        ele = float(ele_elem.text) if ele_elem is not None else 0.0
        time_elem = pt.find("gpx:time", ns) if ns else pt.find("time")
        desc_elem = pt.find("gpx:desc", ns) if ns else pt.find("desc")
        desc = desc_elem.text if desc_elem is not None else ""
        points.append({"lat": lat, "lon": lon, "ele": ele, "desc": desc})

    return points


def nmea_checksum(sentence: str) -> str:
    c = 0
    for ch in sentence:
        c ^= ord(ch)
    return f"{c:02X}"


def format_nmea_rmc(lat: float, lon: float, speed_knots: float = 0.5) -> str:
    lat_deg = int(abs(lat))
    lat_min = (abs(lat) - lat_deg) * 60.0
    lat_hemi = "N" if lat >= 0 else "S"
    lat_str = f"{lat_deg:02d}{lat_min:07.4f}"

    lon_deg = int(abs(lon))
    lon_min = (abs(lon) - lon_deg) * 60.0
    lon_hemi = "E" if lon >= 0 else "W"
    lon_str = f"{lon_deg:03d}{lon_min:07.4f}"

    now_utc = datetime.datetime.now(datetime.timezone.utc)
    time_str = now_utc.strftime("%H%M%S.00")
    date_str = now_utc.strftime("%d%m%y")

    raw = f"GPRMC,{time_str},A,{lat_str},{lat_hemi},{lon_str},{lon_hemi},{speed_knots:.1f},0.0,{date_str},,,A"
    return f"${raw}*{nmea_checksum(raw)}"


def send_location(serial: str, lon: float, lat: float, ele: float = 0.0, mode: str = "nmea"):
    cmd = ["adb"]
    if serial:
        cmd.extend(["-s", serial])

    if mode == "nmea":
        sentence = format_nmea_rmc(lat, lon)
        cmd.extend(["emu", "geo", "nmea", sentence])
    else:
        cmd.extend(["emu", "geo", "fix", f"{lon:.6f}", f"{lat:.6f}", f"{ele:.1f}"])

    res = subprocess.run(cmd, capture_output=True, text=True, timeout=5)
    return res.returncode == 0


def main():
    parser = argparse.ArgumentParser(description="Replay GPX route into Android Emulator")
    parser.add_argument("gpx_file", help="Path to GPX file")
    parser.add_argument("-s", "--serial", default="", help="Device serial (e.g. emulator-5554)")
    parser.add_argument(
        "--mode",
        choices=["nmea", "fix"],
        default="nmea",
        help="Location injection mode: nmea (default) or fix",
    )
    parser.add_argument(
        "--step-delay",
        type=float,
        default=0.8,
        help="Delay in seconds between GPX trackpoints (default: 0.8)",
    )
    args = parser.parse_args()

    points = parse_gpx(args.gpx_file)
    print(f"Loaded {len(points)} track points from {args.gpx_file}")
    print(f"Streaming points to emulator {args.serial or '(default)'} via mode='{args.mode}' with {args.step_delay}s step...")

    for i, pt in enumerate(points):
        ok = send_location(args.serial, pt["lon"], pt["lat"], pt["ele"], mode=args.mode)
        if not ok:
            print(f"[{i+1}/{len(points)}] Failed to send geo fix: {pt}")
        if (i + 1) % 15 == 0 or i == 0 or i == len(points) - 1 or "dwell" in pt["desc"]:
            print(f"[{i+1}/{len(points)}] lat={pt['lat']:.6f}, lon={pt['lon']:.6f} ({pt['desc']})")
        time.sleep(args.step_delay)

    print("Route playback completed successfully!")


if __name__ == "__main__":
    main()
