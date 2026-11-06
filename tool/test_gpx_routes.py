import tempfile
import unittest
import math
import subprocess
import datetime
from contextlib import redirect_stdout, redirect_stderr
from io import StringIO
from pathlib import Path
from unittest import mock

import play_gpx_route as player
import generate_gpx_test_route as generator

FIXTURES = Path(__file__).resolve().parent.parent / 'test/fixtures/gpx'
CENTRE = (39.237148, -123.176090)


def distance(a, b):
    lat1, lat2 = map(math.radians, (a[0], b[0]))
    dlat = lat2 - lat1
    dlon = math.radians(b[1] - a[1])
    h = math.sin(dlat / 2) ** 2 + math.cos(lat1) * math.cos(lat2) * math.sin(dlon / 2) ** 2
    return 12742000 * math.asin(math.sqrt(h))


class ParserRegressionTests(unittest.TestCase):
    def parse(self, body):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'route.gpx'
            path.write_text(f'<gpx><trk><trkseg>{body}</trkseg></trk></gpx>')
            return player.parse_gpx(str(path))

    def test_relative_time_and_stationary_speed(self):
        points = self.parse('<trkpt lat="0" lon="0"><time>2020-01-01T00:00:00Z</time></trkpt>'
                            '<trkpt lat="0" lon="0"><time>2020-01-01T00:00:02Z</time></trkpt>')
        self.assertEqual([p['time_offset_s'] for p in points], [0, 2])
        self.assertEqual(points[1]['speed_mps'], 0)

    def test_missing_timestamp_fails(self):
        with self.assertRaises(ValueError):
            self.parse('<trkpt lat="0" lon="0"/>')

    def test_namespaced_and_optional_fields(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'ns.gpx'
            path.write_text('<gpx xmlns="http://www.topografix.com/GPX/1/1"><trk><trkseg>'
                            '<trkpt lat="1" lon="2"><ele>5</ele><desc>test</desc>'
                            '<time>2020-01-01T01:00:00+01:00</time></trkpt>'
                            '</trkseg></trk></gpx>')
            p = player.parse_gpx(path)[0]
            self.assertEqual((p['ele'], p['desc'], p['time_offset_s'], p['speed_mps']), (5, 'test', 0, None))

    def test_invalid_points(self):
        good = '<trkpt lat="0" lon="0"><time>2020-01-01T00:00:00Z</time></trkpt>'
        for body in ('', '<trkpt lat="91" lon="0"><time>2020-01-01T00:00:00Z</time></trkpt>',
                     '<trkpt lat="0" lon="181"><time>2020-01-01T00:00:00Z</time></trkpt>',
                     '<trkpt lat="nan" lon="0"><time>2020-01-01T00:00:00Z</time></trkpt>',
                     '<trkpt lat="0" lon="0"><time>bad</time></trkpt>',
                     '<trkpt lat="0" lon="0"><time>2020-01-01T00:00:00</time></trkpt>',
                     good + good,
                     good + '<trkpt lat="0" lon="0"><time>2019-01-01T00:00:00Z</time></trkpt>'):
            with self.subTest(body=body), self.assertRaises(ValueError):
                self.parse(body)


class ReplayTests(unittest.TestCase):
    def setUp(self):
        self.points = player.parse_gpx(FIXTURES / 'driveby_passthrough.gpx')[:4]

    def test_schedule_accounts_for_modest_overhead(self):
        now = [100.0]
        calls = []
        def send(serial, point, mode):
            calls.append(now[0])
            now[0] += 0.3
        def sleep(seconds):
            now[0] += seconds
        with mock.patch.object(player.time, 'monotonic', side_effect=lambda: now[0]), \
             mock.patch.object(player.time, 'sleep', side_effect=sleep), \
             mock.patch.object(player, 'send_location', side_effect=send):
            player.replay_route(self.points)
        self.assertEqual(calls, [100, 101, 102, 103])

    def test_whole_interval_overrun_stops_without_burst(self):
        now = [100.0]
        calls = []
        def send(serial, point, mode):
            calls.append(now[0])
            now[0] += 2 if len(calls) == 2 else 0.3
        with mock.patch.object(player.time, 'monotonic', side_effect=lambda: now[0]), \
             mock.patch.object(player.time, 'sleep', side_effect=lambda s: now.__setitem__(0, now[0] + s)), \
             mock.patch.object(player, 'send_location', side_effect=send):
            with self.assertRaisesRegex(RuntimeError, 'overrun'):
                player.replay_route(self.points)
        self.assertEqual(calls, [100, 101])

    def test_cli_overrun_fails_without_success(self):
        now = [100.0]
        def run(*args, **kwargs):
            now[0] += 2
            return subprocess.CompletedProcess([], 0, 'OK', '')
        with mock.patch.object(player.time, 'monotonic', side_effect=lambda: now[0]), \
             mock.patch.object(player.time, 'sleep', side_effect=lambda s: now.__setitem__(0, now[0] + s)), \
             mock.patch.object(player.subprocess, 'run', side_effect=run) as command, \
             redirect_stdout(StringIO()) as out, redirect_stderr(StringIO()) as err:
            self.assertEqual(player.main([str(FIXTURES / 'driveby_passthrough.gpx')]), 1)
        self.assertEqual(command.call_count, 1)
        self.assertNotIn('successfully', out.getvalue())
        self.assertIn('overrun', err.getvalue())

    def test_final_sample_overrun_and_sleep_overshoot(self):
        now = [100.0]
        calls = []
        def sleep(seconds):
            now[0] += seconds + (1 if calls else 0)
        with mock.patch.object(player.time, 'monotonic', side_effect=lambda: now[0]), \
             mock.patch.object(player.time, 'sleep', side_effect=sleep), \
             mock.patch.object(player, 'send_location', side_effect=lambda s, p, m: calls.append(now[0])):
            with self.assertRaisesRegex(RuntimeError, 'overrun'):
                player.replay_route(self.points[:2])
        self.assertEqual(calls, [100])

    def test_hold_is_scheduled_and_stationary(self):
        points = player.parse_gpx(FIXTURES / 'premature_exit.gpx')
        hold = next(i for i in range(1, len(points)) if points[i]['speed_mps'] == 0)
        subset = points[hold-1:hold+2]
        offset = subset[0]['time_offset_s']
        subset = [dict(p, time_offset_s=p['time_offset_s'] - offset) for p in subset]
        now = [0.0]
        calls = []
        with mock.patch.object(player.time, 'monotonic', side_effect=lambda: now[0]), \
             mock.patch.object(player.time, 'sleep', side_effect=lambda s: now.__setitem__(0, now[0] + s)), \
             mock.patch.object(player, 'send_location', side_effect=lambda s, p, m: calls.append((now[0], p['speed_mps']))):
            player.replay_route(subset)
        self.assertEqual([x[0] for x in calls], [0, 2, 4])
        self.assertEqual(calls[1][1], 0)

    def test_nmea_checksum_speed_and_bearing(self):
        sentence = player.format_nmea_rmc(-12.5, -45.25, 12 * 3600 / 1852, 270)
        raw, checksum = sentence[1:].split('*')
        check = 0
        for char in raw:
            check ^= ord(char)
        self.assertEqual(checksum, f'{check:02X}')
        fields = raw.split(',')
        self.assertEqual(fields[3:7], ['1230.0000', 'S', '04515.0000', 'W'])
        self.assertAlmostEqual(float(fields[7]), 23.326, places=3)
        self.assertEqual(fields[8], '270.0')

    def test_geo_fix_argument_order_and_speed(self):
        with mock.patch.object(player.subprocess, 'run', return_value=subprocess.CompletedProcess([], 0, 'OK', '')) as run:
            player.send_location('emulator-test', self.points[1], 'fix')
        cmd = run.call_args.args[0]
        self.assertEqual(cmd[:6], ['adb', '-s', 'emulator-test', 'emu', 'geo', 'fix'])
        self.assertEqual(cmd[6:9], [f"{self.points[1]['lon']:.6f}", f"{self.points[1]['lat']:.6f}", '35.0'])
        self.assertEqual(cmd[9], '4')
        self.assertAlmostEqual(float(cmd[10]), self.points[1]['speed_mps'] * 3600 / 1852, places=3)
        self.assertTrue(run.call_args.kwargs['check'])

    def test_nmea_injection_uses_derived_speed(self):
        with mock.patch.object(player.subprocess, 'run', return_value=subprocess.CompletedProcess([], 0, 'OK', '')) as run:
            player.send_location('', self.points[1])
        cmd = run.call_args.args[0]
        self.assertEqual(cmd[:4], ['adb', 'emu', 'geo', 'nmea'])
        fields = cmd[4].split(',')
        self.assertAlmostEqual(float(fields[7]), self.points[1]['speed_mps'] * 3600 / 1852, places=3)
        self.assertAlmostEqual(float(fields[8]), self.points[1]['bearing_deg'], places=1)

    def test_failures_stop_and_cli_nonzero(self):
        failures = [subprocess.CalledProcessError(1, 'adb'), subprocess.TimeoutExpired('adb', 5),
                    OSError('missing adb')]
        for failure in failures:
            with self.subTest(failure=failure), mock.patch.object(player.subprocess, 'run', side_effect=failure) as run, \
                 redirect_stdout(StringIO()) as out, redirect_stderr(StringIO()):
                self.assertEqual(player.main([str(FIXTURES / 'driveby_passthrough.gpx')]), 1)
                self.assertEqual(run.call_count, 1)
                self.assertNotIn('successfully', out.getvalue())
        with mock.patch.object(player.subprocess, 'run', return_value=subprocess.CompletedProcess([], 0, 'KO: bad command', '')):
            with self.assertRaises(RuntimeError):
                player.send_location('', self.points[0])
        for stdout, stderr in [('  KO: bad command\n', ''), ('OK\n', '\tKO: rejected\n')]:
            with self.subTest(stdout=stdout, stderr=stderr), \
                 mock.patch.object(player.subprocess, 'run', return_value=subprocess.CompletedProcess([], 0, stdout, stderr)):
                with self.assertRaises(RuntimeError):
                    player.send_location('', self.points[0])
        with mock.patch.object(player.subprocess, 'run', return_value=subprocess.CompletedProcess([], 0, 'OK', ' KO: rejected')) as run, \
             redirect_stdout(StringIO()) as out, redirect_stderr(StringIO()):
            self.assertEqual(player.main([str(FIXTURES / 'driveby_passthrough.gpx')]), 1)
            self.assertEqual(run.call_count, 1)
            self.assertNotIn('successfully', out.getvalue())
        with mock.patch.object(player.subprocess, 'run') as run, redirect_stderr(StringIO()):
            self.assertEqual(player.main(['/missing/route.gpx']), 1)
            run.assert_not_called()
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'broken.gpx'
            path.write_text('<gpx>')
            with mock.patch.object(player.subprocess, 'run') as run, redirect_stderr(StringIO()):
                self.assertEqual(player.main([str(path)]), 1)
                run.assert_not_called()


class FixtureTests(unittest.TestCase):
    def generated(self, function):
        origin = datetime.datetime(2020, 1, 1, tzinfo=datetime.timezone.utc)
        xml = function(*CENTRE, start_time=origin)
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'generated.gpx'
            path.write_text(xml)
            return player.parse_gpx(path)

    def assert_bounce(self, points):
        distances = [distance(CENTRE, (p['lat'], p['lon'])) for p in points]
        crossings = []
        for i in range(1, len(points)):
            a, b = distances[i-1:i+1]
            if (a < 100) != (b < 100):
                fraction = (100 - a) / (b - a)
                crossings.append(points[i-1]['time_offset_s'] + fraction * (points[i]['time_offset_s'] - points[i-1]['time_offset_s']))
        self.assertEqual(len(crossings), 2)
        self.assertLess(crossings[1] - crossings[0], 25)
        self.assertGreater(crossings[1] - crossings[0], 12)
        speeds = [distance((a['lat'], a['lon']), (b['lat'], b['lon'])) / (b['time_offset_s'] - a['time_offset_s']) for a, b in zip(points, points[1:])]
        self.assertTrue(all(1.2 < speed < 1.6 for speed in speeds if speed > 0))
        self.assertGreaterEqual(sum(1 for speed in speeds if speed == 0), 5)

    def assert_adjacent(self, points):
        a = CENTRE
        b = (CENTRE[0], CENTRE[1] + 70 / (111139 * math.cos(math.radians(CENTRE[0]))))
        self.assertAlmostEqual(distance(a, b), 70, delta=0.2)
        coords = [(p['lat'], p['lon']) for p in points]
        self.assertLess(distance(a, coords[-1]), 100)
        self.assertLess(distance(b, coords[-1]), 0.2)
        for centre, minimum in [(a, 38), (b, 28)]:
            held = [p['time_offset_s'] for p in points if distance(centre, (p['lat'], p['lon'])) < 0.2]
            self.assertGreaterEqual(max(held) - min(held), minimum)
        self.assertTrue(all(distance(a, c) < 100 and distance(b, c) < 100
                            for c in coords if distance(a, c) < 0.2 or distance(b, c) < 0.2))

    def test_bounce_crossing_time_and_speed(self):
        self.assert_bounce(player.parse_gpx(FIXTURES / 'premature_exit.gpx'))

    def test_generated_bounce_crossing_time_and_speed(self):
        self.assert_bounce(self.generated(generator.generate_premature_exit))

    def test_adjacent_independent_centres_and_holds(self):
        self.assert_adjacent(player.parse_gpx(FIXTURES / 'adjacent_nextdoor.gpx'))

    def test_generated_adjacent_independent_centres_and_holds(self):
        self.assert_adjacent(self.generated(generator.generate_adjacent_nextdoor))

    def test_all_fixture_spans_and_nominal_speeds(self):
        for name, span, low, high in [('walkin_dwell.gpx', 208, 1.2, 1.6),
                                      ('driveby_passthrough.gpx', 25, 11, 13)]:
            points = player.parse_gpx(FIXTURES / name)
            self.assertEqual(points[-1]['time_offset_s'], span)
            speed = distance((points[0]['lat'], points[0]['lon']), (points[1]['lat'], points[1]['lon'])) / (points[1]['time_offset_s'] - points[0]['time_offset_s'])
            self.assertTrue(low < speed < high)
