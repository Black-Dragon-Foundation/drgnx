;;; conformance-rows-test.el --- batch tests: what the conformance rows' shell lines may rely on -*- lexical-binding: t -*-
;; test-class: det
(require 'ert)
(require 'cl-lib)
(require 'json)

(defconst drgnx-conformance-rows-test--root
  (expand-file-name "../conformance/" (file-name-directory (or load-file-name buffer-file-name))))

;; A `run' step's shell line that writes a file with `printf '...\"...'' hands printf a backslash and a quote.  bash's
;; printf turns that into a quote and dash's (/bin/sh on Ubuntu runners) keeps the backslash: the file differs by the
;; shell, and a settings.el with `\"host:80\"' reads as a symbol with quotes in it (container-escape rows on PR 4:
;; "the allow-list: BadName").  A row writes the quote itself: in the JSON a single `\"'.
(ert-deftest drgnx-conformance-rows/no-printf-format-holds-a-backslash-quote ()
  (skip-unless (file-directory-p drgnx-conformance-rows-test--root))
  (let (bad (rows 0))
    (dolist (f (directory-files-recursively drgnx-conformance-rows-test--root "\\.jsonl\\'"))
      (with-temp-buffer
        (let ((coding-system-for-read 'utf-8-unix)) (insert-file-contents f))
        (let ((n 0))
          (dolist (line (split-string (buffer-string) "\n" t))
            (setq n (1+ n))
            (let ((step (ignore-errors (json-parse-string line :object-type 'alist :array-type 'list))))
              (when (and step (equal (alist-get 'do step) "run"))
                (setq rows (1+ rows))
                (dolist (a (alist-get 'args step))
                  (when (and (stringp a) (string-search "printf '" a) (string-search "\\\"" a))
                    (push (format "%s:%d" (file-relative-name f drgnx-conformance-rows-test--root) n) bad)))))))))
    (should (> rows 100))
    (should (equal (nreverse bad) nil))))

;;; conformance-rows-test.el ends here
