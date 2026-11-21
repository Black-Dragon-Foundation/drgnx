;;; live-test.el --- the new language packs, built and used for real -*- lexical-binding: t -*-
;; Run by test/packs/live.sh after `drgnx packs sync --add …' in the same environment.  Each sample opens in the mode of
;; its pack, and chosen tokens carry the faces highlighting should give them.
(require 'ert)
(require 'drgnx)
(require 'drgnx-modules)
(load (expand-file-name "modules/lang/drgnx-lang-packs" drgnx-dir) nil t)

(defvar drgnx-packs-live--samples
  '(("kotlin" "Sample.kt" drgnx-pack-ts-mode
     ("class" 0 font-lock-keyword-face) ("fun push" 4 font-lock-function-name-face)
     ("\"hello\"" 0 font-lock-string-face) ("// greeting" 0 font-lock-comment-face))
    ("swift" "Sample.swift" drgnx-pack-ts-mode
     ("struct" 0 font-lock-keyword-face) ("func main" 5 font-lock-function-name-face)
     ("\"hello\"" 0 font-lock-string-face) ("// greeting" 0 font-lock-comment-face))
    ("zig" "sample.zig" drgnx-pack-ts-mode
     ("pub fn" 0 font-lock-keyword-face) ("fn push" 3 font-lock-function-name-face)
     ("\"size" 0 font-lock-string-face) ("// greeting" 0 font-lock-comment-face))
    ("sql" "sample.sql" drgnx-pack-ts-mode
     ("CREATE" 0 font-lock-keyword-face) ("-- a small" 0 font-lock-comment-face) ("'2026" 0 font-lock-string-face))
    ("php" "sample.php" php-ts-mode ("class" 0 font-lock-keyword-face) ("// greeting" 0 font-lock-comment-face))
    ("elixir" "sample.ex" elixir-ts-mode ("defmodule" 0 font-lock-keyword-face) ("# greeting" 0 font-lock-comment-face))))

(defun drgnx-packs-live--face-at (token offset)
  (save-excursion
    (goto-char (point-min))
    (unless (search-forward token nil t) (error "no %S in the sample" token))
    (let ((face (get-text-property (+ (match-beginning 0) offset) 'face)))
      (ensure-list face))))

(drgnx-modules-run 'startup)            ; lang/packs applies active.eld, as at a real startup

(ert-deftest drgnx-packs-live/the-packs-are-applied ()
  (should (drgnx-packs-active))
  (should (> (length (plist-get (drgnx-packs-active) :packs)) 4)))

(dolist (s drgnx-packs-live--samples)
  (let ((pack (nth 0 s)) (file (nth 1 s)) (mode (nth 2 s)) (checks (nthcdr 3 s)))
    (eval
     `(ert-deftest ,(intern (format "drgnx-packs-live/%s-opens-in-its-mode-with-highlighting" pack)) ()
        (let ((buf (find-file-noselect (expand-file-name ,(format "packs/%s/test/samples/%s" pack file) drgnx-dir))))
          (unwind-protect
              (with-current-buffer buf
                (should (eq major-mode ',mode))
                (font-lock-ensure)
                (dolist (c ',checks)
                  (should (memq (nth 2 c) (drgnx-packs-live--face-at (nth 0 c) (nth 1 c))))))
            (with-current-buffer buf (set-buffer-modified-p nil))
            (kill-buffer buf))))
     t)))

(provide 'live-test)
;;; live-test.el ends here
