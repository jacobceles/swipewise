#!/usr/bin/env python3
"""Replay GPX route offsets at 1x; GPX dates are not live fix timestamps."""

import argparse
import datetime
import math
import subprocess
import sys
import time
import xml.etree.ElementTree as ET


def parse_gpx(gpx_path: str):
    """Return points with lat/lon/ele/desc, time_offset_s, speed_mps and bearing_deg.

    Speed and bearing describe the preceding serialized-coordinate segment. The
    first point uses the following segment; a single point has neither (None).
    Stationary segments have zero speed and no bearing. Elevation defaults to 0.
    """
    root = ET.parse(gpx_path).getroot()
    namespace = root.tag.partition('}')[0] + '}' if root.tag.startswith('{') else ''
    if root.tag != namespace + 'gpx':
        raise ValueError('Expected GPX root')
    trackpoints = root.findall(f'.//{namespace}trkpt')
    if not trackpoints:
        raise ValueError('GPX has no track points')
    points = []
    times = []
    for pt in trackpoints:
        try:
            lat, lon = float(pt.attrib['lat']), float(pt.attrib['lon'])
            ele_text = pt.findtext(namespace + 'ele')
            ele = float(ele_text) if ele_text is not None else 0.0
            stamp = datetime.datetime.fromisoformat(pt.findtext(namespace + 'time').replace('Z', '+00:00'))
            if stamp.tzinfo is None or stamp.utcoffset() is None:
                raise ValueError('timestamp needs timezone')
        except (KeyError, TypeError, AttributeError, ValueError) as exc:
            raise ValueError('Invalid GPX point or timestamp') from exc
        if not (math.isfinite(lat) and -90 <= lat <= 90 and math.isfinite(lon)
                and -180 <= lon <= 180 and math.isfinite(ele)):
            raise ValueError('Invalid coordinate or elevation')
        if times and stamp <= times[-1]:
            raise ValueError('GPX timestamps must strictly increase')
        times.append(stamp)
        points.append({'lat': lat, 'lon': lon, 'ele': ele,
                       'desc': pt.findtext(namespace + 'desc') or '',
                       'time_offset_s': (stamp - times[0]).total_seconds(),
                       'speed_mps': None, 'bearing_deg': None})
    for i in range(1, len(points)):
        a, b = points[i - 1], points[i]
        lat1, lat2 = math.radians(a['lat']), math.radians(b['lat'])
        dlat = lat2 - lat1
        dlon = math.radians(b['lon'] - a['lon'])
        h = math.sin(dlat / 2) ** 2 + math.cos(lat1) * math.cos(lat2) * math.sin(dlon / 2) ** 2
        distance = 2 * 6371000 * math.asin(math.sqrt(min(1.0, h)))
        b['speed_mps'] = distance / (b['time_offset_s'] - a['time_offset_s'])
        if distance:
            y = math.sin(dlon) * math.cos(lat2)
            x = math.cos(lat1) * math.sin(lat2) - math.sin(lat1) * math.cos(lat2) * math.cos(dlon)
            b['bearing_deg'] = math.degrees(math.atan2(y, x)) % 360
    if len(points) > 1:
        points[0]['speed_mps'] = points[1]['speed_mps']
        points[0]['bearing_deg'] = points[1]['bearing_deg']
    return points


def nmea_checksum(sentence: str) -> str:
    checksum = 0
    for char in sentence:
        checksum ^= ord(char)
    return f'{checksum:02X}'


def format_nmea_rmc(lat: float, lon: float, speed_knots: float, bearing_deg=None) -> str:
    lat_deg, lon_deg = int(abs(lat)), int(abs(lon))
    lat_str = f'{lat_deg:02d}{(abs(lat) - lat_deg) * 60:07.4f}'
    lon_str = f'{lon_deg:03d}{(abs(lon) - lon_deg) * 60:07.4f}'
    now = datetime.datetime.now(datetime.timezone.utc)
    bearing = '' if bearing_deg is None else f'{bearing_deg:.1f}'
    raw = (f"GPRMC,{now:%H%M%S}.00,A,{lat_str},{'N' if lat >= 0 else 'S'},"
           f"{lon_str},{'E' if lon >= 0 else 'W'},{speed_knots:.3f},{bearing},{now:%d%m%y},,,A")
    return f'${raw}*{nmea_checksum(raw)}'


def send_location(serial: str, point: dict, mode: str = 'nmea'):
    # Emulator console geo fix syntax: longitude latitude altitude satellites velocity (knots).
    speed = point['speed_mps']
    if speed is None:
        raise ValueError('Cannot inject speed from a single-point route')
    knots = speed * 3600 / 1852
    cmd = ['adb']
    if serial:
        cmd.extend(['-s', serial])
    if mode == 'nmea':
        cmd.extend(['emu', 'geo', 'nmea', format_nmea_rmc(
            point['lat'], point['lon'], knots, point['bearing_deg'])])
    elif mode == 'fix':
        cmd.extend(['emu', 'geo', 'fix', f"{point['lon']:.6f}", f"{point['lat']:.6f}",
                    f"{point['ele']:.1f}", '4', f'{knots:.3f}'])
    else:
        raise ValueError('Unknown injection mode')
    result = subprocess.run(cmd, capture_output=True, text=True, timeout=5, check=True)
    for output in (result.stdout, result.stderr):
        for line in output.splitlines():
            if line.lstrip().startswith('KO'):
                raise RuntimeError(f'Emulator rejected location: {line.strip()}')


def replay_route(points, serial='', mode='nmea'):
    """Replay at 1x, aborting if a sample is a whole following interval late.

    For the final sample, use its preceding interval. Smaller jitter may still
    compress intervals; device-observed timing must be checked separately.
    """
    if not points or points[0]['speed_mps'] is None:
        raise ValueError('Route needs at least two timed points')
    start = time.monotonic()
    for i, point in enumerate(points):
        delay = start + point['time_offset_s'] - time.monotonic()
        if delay > 0:
            time.sleep(delay)
        if i + 1 < len(points):
            interval = points[i + 1]['time_offset_s'] - point['time_offset_s']
        else:
            interval = point['time_offset_s'] - points[i - 1]['time_offset_s']
        if time.monotonic() - (start + point['time_offset_s']) >= interval:
            raise RuntimeError(f'Replay schedule overrun at point {i + 1}')
        send_location(serial, point, mode)


def main(argv=None):
    parser = argparse.ArgumentParser(description='Replay GPX route at 1x into Android Emulator')
    parser.add_argument('gpx_file')
    parser.add_argument('-s', '--serial', default='')
    parser.add_argument('--mode', choices=['nmea', 'fix'], default='nmea')
    args = parser.parse_args(argv)
    try:
        points = parse_gpx(args.gpx_file)
        replay_route(points, args.serial, args.mode)
    except (OSError, ET.ParseError, ValueError, subprocess.SubprocessError, RuntimeError) as exc:
        print(f'Route playback failed: {exc}', file=sys.stderr)
        return 1
    print(f'Route playback completed successfully ({len(points)} points).')
    return 0


if __name__ == '__main__':
    sys.exit(main())
