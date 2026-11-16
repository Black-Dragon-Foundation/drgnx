;;; lint-kit-test.el --- lint: the UI kit's rules (Rust names faces through FaceId) -*- lexical-binding: t -*-
;; test-class: det
;; Pattern [D]: pure.  Rust names a face through drgnx-rows' generated `FaceId' (`FaceId::TextMuted.name()',
;; `FaceId::AGENT[i].name()'), so a renamed or removed face is a compile error.  This lint reads every .rs under
;; runtime/crates/ (but the generated faces.rs and its test) as text, outside comments, and counts per file the string literals
;; equal to a drgnx face of etc/ui/faces.eld, and the `format!' literals "drgnx-FAMILY-{...}" of a numbered face family.
;; The standard faces (`default', `bold', `error'...) are left out: they are Emacs's, never renamed by drgnx, and the
;; same words are JSON keys and messages.  `drgnx-lint-kit--rust-face-literals-not-yet' holds the files that still
;; name faces by string, with their counts, which only fall.
(require 'ert)
(require 'cl-lib)
(require 'subr-x)
(require 'drgnx-paths)

(defconst drgnx-lint-kit--rust-face-literals-not-yet
  '()
  "((FILE COUNT)...): files under runtime/crates/ that still name faces by string literal, and how many (only falls).")

(defconst drgnx-lint-kit--enum-files
  '("runtime/crates/drgnx-rows/src/faces.rs" "runtime/crates/drgnx-rows/tests/faces.rs")
  "The enum and its own test: they spell the names out on purpose.")

(defun drgnx-lint-kit--faces ()
  "The drgnx faces of etc/ui/faces.eld, as a hash table of their names."
  (let ((table (make-hash-table :test #'equal)))
    (dolist (face (with-temp-buffer
                    (insert-file-contents (expand-file-name "etc/ui/faces.eld" drgnx-dir))
                    (read (current-buffer))))
      (when (string-prefix-p "drgnx-" (symbol-name face)) (puthash (symbol-name face) t table)))
    table))

(defun drgnx-lint-kit--families (faces)
  "The prefixes \"drgnx-NAME-\" of the numbered families among FACES (a table of names): NAME-1 or NAME-0 and NAME-2."
  (let (out)
    (maphash (lambda (name _)
               (when (string-match "\\`\\(.*-\\)[01]\\'" name)
                 (let ((prefix (match-string 1 name)))
                   (when (gethash (concat prefix "2") faces) (cl-pushnew prefix out :test #'equal)))))
             faces)
    out))

(defun drgnx-lint-kit--strings ()
  "The ordinary string literals of the Rust text in the current buffer, outside comments, raw strings and char
literals: a list of their contents (escapes left as written)."
  (goto-char (point-min))
  (let (out)
    (while (re-search-forward "//\\|/\\*\\|\\br#*\"\\|\"\\|'" nil t)
      (let ((m (match-string 0)))
        (cond ((equal m "//") (forward-line 1))
              ((equal m "/*") (search-forward "*/" nil 'move))
              ((string-prefix-p "r" m)
               (search-forward (concat "\"" (make-string (- (length m) 2) ?#)) nil 'move))
              ((equal m "\"")
               (let ((start (point)))
                 (while (and (re-search-forward "\\\\.\\|\"" nil 'move) (not (equal (match-string 0) "\""))))
                 (push (buffer-substring-no-properties start (max start (1- (point)))) out)))
              ;; a char literal ('x', '\n', '\u{..}') is stepped over; a lifetime ('a) is not a literal
              ((looking-at "\\\\[^']*'\\|[^\\\\]'") (goto-char (match-end 0))))))
    (nreverse out)))

(defun drgnx-lint-kit-rust-face-count (file &optional faces families)
  "How many times FILE (Rust) names a drgnx face by string: a literal equal to one of FACES (a table of names, default
etc/ui/faces.eld's), or a `format!' literal \"PREFIX{...}\" of one of FAMILIES."
  (let* ((faces (or faces (drgnx-lint-kit--faces)))
         (families (or families (drgnx-lint-kit--families faces))))
    (with-temp-buffer
      (insert-file-contents file)
      (cl-count-if (lambda (s)
                     (or (gethash s faces)
                         (cl-some (lambda (p) (string-match-p (concat "\\`" (regexp-quote p) "{[^}]*}\\'") s))
                                  families)))
                   (drgnx-lint-kit--strings)))))

(defun drgnx-lint-kit--rust-counts ()
  "((FILE COUNT)...) for every .rs under runtime/crates/ that names a face by string (FILE relative to the checkout)."
  (let* ((faces (drgnx-lint-kit--faces)) (families (drgnx-lint-kit--families faces)) (out nil))
    (dolist (file (directory-files-recursively (expand-file-name "runtime/crates" drgnx-dir) "\\.rs\\'"))
      (let ((rel (file-relative-name file drgnx-dir)))
        (unless (or (member rel drgnx-lint-kit--enum-files) (string-search "/target/" rel))
          (let ((n (drgnx-lint-kit-rust-face-count file faces families)))
            (when (> n 0) (push (list rel n) out))))))
    (sort out (lambda (a b) (string< (car a) (car b))))))

(ert-deftest drgnx-lint/rust-faces-through-the-enum ()
  "Pattern D: no Rust file names more faces by string than the allowlist says; a file that fell below its count, or
is gone, must have its row lowered or removed."
  (let ((counts (drgnx-lint-kit--rust-counts)) (fails nil))
    (pcase-dolist (`(,file ,n) counts)
      (let ((allowed (or (cadr (assoc file drgnx-lint-kit--rust-face-literals-not-yet)) 0)))
        (when (> n allowed)
          (push (format "%s: %d face names as strings, %d above the allowlist (use FaceId::X.name())"
                        file n (- n allowed))
                fails))))
    (pcase-dolist (`(,file ,allowed) drgnx-lint-kit--rust-face-literals-not-yet)
      (let ((n (or (cadr (assoc file counts)) 0)))
        (when (< n allowed)
          (push (format "%s: %d now, the allowlist says %d: lower it" file n allowed) fails))))
    (when fails (ert-fail (string-join (nreverse fails) "\n")))))

(ert-deftest drgnx-lint/rust-face-lint-sees-each-form ()
  "Pattern D: a literal face, a face passed to a builder and a family's format! count; a non-face drgnx name, a face
in a comment, a raw string or a lifetime's neighbour does not."
  (let ((file (make-temp-file "drgnx-lint-kit" nil ".rs")))
    (unwind-protect
        (progn
          (with-temp-file file
            (insert "fn f<'a>(b: &'a mut RowBuilder, n: usize) {\n"
                    "    let x = Some(\"drgnx-text-muted\");\n"
                    "    b.face(0, 1, \"drgnx-chip\");\n"
                    "    let s = format!(\"drgnx-work-who-{}\", n);\n"
                    "    let k = \"drgnx-settings\";\n"
                    "    // \"drgnx-text-muted\" in a comment\n"
                    "    let r = r#\"{\"face\": \"drgnx-text-muted\"}\"#;\n"
                    "    let c = '\"';\n"
                    "}\n"))
          (should (= 3 (drgnx-lint-kit-rust-face-count file))))
      (delete-file file))))

(provide 'lint-kit-test)
;;; lint-kit-test.el ends here
