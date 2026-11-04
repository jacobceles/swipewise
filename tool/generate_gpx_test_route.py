#!/usr/bin/env python3
"""
generate_gpx_test_route.py - Generate time-stamped GPX route files for Android Emulator
geofencing and dwell verification.

Generates 4 distinct scenarios:
1. walkin_dwell: Standard walk-in at 1.2 m/s with 35s dwell inside 100m geofence.
2. driveby_passthrough: High-speed traversal at 12 m/s (~43 km/h) through geofence without stopping.
3. premature_exit: Approach, enter geofence for only 12s, then exit before 30s dwell timer.
4. adjacent_nextdoor: Dwell at Store A, then walk 40m across to adjacent Store B.
"""

import argparse
import datetime
import math
import os
import sys

EARTH_RADIUS_M = 6371000.0


def haversine(lat1: float, lon1: float, lat2: float, lon2: float) -> float:
    phi1, phi2 = math.radians(lat1), math.radians(lat2)
    dphi = math.radians(lat2 - lat1)
    dlambda = math.radians(lon2 - lon1)
    a = math.sin(dphi / 2) ** 2 + math.cos(phi1) * math.cos(phi2) * math.sin(dlambda / 2) ** 2
    return 2 * EARTH_RADIUS_M * math.atan2(math.sqrt(a), math.sqrt(1 - a))


def offset_lat(lat: float, meters: float) -> float:
    # 1 degree of latitude is approximately 111,139 meters
    return lat + (meters / 111139.0)


def offset_lon(lat: float, lon: float, meters: float) -> float:
    # 1 degree of longitude at given latitude
    meters_per_deg = 111139.0 * math.cos(math.radians(lat))
    return lon + (meters / meters_per_deg)


def build_gpx_xml(name: str, desc: str, points: list, start_time: datetime.datetime, elevation_m: float = 35.0) -> str:
    lines = [
        '<?xml version="1.0" encoding="UTF-8"?>',
        '<gpx version="1.1" creator="SwipeWise Geofence Test Generator" '
        'xmlns="http://www.topografix.com/GPX/1/1" '
        'xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" '
        'xsi:schemaLocation="http://www.topografix.com/GPX/1/1 '
        'http://www.topografix.com/GPX/1/1/gpx.xsd">',
        '  <metadata>',
        f'    <name>{name}</name>',
        f'    <desc>{desc}</desc>',
        f'    <time>{start_time.strftime("%Y-%m-%dT%H:%M:%SZ")}</time>',
        '  </metadata>',
        '  <trk>',
        f'    <name>{name}</name>',
        '    <trkseg>',
    ]

    for lat, lng, dist, pt_time, phase in points:
        iso_time = pt_time.strftime("%Y-%m-%dT%H:%M:%SZ")
        lines.append(f'      <trkpt lat="{lat:.6f}" lon="{lng:.6f}">')
        lines.append(f"        <ele>{elevation_m:.1f}</ele>")
        lines.append(f"        <time>{iso_time}</time>")
        lines.append(f"        <desc>phase={phase} dist_to_target={dist:.1f}m</desc>")
        lines.append("      </trkpt>")

    lines.append("    </trkseg>")
    lines.append("  </trk>")
    lines.append("</gpx>")
    lines.append("")
    return "\n".join(lines)


def generate_walkin_dwell(
    target_lat: float,
    target_lng: float,
    start_distance_m: float = 120.0,
    store_interior_distance_m: float = 20.0,
    dwell_duration_s: int = 65,
    walking_speed_mps: float = 1.4,
    dt: float = 2.0,
    start_time: datetime.datetime | None = None,
) -> str:
    if start_time is None:
        start_time = datetime.datetime.now(datetime.timezone.utc).replace(microsecond=0)

    current_time = start_time
    points = []

    # Inbound
    inbound_dist = start_distance_m - store_interior_distance_m
    step_m = walking_speed_mps * dt
    inbound_steps = int(round(inbound_dist / step_m))
    step_inbound = inbound_dist / inbound_steps

    for i in range(inbound_steps):
        dist = start_distance_m - (i * step_inbound)
        lat = offset_lat(target_lat, -dist)
        points.append((lat, target_lng, dist, current_time, "inbound"))
        current_time += datetime.timedelta(seconds=dt)

    # Dwell inside store (sub-0.2 m/s micro-movement)
    dwell_steps = int(round(dwell_duration_s / dt))
    for i in range(dwell_steps):
        micro = 0.5 * math.sin(2 * math.pi * i / 10.0)
        dist = store_interior_distance_m + micro
        lat = offset_lat(target_lat, -dist)
        points.append((lat, target_lng, dist, current_time, "dwell"))
        current_time += datetime.timedelta(seconds=dt)

    # Outbound walk back
    outbound_steps = inbound_steps
    step_outbound = inbound_dist / outbound_steps
    for i in range(outbound_steps + 1):
        dist = store_interior_distance_m + (i * step_outbound)
        lat = offset_lat(target_lat, -dist)
        points.append((lat, target_lng, dist, current_time, "outbound"))
        current_time += datetime.timedelta(seconds=dt)

    return build_gpx_xml(
        name="Scenario 1: Walk-in and Dwell",
        desc=f"Walk-in from {start_distance_m:.0f}m at {walking_speed_mps}m/s, dwell {dwell_duration_s}s, exit.",
        points=points,
        start_time=start_time,
    )


