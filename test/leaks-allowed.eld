;; -*- mode: lisp-data -*-
;; What the leak census (bin/drgnx test --leaks, harness/run-ert.el; docs/develop/check.md) does not report: Emacs's
;; own timers and hooks, and deliberate fixtures.  Each entry is (:what REGEXP :source REGEXP :why STRING).  A leak
;; is left out when its line (for example "hook kill-buffer-hook +some-fn") matches :what and the file that defined
;; it matches :source (leave :source out for any).  Sources inside the checkout are relative to it.  Say why: an
;; entry without a reason is a leak somebody hid.
;;
;; Emacs's lisp directory: /usr/share/emacs/31.1/lisp/ (Linux), .../Emacs.app/Contents/Resources/lisp/ (macOS).
(
 (:what "\\`feature \\+"
  :source "/emacs/[0-9.]+/\\(?:lisp\\|etc/themes\\)/\\|/Contents/Resources/\\(?:lisp\\|etc/themes\\)/"
  :why "Emacs's own library or theme, loaded on demand; a feature is never unloaded (no unload-feature), what it installs shows as its own lines")
 (:what "\\`feature \\+"
  :source "\\`\\(?:core\\|wb\\|modules\\|harness\\)/"
  :why "drgnx's own library, loaded by a test that needs it; a feature is never unloaded, what it installs shows as its own lines")
 (:what "\\`feature \\+"
  :source "/drgnx-\\(?:pkg\\|ext\\)[A-Za-z0-9]+/"
  :why "a fixture package the package and extension tests install into their temp directory and load")
 (:what "\\`feature \\+drgnx-keys-test-feature-"
  :why "fake features the keys test provides to exercise after-load key rows")
 (:what "\\`timer "
  :source "/emacs/[0-9.]+/lisp/\\|/Contents/Resources/lisp/"
  :why "a timer Emacs's own library starts (undo boundary, auto-revert, org cache, password cache, url cookies)")
 (:what "\\`advice "
  :source "/emacs/[0-9.]+/lisp/\\|/Contents/Resources/lisp/"
  :why "advice one of Emacs's libraries puts on another of its functions when it loads (org-compat, org-fold, sh-script)")
 (:what "\\`hook \\(?:[^d]\\|d[^r]\\|dr[^g]\\)[^ ]* \\+"
  :source "/emacs/[0-9.]+/lisp/\\|/Contents/Resources/lisp/"
  :why "an Emacs library wiring itself into a hook (its own, or a stock one) when it loads; drgnx's hook variables (drgnx-…) are not covered")
 (:what "\\`hook \\(?:tramp[a-z-]*\\|native-comp-never-optimize-functions\\) \\+"
  :why "lambdas Tramp puts on its own hooks when it loads, and the function native compilation of a trampoline puts on its list")
 (:what "\\`buffer [+-] \\*\\(?:code-conversion-work\\|code-converting-work\\|tab-line-hscroll\\|jka-compr-wr-temp\\|string-pixel-width\\|work\\|Minibuf-[0-9]+\\)\\*\\'"
  :why "hidden work buffers Emacs makes for itself and keeps (` *work*': the pool of `with-work-buffer', which shr's
string-pixel-width uses)")
 (:what "\\`buffer \\+\\*\\(?:Compile-Log\\|Native-compile-Log\\|Warnings\\)\\*\\'"
  :why "the logs byte and native compilation, and warnings, write to")
 ;; The GUI tier's per-file check (DRGNX_TEST_FILE_LEAKS) reads more than the census does; what follows is what loading a
 ;; library or a fixture does, which is no leak: a feature is never unloaded.
 (:what "\\`registry [^ ]+ \\+"
  :why "a library registering its commands, view types, subscribers or fillers when it loads; a feature is never unloaded, so its registry rows stay")
 (:what "\\`feature \\+"
  :source "\\`\\(?:themes\\|test/fixtures\\)/"
  :why "a theme or a test fixture a test loads; a feature is never unloaded")
 (:what "\\`\\(?:feature\\|timer\\|hook\\|advice\\|global-map\\) "
  :source "/\\(?:childframe-elpa\\|pinned-elpa\\)/"
  :why "a pinned child-frame or modal package loaded by the test that needs it: its own hooks, timers and keys come with the load (a function variable it wraps, like the focus function, is not covered: it changes what the next file sees)")
 (:what "\\`\\(?:minor-mode-map\\|minor-mode\\|emulation-map\\|after-load\\) "
  :why "a library defining its minor mode and map, or an after-load form, when it loads")
 (:what "\\`timer idle [+-]#\\[nil ((if (buffer-live-p buffer)"
  :why "the one-shot idle timer that kills a buffer a library displayed: one fired and another is pending, a rolling pair")
 (:what "\\`timer [+-]surfaces-usage "
  :why "the layer's idle flush of the usage counters: re-armed by every use, a rolling pair")
 (:what "\\`global-map [^ ]+ [^ ]* ?\\+nil\\'"
  :why "a key set to nil: no binding, only the entry; a prefix map created on the way stays")
 (:what "\\`buffer "
  :why "buffers are closed by the harness's cleanup between files (ert-kill-all-test-buffers); a hidden work buffer is no state")
 (:what "\\`frame-param drgnx-\\(?:wb-\\|intent-by\\|layouts-\\|look-\\|frame-role\\|monitor\\|platform-wm\\|work-space-shown\\)"
  :why "the workbench's own layout and look bookkeeping in the frame parameters: every file that opens a panel sets it; the look rows' drgnx-look-gui-check-clean reads what moves pixels")
 (:what "\\`frame-param \\(?:glitnir--[a-z-]+\\|session-name\\) "
  :why "the renderer's and the session's own bookkeeping")
 (:what "\\`window-param \\(?:quit-restore\\|quit-restore-prev\\|internal-region-overlay\\|drgnx-uitest-id\\) "
  :why "what Emacs and the harness note on a window that showed a buffer, was cloned or was driven; none of it draws anything")
 (:what "\\`window-param [^ ]+ \\+nil\\'"
  :why "a parameter set to nil: absent, as Emacs cannot remove one")
 (:what "\\`hook mini-frame-advice-functions \\+"
  :why "mini-frame's defcustom list of functions it advises, filled when the library loads")
 (:what "\\`timer [+-]x-hide-tip "
  :why "Emacs's tooltip timer: one is pending after a tip was shown, gone after it fired")
 (:what "\\`frame-param \\(?:font-parameter\\|nidhogg--font-height\\|nidhogg-text-zoom\\|line-spacing\\|toplevel-chrome\\|tab-bar-lines-keep-state\\|drgnx-topline-lines\\) "
  :why "parameters the renderer and the font code derive from `font' and the bars: the look rows' clean check reads the parameters themselves (font, line-spacing, bars)")
 (:what "\\`face [^ ]+ [+-]\\\\(unspecified\\\\ \\.\\\\ \\(?:unspecified\\|reset\\)\\\\)\\'"
  :why "a face with no colour of its own on the frame: defined (or first realised) by a library that loaded, or gone back to that; a colour a test sets and leaves is still named")
 (:what "\\`global-map "
  :source "/emacs/[0-9.]+/lisp/\\|/Contents/Resources/lisp/"
  :why "keys an Emacs library (tab-line, help, kmacro) binds in the global map when it loads")
 (:what "\\`\\(?:hook \\(?:hack-dir-local-get-variables-functions\\|drgnx-settings-[a-z-]+\\|drgnx-keys-after-apply-functions\\)\\|advice \\(?:hack-local-variables-filter\\|hack-dir-local--get-variables\\)\\) \\+"
  :source "\\`\\(?:core\\|wb\\|modules\\)/"
  :why "drgnx's settings and keys libraries wiring themselves into Emacs's file-local variable machinery and their own hooks when they load; a library is never unloaded")
 (:what "\\`advice drgnx-hub--connect-socket \\+"
  :source "\\`harness/"
  :why "the harness's own hub-caller bookkeeping, installed when drgnx-uitest loads")
 (:what "\\`hook \\(?:drgnx-guard-prompt-functions\\|describe-widget-functions\\) \\+"
  :why "the prompt guard's list of prompt functions and the widget describer, filled when their libraries load")
 (:what "\\`\\(?:hook\\|function-variable\\) "
  :source "\\`\\(?:core/drgnx-surfaces\\|wb/drgnx-\\(?:wb\\|explorer\\|popup\\)\\|modules/tools/drgnx-replace\\)\\.el\\'"
  :why "the workbench, surfaces and replace libraries wiring their hooks when first used in a session; each GUI test file has a session of its own, so it reaches no other file")
)
