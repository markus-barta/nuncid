#!/usr/bin/env python3
import datetime as dt
import importlib.util
import json
from pathlib import Path
import subprocess
import tempfile
import unittest

spec = importlib.util.spec_from_file_location("release_policy", Path(__file__).with_name("release-policy.py"))
p = importlib.util.module_from_spec(spec)
spec.loader.exec_module(p)


class ReleasePolicyTests(unittest.TestCase):
    def test_dates_and_mapping(self):
        for value in ["00.01.01", "00.01.01.00.00.00", "24.02.29", "26.09.06.17.00.01", "99.12.31.23.59.59"]:
            self.assertEqual(p.canonical_version(p.bundle_version(value)), value)
        self.assertNotEqual(p.bundle_version("26.09.06"), p.bundle_version("26.09.06.00.00.00"))
        for value in ["26.02.29", "26.04.31", "26.09.06.24.00.00", "26.9.06", "26.09.06Z", "26.09.06\n", "v26.09.06", "26.09.06.00.00.60", "2026.09.06"]:
            with self.assertRaises(ValueError):
                p.calendar(value)
        for value in ["2026.229.0", "1999.101.1", "2100.101.1", "2026.906.86401", "2026.0906.1", "2026.906.-1"]:
            with self.assertRaises(ValueError):
                p.canonical_version(value)
        # Every supported date at both precision boundaries, plus every second
        # of one date. Mapping never conflates short form with long midnight.
        date = dt.date(2000, 1, 1)
        seen = set()
        while date.year < 2100:
            for tail in ["", ".00.00.00", ".23.59.59"]:
                value = date.strftime("%y.%m.%d") + tail
                mapped = p.bundle_version(value)
                self.assertNotIn(mapped, seen)
                seen.add(mapped)
                self.assertEqual(p.canonical_version(mapped), value)
            date += dt.timedelta(days=1)
        for second in range(86400):
            value = (dt.datetime(2026, 9, 6) + dt.timedelta(seconds=second)).strftime("%y.%m.%d.%H.%M.%S")
            self.assertEqual(p.canonical_version(p.bundle_version(value)), value)

    def test_reservation_and_fail_closed(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            subprocess.run(["git", "init", "-q", str(root)], check=True)
            (root / p.RECORD).parent.mkdir(parents=True)
            record = dict(version_scheme="legacy", version="1.2.3", release_channel="stable", release_sequence=19, bundle_short_version="1.2.3")
            (root / p.RECORD).write_text(json.dumps(record))
            (root / "VERSION").write_text("1.2.3\n")
            (root / "README.md").write_text("release-1.2.3-blue Latest release 1.2.3 hero-1.2.3.png")
            history = "## [Unreleased]\n\n## [1.2.3] - 2026-09-06\n\n- Immutable.\n"
            (root / "CHANGELOG.md").write_text(history)
            now = dt.datetime(2026, 9, 6, 17, 40, 0, tzinfo=dt.timezone.utc)
            version = p.reserve("Explore on demand.", root, now)
            self.assertEqual(version, "26.09.06.17.40.00")
            self.assertEqual(p.load(root)["release_sequence"], 20)
            self.assertIn(history.split("\n", 2)[2], (root / "CHANGELOG.md").read_text())
            before = {path: path.read_bytes() for path in [root / "VERSION", root / "README.md", root / "CHANGELOG.md", root / p.RECORD]}
            for moment in [now, now - dt.timedelta(seconds=1)]:
                with self.assertRaises(ValueError):
                    p.reserve("Collision", root, moment)
                self.assertEqual(before, {path: path.read_bytes() for path in before})
            p.reserve("Next set.", root, now + dt.timedelta(seconds=1))
            record = p.load(root)
            self.assertEqual(record["release_sequence"], 21)
            self.assertEqual(record["first_calendar_version"], version)
            for bad in [None, "unknown", "legacy"]:
                altered = dict(record, version_scheme=bad)
                (root / p.RECORD).write_text(json.dumps(altered))
                with self.assertRaises(ValueError):
                    p.load(root)
            for field, value in [("version", "26.09.06"), ("release_channel", "preview"), ("release_sequence", 20), ("bundle_short_version", "2026.906.0"), ("first_calendar_version", "26.09.07")]:
                (root / p.RECORD).write_text(json.dumps(dict(record, **{field: value})))
                with self.assertRaises(ValueError):
                    p.load(root)
            (root / p.RECORD).write_text(json.dumps(dict(record, retired_calendar_candidates=[{"version": version}])))
            self.assertEqual(p.load(root)["release_sequence"], 21)
            (root / p.RECORD).write_text(json.dumps(dict(record, retired_calendar_candidates=[{"version": record["version"]}])))
            with self.assertRaises(ValueError):
                p.load(root)


if __name__ == "__main__":
    unittest.main()