def generate_driveby_passthrough(
    target_lat: float,
    target_lng: float,
    start_distance_m: float = 150.0,
    drive_speed_mps: float = 12.0,  # ~43 km/h
    dt: float = 1.0,
    start_time: datetime.datetime | None = None,
) -> str:
    if start_time is None:
        start_time = datetime.datetime.now(datetime.timezone.utc).replace(microsecond=0)

    current_time = start_time
    points = []

    # Drive from 150m south to 150m north through the 100m geofence at 12 m/s
    total_dist = 2 * start_distance_m  # 300m
    total_steps = int(round(total_dist / (drive_speed_mps * dt)))
    step_dist = total_dist / total_steps

    for i in range(total_steps + 1):
        # Starts at -150m (south), reaches 0m (center), exits to +150m (north)
        pos_y = -start_distance_m + (i * step_dist)
        lat = offset_lat(target_lat, pos_y)
        dist_from_target = abs(pos_y)
        points.append((lat, target_lng, dist_from_target, current_time, "driveby"))
        current_time += datetime.timedelta(seconds=dt)

    return build_gpx_xml(
        name="Scenario 2: Drive-by Pass Through",
        desc=f"Drive through {start_distance_m*2:.0f}m path at {drive_speed_mps}m/s without stopping.",
        points=points,
        start_time=start_time,
    )


def generate_premature_exit(
    target_lat: float,
    target_lng: float,
    start_distance_m: float = 120.0,
    dwell_duration_s: int = 12,  # Well under 30s dwell timer
    walking_speed_mps: float = 1.4,
    dt: float = 2.0,
    start_time: datetime.datetime | None = None,
) -> str:
    if start_time is None:
        start_time = datetime.datetime.now(datetime.timezone.utc).replace(microsecond=0)

    current_time = start_time
    points = []

    # Inbound to 50m inside fence
    interior_dist = 50.0
    inbound_dist = start_distance_m - interior_dist
    step_m = walking_speed_mps * dt
    inbound_steps = int(round(inbound_dist / step_m))
    step_inbound = inbound_dist / inbound_steps

    for i in range(inbound_steps):
        dist = start_distance_m - (i * step_inbound)
        lat = offset_lat(target_lat, -dist)
        points.append((lat, target_lng, dist, current_time, "inbound"))
        current_time += datetime.timedelta(seconds=dt)

    # Brief stay inside (12s < 30s dwell alarm)
    dwell_steps = int(round(dwell_duration_s / dt))
    for i in range(dwell_steps):
        lat = offset_lat(target_lat, -interior_dist)
        points.append((lat, target_lng, interior_dist, current_time, "short_stay"))
        current_time += datetime.timedelta(seconds=dt)

    # Outbound exit back
    outbound_steps = inbound_steps
    step_outbound = inbound_dist / outbound_steps
    for i in range(outbound_steps + 1):
        dist = interior_dist + (i * step_outbound)
        lat = offset_lat(target_lat, -dist)
        points.append((lat, target_lng, dist, current_time, "outbound"))
        current_time += datetime.timedelta(seconds=dt)

    return build_gpx_xml(
        name="Scenario 3: Premature Exit / Bounce",
        desc=f"Enter geofence, stay only {dwell_duration_s}s, exit before 30s dwell alarm.",
        points=points,
        start_time=start_time,
    )


