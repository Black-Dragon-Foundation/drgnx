import os, stat, sys, tempfile, unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "harness"))
import drgnx_ui as ui


class PrepareTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name) / "state"

    def tearDown(self):
        self.tmp.cleanup()

    def test_minimal_layout(self):
        s = ui.prepare_run("drgnx-ui-1", None, "1600x900", self.root)
        run = Path(s["run"])
        self.assertEqual(s["socket"], str(run / "sock" / "drgnx-ui-1"))
        self.assertEqual(stat.S_IMODE(os.stat(run / "sock").st_mode), 0o700)
        self.assertIn("prelude.el", (run / "init/early-init.el").read_text())
        self.assertIn("drgnx-ui-load-config", (run / "init/init.el").read_text())
        self.assertEqual(s["config"], "minimal")
        self.assertEqual(s["config_dir"], "")

    def test_external_config_links_code_copies_custom_skips_state(self):
        cfg = Path(self.tmp.name) / "cfg"
        for d in ("lisp", "extras", "elpa"):
            (cfg / d).mkdir(parents=True)
        (cfg / "init.el").write_text(";; init\n")
        (cfg / "custom.el").write_text(";; custom\n")
        (cfg / "history").write_text("secret history\n")
        s = ui.prepare_run("drgnx-ui-2", str(cfg), "800x600", self.root)
        init = Path(s["run"]) / "init"
        self.assertTrue((init / "lisp").is_symlink())
        self.assertTrue((init / "extras").is_symlink())
        self.assertFalse((init / "custom.el").is_symlink())
        self.assertTrue((init / "custom.el").is_file())
        self.assertFalse((init / "history").exists())
        self.assertFalse((init / "elpa").exists())   # package-user-dir points at it instead
        self.assertEqual(s["config_dir"], str(cfg.resolve()))

    def test_existing_run_dir_is_not_reused(self):
        ui.prepare_run("drgnx-ui-1", None, "1600x900", self.root)
        with self.assertRaises(FileExistsError):
            ui.prepare_run("drgnx-ui-1", None, "1600x900", self.root)

    def test_bad_size_and_config_rejected(self):
        with self.assertRaises(ui.HarnessError):
            ui.prepare_run("drgnx-ui-3", None, "big", self.root)
        with self.assertRaises(ui.HarnessError):
            ui.prepare_run("drgnx-ui-4", str(self.root / "nope"), "1600x900", self.root)

    def test_env_is_allowlisted(self):
        os.environ["DRGNX_FAKE_API_KEY"] = "x"
        try:
            s = ui.prepare_run("drgnx-ui-5", None, "1600x900", self.root)
            env = ui.session_env(s)
        finally:
            del os.environ["DRGNX_FAKE_API_KEY"]
        self.assertNotIn("DRGNX_FAKE_API_KEY", env)
        self.assertEqual(env["DRGNX_UI_NAME"], "drgnx-ui-5")
        self.assertEqual(env["EMACS_SOCKET_NAME"], s["socket"])
        self.assertEqual(ui.env_argv({"A": "1"}), ["env", "-i", "A=1"])

    def test_compositor_argv(self):
        s = ui.prepare_run("drgnx-ui-6", None, "1024x768", self.root)
        argv = ui.compositor_argv(s)
        self.assertEqual(argv[:3], ["dbus-run-session", "--", "mutter"])
        for flag in ("--headless", "--wayland", "--no-x11"):
            self.assertIn(flag, argv)
        self.assertEqual(argv[argv.index("--virtual-monitor") + 1], "1024x768")
        self.assertEqual(argv[argv.index("--wayland-display") + 1], "drgnx-ui-6")
        self.assertNotIn("-Q", argv)
        self.assertEqual(argv[argv.index("--init-directory") + 1], str(Path(s["run"]) / "init"))
