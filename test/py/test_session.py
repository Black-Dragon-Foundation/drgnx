import json, os, socket, subprocess, sys, tempfile, unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "harness"))
import drgnx_ui as ui

EMACS = ["emacs", "--batch", "-Q", "-L", str(ui.HARNESS), "-l", "drgnx-uitest", "--eval"]


class SessionUnitTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        os.environ["DRGNX_UI_STATE"] = self.tmp.name

    def tearDown(self):
        del os.environ["DRGNX_UI_STATE"]
        self.tmp.cleanup()

    def test_el_quoting_roundtrip(self):
        s = 'he said "hi"\\ \n✓ \t'
        p = subprocess.run([*EMACS, f"(princ (drgnx-uitest--json (list :s {ui.el(s)})))"],
                           capture_output=True, text=True)
        self.assertEqual(json.loads(p.stdout)["s"], s)
        self.assertEqual((ui.el(None), ui.el(True), ui.el(3)), ("nil", "t", "3"))

    def test_parse_reply_handles_elisp_string_printing(self):
        printed = subprocess.run([*EMACS, '(prin1 (drgnx-uitest--json (list :t "a\\"b\\nc ✓")))'],
                                 capture_output=True, text=True).stdout
        self.assertEqual(ui.parse_reply(printed), {"t": 'a"b\nc ✓'})

    def test_launch_argv(self):
        s = ui.prepare_run("drgnx-ui-1", None, "1600x900")
        argv = ui.launch_argv(s)
        self.assertEqual(argv[:6], ["systemd-run", "--user", "--quiet", "--collect", "--unit", "drgnx-ui-1"])
        for prop in ("RuntimeMaxSec=1800", "MemoryMax=3G"):
            self.assertIn(prop, argv)
        self.assertEqual(argv[argv.index("--") + 1: argv.index("--") + 3], ["env", "-i"])

    def test_next_name_skips_stale_dirs(self):
        (Path(self.tmp.name) / "drgnx-ui-1").mkdir()
        self.assertEqual(ui.next_name(Path(self.tmp.name)), "drgnx-ui-2")

    def test_reap_removes_stale_dirs(self):
        ui.prepare_run("drgnx-ui-7", None, "1600x900")
        self.assertIn("drgnx-ui-7", ui.reap())
        self.assertFalse((Path(self.tmp.name) / "drgnx-ui-7").exists())

    def test_reap_leaves_other_state_roots_alone(self):
        units = "drgnx-ui-41.service loaded active running x\ndrgnx-ui-42.service loaded active running y\n"
        shows = {"drgnx-ui-41": f"argv[]=env DRGNX_UI_RUN={self.tmp.name}/drgnx-ui-41 ...",
                 "drgnx-ui-42": "argv[]=env DRGNX_UI_RUN=/elsewhere/drgnx-ui-42 ..."}
        self.assertEqual(ui.reap_targets(Path(self.tmp.name), units, shows.get), ["drgnx-ui-41"])

    def test_foreign_sessions_refused(self):
        for name in ("server", "../drgnx-ui-1", "/run/user/1000/emacs/server", "drgnx-ui-1x", "drgnx-ui-9", 7):
            with self.assertRaises(ui.Refused):
                ui.own_session(name)

    def test_own_session_needs_its_socket(self):
        s = ui.prepare_run("drgnx-ui-3", None, "1600x900")
        with self.assertRaises(ui.Refused):
            ui.own_session("drgnx-ui-3")              # no socket yet
        sock = socket.socket(socket.AF_UNIX)
        sock.bind(s["socket"])
        try:
            self.assertEqual(ui.own_session("drgnx-ui-3")["name"], "drgnx-ui-3")
        finally:
            sock.close()

    def test_composite_argv(self):
        cap = {"root": "/r.png", "children": [{"path": "/c0.png", "x": 307, "y": 338}]}
        self.assertEqual(ui.composite_argv(cap, "/o.png"),
                         ["magick", "/r.png", "/c0.png", "-geometry", "+307+338", "-composite", "/o.png"])

    def test_act_rejects_unknown_actions(self):
        with self.assertRaises(ui.HarnessError):
            ui.act({"socket": "/nonexistent"}, {"fly": 1})
