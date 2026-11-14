;;; gen.el --- Write NAME.forms.json for each fixture NAME.el  -*- lexical-binding: t; -*-

;; Run once (see the test): emacs --batch -Q -l runtime/crates/hrafn/tests/fixtures/elisp/gen.el
;; The Emacs reader's form spans are the oracle for the chunker's top-level forms: each pair is [START, END) in bytes.
;; The reader only reads; no fixture is evaluated.

(let ((dir (file-name-directory (or load-file-name buffer-file-name))))
  (dolist (file (directory-files dir t "\\.el\\'"))
    (unless (string= (file-name-nondirectory file) "gen.el")
      (with-temp-buffer
        (let ((coding-system-for-read 'utf-8-unix))
          (insert-file-contents file))
        (set-syntax-table emacs-lisp-mode-syntax-table)
        (goto-char (point-min))
        (let (spans)
          (while (progn (forward-comment (buffer-size)) (not (eobp)))
            (let ((start (position-bytes (point))))
              (read (current-buffer))
              (push (format "[%d,%d]" (1- start) (1- (position-bytes (point)))) spans)))
          (let ((coding-system-for-write 'utf-8-unix))
            (write-region (format "[%s]\n" (string-join (nreverse spans) ","))
                          nil (concat (file-name-sans-extension file) ".forms.json") nil 'silent)))))))