def generate_adjacent_nextdoor(
    target_lat: float,
    target_lng: float,
    store_a_dist_m: float = 20.0,
    store_b_dist_m: float = 40.0,  # 40m east of Store A
    dwell_a_s: int = 40,
    dwell_b_s: int = 30,
    walking_speed_mps: float = 1.4,
    dt: float = 2.0,
    start_time: datetime.datetime | None = None,
) -> str:
    if start_time is None:
        start_time = datetime.datetime.now(datetime.timezone.utc).replace(microsecond=0)

    current_time = start_time
    points = []

    # 1. Approach and dwell at Store A
    lat_a = offset_lat(target_lat, -store_a_dist_m)
    lng_a = target_lng

    # Approach from 120m south to Store A
    inbound_dist = 120.0 - store_a_dist_m
    step_m = walking_speed_mps * dt
    inbound_steps = int(round(inbound_dist / step_m))
    step_inbound = inbound_dist / inbound_steps

    for i in range(inbound_steps):
        dist = 120.0 - (i * step_inbound)
        lat = offset_lat(target_lat, -dist)
        points.append((lat, lng_a, dist, current_time, "approach_store_a"))
        current_time += datetime.timedelta(seconds=dt)

    # Dwell at Store A
    dwell_a_steps = int(round(dwell_a_s / dt))
    for i in range(dwell_a_steps):
        points.append((lat_a, lng_a, store_a_dist_m, current_time, "dwell_store_a"))
        current_time += datetime.timedelta(seconds=dt)

    # 2. Walk 40m East from Store A to Store B
    transit_steps = int(round(store_b_dist_m / step_m))
    step_east = store_b_dist_m / transit_steps
    for i in range(1, transit_steps + 1):
        lng_b = offset_lon(lat_a, lng_a, i * step_east)
        dist = haversine(target_lat, target_lng, lat_a, lng_b)
        points.append((lat_a, lng_b, dist, current_time, "walk_to_store_b"))
        current_time += datetime.timedelta(seconds=dt)

    lng_b_final = offset_lon(lat_a, lng_a, store_b_dist_m)

    # 3. Dwell at Store B
    dwell_b_steps = int(round(dwell_b_s / dt))
    for i in range(dwell_b_steps):
        dist = haversine(target_lat, target_lng, lat_a, lng_b_final)
        points.append((lat_a, lng_b_final, dist, current_time, "dwell_store_b"))
        current_time += datetime.timedelta(seconds=dt)

    return build_gpx_xml(
        name="Scenario 4: Adjacent Next-Door Store Walk",
        desc=f"Dwell {dwell_a_s}s at Store A, walk {store_b_dist_m}m to Store B, dwell {dwell_b_s}s.",
        points=points,
        start_time=start_time,
    )


def generate_all_fixtures(output_dir: str, target_lat: float, target_lng: float):
    os.makedirs(output_dir, exist_ok=True)

    scenarios = [
        ("walkin_dwell.gpx", generate_walkin_dwell(target_lat, target_lng)),
        ("driveby_passthrough.gpx", generate_driveby_passthrough(target_lat, target_lng)),
        ("premature_exit.gpx", generate_premature_exit(target_lat, target_lng)),
        ("adjacent_nextdoor.gpx", generate_adjacent_nextdoor(target_lat, target_lng)),
    ]

    for filename, xml in scenarios:
        path = os.path.join(output_dir, filename)
        with open(path, "w", encoding="utf-8") as f:
            f.write(xml)
        print(f"Generated: {path}")


def main():
    parser = argparse.ArgumentParser(description="Generate GPX test routes for Android Emulator")
    parser.add_argument("--lat", type=float, default=39.237148, help="Target merchant latitude")
    parser.add_argument("--lng", type=float, default=-123.176090, help="Target merchant longitude")
    parser.add_argument("--all", action="store_true", help="Generate all 4 standard test fixtures into test/fixtures/gpx")
    parser.add_argument("--out-dir", default="test/fixtures/gpx", help="Output directory for --all")
    parser.add_argument("-o", "--output", default="test/fixtures/gpx/walkin_dwell.gpx", help="Single file output path")
    args = parser.parse_args()

    if args.all:
        generate_all_fixtures(args.out_dir, args.lat, args.lng)
    else:
        xml = generate_walkin_dwell(args.lat, args.lng)
        os.makedirs(os.path.dirname(args.output) or ".", exist_ok=True)
        with open(args.output, "w", encoding="utf-8") as f:
            f.write(xml)
        print(f"Generated GPX route: {args.output}")


if __name__ == "__main__":
    main()
