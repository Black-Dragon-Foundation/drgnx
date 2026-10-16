import json, os, subprocess, sys, tempfile, unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "harness"))
import drgnx_ui as ui


def nonblank(png):
    out = subprocess.run(["magick", png, "-format", "%[fx:standard_deviation]", "info:"],
                         capture_output=True, text=True).stdout
    return float(out) > 0.01


class LiveSessionTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        os.environ["DRGNX_UI_STATE"] = self.tmp.name

    def tearDown(self):
        for sess in ui.ls():
            ui.stop(sess["name"])
        del os.environ["DRGNX_UI_STATE"]
        self.tmp.cleanup()

    def test_start_drive_capture_stop(self):
        s = ui.start("minimal")
        self.assertFalse(s["ready"]["init_error"])
        sess = ui.own_session(s["name"])
        r = ui.measure(sess, [{"type": "hello drgnx ✓"}])
        self.assertTrue(r["settled"])
        self.assertEqual(r["collateral_moves"], 0)
        text = ui.call(sess, '(with-current-buffer "*scratch*" (drgnx-uitest--json (list :s (buffer-string))))')
        self.assertEqual(text["s"], "hello drgnx ✓")
        r = ui.measure(sess, [{"buffer": "*scratch*", "text": "drgnx"}])
        st = ui.state(sess)
        win = [w for w in st["windows"] if w["selected"]][0]
        self.assertEqual(win["point"], 7)                 # clicked on the "d" of "drgnx"
        shot = ui.screenshot(sess, str(Path(self.tmp.name) / "s.png"))
        self.assertTrue(nonblank(shot["path"]))
        ui.stop(s["name"])
        self.assertFalse(ui.unit_active(s["name"]))
        left = subprocess.run(["pgrep", "-f", f"--wayland-display {s['name']}"], capture_output=True, text=True)
        self.assertEqual(left.stdout.strip(), "")

    def test_init_error_still_ready(self):
        cfg = Path(self.tmp.name) / "broken"
        cfg.mkdir()
        (cfg / "init.el").write_text('(error "broken config")\n')
        s = ui.start(str(cfg))
        self.assertTrue(s["ready"]["init_error"])
        ui.stop(s["name"])
