"""Verify the shell fixture's exit protocol without starting any engine."""
from pathlib import Path
import os
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
PASS = 'GMORN_SCOPE_VERIFY_JSON {"schema":1,"status":"pass","checks":1}'
FAIL = 'GMORN_SCOPE_VERIFY_JSON {"schema":1,"status":"fail","checks":1}'


class FixtureProtocol(unittest.TestCase):
    def run_fake(self, lines, exit_code=0, args=()):
        # All test writes remain in this package's explicitly owned directory.
        with tempfile.TemporaryDirectory(prefix="fixture-test-", dir=ROOT) as tmp:
            tmp_path = Path(tmp)
            fake = tmp_path / "fake-godot"
            # Fixed Python executable stub: no engine, media, or shell evaluation.
            fake.write_text(
                "#!/usr/bin/env python3\nimport sys\n"
                + "print(" + repr("\n".join(lines)) + ")\n"
                + "sys.exit(" + str(exit_code) + ")\n"
            )
            fake.chmod(0o700)
            env = dict(os.environ, GODOT_BIN=str(fake), TMPDIR=str(tmp_path))
            return subprocess.run(
                ["sh", str(ROOT / "verify.sh"), *args], env=env,
                capture_output=True, text=True, timeout=5,
            )

    def test_completed_positive_summary(self):
        self.assertEqual(self.run_fake([PASS]).returncode, 0)

    def test_exit_zero_without_summary_is_failure(self):
        self.assertNotEqual(self.run_fake(["engine started"]).returncode, 0)

    def test_false_summary_is_failure(self):
        self.assertNotEqual(self.run_fake([FAIL]).returncode, 0)

    def test_error_beside_positive_summary_is_failure(self):
        for message in ("SCRIPT ERROR: wrong callable", "ERROR: resource missing", "WARNING: leak"):
            with self.subTest(message=message):
                self.assertNotEqual(self.run_fake([message, PASS]).returncode, 0)

    def test_nonzero_exit_overrides_positive_summary(self):
        self.assertEqual(self.run_fake([PASS], exit_code=7).returncode, 7)

    def test_runtime_suite_does_not_use_assert_as_exit_protocol(self):
        source = (ROOT / "verify.gd").read_text()
        self.assertNotIn("assert(", source)
        self.assertIn("quit(0 if passed else 1)", source)
        self.assertIn('"--force-failure"', source)
        self.assertIn('"--fault-callback-error"', source)
        self.assertIn("AudioServer.set_bus_mute(0, true)", source)

    def test_package_has_no_nested_project_or_assets(self):
        self.assertFalse((ROOT / "project.godot").exists())
        self.assertFalse((ROOT / "plugin.cfg").exists())
        source = (ROOT / "gmorn_scope.gd").read_text()
        self.assertNotIn("preload(", source)
        self.assertNotIn("res://", source)
        self.assertNotIn("user://", source)


if __name__ == "__main__":
    unittest.main()
