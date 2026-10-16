import json, os, subprocess, tempfile, unittest
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]


class RunErtTest(unittest.TestCase):
    def test_mixed_suite_writes_results_and_fails(self):
        with tempfile.TemporaryDirectory() as tmp:
            results = Path(tmp) / "results.json"
            p = subprocess.run(
                ["emacs", "--batch", "-Q", "-l", str(REPO / "harness/run-ert.el"),
                 "-f", "drgnx-run-ert-batch", str(REPO / "test/py/fixtures/ert-mixed")],
                capture_output=True, text=True, env={**os.environ, "DRGNX_TEST_RESULTS": str(results)})
            self.assertEqual(p.returncode, 1, p.stderr)
            r = json.loads(results.read_text())
            self.assertEqual((r["total"], r["passed"], r["failed"]), (2, 1, 1))
            self.assertEqual(r["failures"][0]["name"], "drgnx-fixture/fails")

    def test_suite_that_fails_to_load_is_a_failure(self):
        with tempfile.TemporaryDirectory() as tmp:
            (Path(tmp) / "broken-test.el").write_text('(error "boom")\n')
            results = Path(tmp) / "results.json"
            p = subprocess.run(
                ["emacs", "--batch", "-Q", "-l", str(REPO / "harness/run-ert.el"),
                 "-f", "drgnx-run-ert-batch", tmp],
                capture_output=True, text=True, env={**os.environ, "DRGNX_TEST_RESULTS": str(results)})
            self.assertEqual(p.returncode, 1, p.stderr)
            r = json.loads(results.read_text())
            self.assertEqual(r["failed"], 1)
            self.assertTrue(r["failures"][0]["name"].startswith("load "))


if __name__ == "__main__":
    unittest.main()
