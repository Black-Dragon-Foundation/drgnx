import os, shutil, subprocess, sys, tempfile, time, unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "harness"))
import drgnx_ui as ui

HANG = """;;; hang-test.el -*- lexical-binding: t -*-
(require 'ert)
(ert-deftest drgnx-fixture/hangs () (sleep-for 60))
"""


class RunnerTest(unittest.TestCase):
    def test_hanging_suite_times_out_without_leftovers(self):
        with tempfile.TemporaryDirectory() as tmp:
            (Path(tmp) / "hang-test.el").write_text(HANG)
            t0 = time.time()
            rc, results, run = ui.run_ert_session(Path(tmp), timeout=8)
            self.assertNotEqual(rc, 0)
            self.assertIsNone(results)
            self.assertLess(time.time() - t0, 20)
            left = subprocess.run(["pgrep", "-f", run.name], capture_output=True, text=True).stdout
            self.assertEqual(left.strip(), "")
            shutil.rmtree(run)

    def test_relative_suite_path_and_load_error_fail_fast(self):
        with tempfile.TemporaryDirectory(dir=".") as tmp:
            (Path(tmp) / "broken-test.el").write_text('(error "boom")\n')
            t0 = time.time()
            rc, results, run = ui.run_ert_session(Path(os.path.relpath(tmp)), timeout=30)
            self.assertNotEqual(rc, 0)
            self.assertLess(time.time() - t0, 20)
            self.assertEqual(results["failed"], 1)
            shutil.rmtree(run)
