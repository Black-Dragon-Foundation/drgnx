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
 (:what "\\`drgnx-keys--applied length nil -> 0\\'"
  :why "the variable became bound because the library loaded: a load, not a change")
)
