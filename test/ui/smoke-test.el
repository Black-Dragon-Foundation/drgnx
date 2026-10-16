;;; smoke-test.el --- GUI smoke tests (run by `drgnx test --ui') -*- lexical-binding: t -*-
(require 'ert)
(require 'drgnx-uitest)

(ert-deftest drgnx-ui-smoke/frame-is-visible-and-graphical ()
  (let ((f (drgnx-uitest-root-frame)))
    (should (frame-visible-p f))
    (should (memq (window-system f) '(pgtk x)))
    (should (> (frame-pixel-width f) 640))))

(ert-deftest drgnx-ui-smoke/session-is-isolated ()
  (should (string-prefix-p (getenv "DRGNX_UI_RUN") (expand-file-name user-emacs-directory)))
  (should (null auth-sources))
  (should (equal server-name (getenv "DRGNX_UI_NAME")))
  (should-error (url-retrieve-synchronously "https://example.org")))
