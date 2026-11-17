;;; lint-kit-test.el --- lint: the UI kit's rules (Rust names faces through FaceId; the kit's roles) -*- lexical-binding: t -*-
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
(require 'drgnx-ui-kit)

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

;;;; The kit's roles: a component that landed owns its role, and nothing else draws it

;; A component's entry in etc/ui/components.eld with `:lint t' (each component's task sets it) turns its role on.  In
;; core/, wb/ and modules/ (not core/drgnx-ui-kit.el, the kit itself) each file's count of the role's forms only falls:
;; a new `defface' whose name matches the role's FACES (domain faces, `drgnx-lint-kit--domain', never match), a use of
;; a face the entry `:replaces' or of a function it lists in `:helpers', a string holding one of the role's LITERALS;
;; and in Rust (but drgnx-rows' kit.rs and the generated enum) a use of a replaced face's `FaceId' variant.

(defconst drgnx-lint-kit-roles
  '((row :faces "-\\(selected\\|hover\\)\\(-\\|\\'\\)")
    (button :faces "-button\\(-\\|\\'\\)")
    (chip :faces "-\\(chip\\|pill\\|badge\\)\\(-\\|\\'\\)")
    (card :faces "-card\\(-\\|\\'\\)")
    (tab :faces "-\\(tab\\|tabs\\|current-tab\\)\\(-\\|\\'\\)")
    (section-header :faces "-\\(heading\\|section-header\\|section-title\\)\\(-\\|\\'\\)")
    (key-hint :faces "-\\(key-hint\\|keycap\\|kbd\\)\\(-\\|\\'\\)")
    (status-dot :faces "-status-dot\\(-\\|\\'\\)" :literals ("●")))
  "((ID :faces REGEXP :literals (STRING...))...): the roles the kit owns, each switched on by its component's `:lint t'.")

(defconst drgnx-lint-kit--domain "syntax\\|refine\\|ansi\\|debug\\|notebook"
  "Face names of a domain (syntax, diff refine, ANSI, the debugger, notebooks), never a kit role's.")

(defconst drgnx-lint-kit--not-yet
  '(;; row (Task 9): the state faces themselves, and selections and hovers no task has moved onto the kit yet
    ("core/drgnx-faces.el" row 7) ("modules/tools/drgnx-replace.el" row 1) ("modules/tools/drgnx-term.el" row 1)
    ("modules/tools/drgnx-work-space.el" row 1) ("modules/ui/drgnx-decor.el" row 1) ("modules/ui/drgnx-statusbar.el" row 1)
    ("modules/ui/drgnx-topline.el" row 1) ("runtime/crates/drgnx-ratatoskr/src/notebook/views.rs" row 1)
    ("runtime/crates/drgnx-ratatoskr/src/notebook/views/tests.rs" row 2) ("wb/drgnx-chrome.el" row 1)
    ("wb/drgnx-explorer.el" row 3) ("wb/drgnx-view-nav.el" row 1) ("wb/drgnx-view.el" row 1)
    ;; button and key-hint (Task 12): `drgnx-keycap' itself; the Flow tile's button and key faces (its keys are drawn by
    ;; the hub in the Flow's own key faces and a Lisp pass maps them to their buttons, work-flow.el, flow.rs); decor's
    ;; buttons (Task 15 moves them out)
    ("core/drgnx-palette.el" key-hint 1) ("modules/tools/drgnx-work-flow.el" button 7)
    ("modules/tools/drgnx-work-flow.el" key-hint 3) ("modules/ui/drgnx-decor.el" button 5)
    ("runtime/crates/drgnx-ratatoskr/src/work/trail/flow.rs" button 2)
    ("runtime/crates/drgnx-ratatoskr/src/work/trail/flow.rs" key-hint 2)
    ;; chip and status-dot (Task 14): the sites not moved onto the kit yet, each falling as its site moves
    ("core/drgnx-agent-identity.el" status-dot 1)
    ("core/drgnx-faces.el" chip 10)
    ("core/drgnx-freezes.el" status-dot 2)
    ("core/drgnx-history-revert.el" status-dot 3)
    ("core/drgnx-modules.el" status-dot 5)
    ("core/drgnx-notices.el" status-dot 1)
    ("core/drgnx-onboard.el" status-dot 1)
    ("core/drgnx-settings-page.el" chip 1)
    ("modules/editor/drgnx-fold.el" chip 2)
    ("modules/extra/drgnx-debug-console.el" chip 2)
    ("modules/extra/drgnx-debug-disassembly.el" chip 1)
    ("modules/extra/drgnx-debug-gutter.el" status-dot 4)
    ("modules/extra/drgnx-debug-heap.el" chip 5)
    ("modules/extra/drgnx-debug-timeline.el" chip 1)
    ("modules/extra/drgnx-debug-view.el" chip 2)
    ("modules/lang/drgnx-notebook.el" chip 8)
    ("modules/lang/drgnx-notebook.el" status-dot 1)
    ("modules/org/drgnx-org.el" chip 1)
    ("modules/tools/drgnx-agent-panel.el" chip 1)
    ("modules/tools/drgnx-replace.el" chip 4)
    ("modules/tools/drgnx-search-handoff.el" chip 1)
    ("modules/tools/drgnx-work-flow.el" chip 9)
    ("modules/tools/drgnx-work-map.el" status-dot 2)
    ("modules/tools/drgnx-work-space.el" chip 2)
    ("modules/ui/drgnx-decor.el" chip 5)
    ("modules/ui/drgnx-inbox.el" status-dot 1)
    ("modules/ui/drgnx-look-bridge.el" chip 5)
    ("modules/ui/drgnx-topline.el" chip 2)
    ("modules/ui/drgnx-topline.el" status-dot 1)
    ("modules/ui/drgnx-tty-popups.el" status-dot 1)
    ("runtime/crates/drgnx-ratatoskr/src/debug/bisect_card.rs" chip 1)
    ("runtime/crates/drgnx-ratatoskr/src/notebook/views.rs" chip 8)
    ("runtime/crates/drgnx-ratatoskr/src/notebook/views/tests.rs" chip 12)
    ("runtime/crates/vegvisir/src/trail.rs" chip 2)
    ("runtime/crates/vegvisir/tests/trail.rs" chip 2)
    ("wb/drgnx-area.el" chip 1)
    ("wb/drgnx-buffers.el" status-dot 1)
    ("wb/drgnx-chrome.el" status-dot 3)
    ("wb/drgnx-explorer.el" status-dot 2))
  "((FILE ID COUNT)...): the forms of a role that is on, left in FILE (only falls).  A branch merged later adds its
files' counts in its merge commit.")

(defun drgnx-lint-kit--entry (table id)
  "Component ID's entry (a plist) in TABLE, the components data."
  (cdr (assq id (alist-get 'components table))))

(defun drgnx-lint-kit--on (table)
  "The roles of `drgnx-lint-kit-roles' whose component in TABLE has `:lint t', as ((ID . ROLE-PLIST) . ENTRY)."
  (let (out)
    (dolist (r drgnx-lint-kit-roles (nreverse out))
      (let ((entry (drgnx-lint-kit--entry table (car r))))
        (when (eq (plist-get entry :lint) t) (push (cons r entry) out))))))

(defun drgnx-lint-kit--forms (file)
  "The forms of the Lisp FILE."
  (with-temp-buffer
    (insert-file-contents file)
    (let (forms)
      (condition-case nil (while t (push (read (current-buffer)) forms)) (end-of-file nil) (invalid-read-syntax nil))
      (nreverse forms))))

(defconst drgnx-lint-kit--doc-at
  '((defun . 3) (defmacro . 3) (cl-defun . 3) (cl-defmacro . 3) (defsubst . 3) (define-inline . 3)
    (defvar . 3) (defconst . 3) (defcustom . 3) (defface . 3))
  "Definers and the index of their docstring, which is prose, not a drawn string.")

(defun drgnx-lint-kit-role-count (file role entry)
  "How many forms of ROLE ((ID :faces :literals)) and its component ENTRY (:replaces, :helpers) the Lisp FILE has."
  (let* ((faces (plist-get (cdr role) :faces)) (literals (plist-get (cdr role) :literals))
         (old (mapcar #'car (plist-get entry :replaces))) (helpers (plist-get entry :helpers)) (n 0))
    (cl-labels ((walk (x)
                  (cond ((stringp x) (when (cl-some (lambda (l) (string-search l x)) literals) (cl-incf n)))
                        ((symbolp x) (when (and x (or (memq x old) (memq x helpers))) (cl-incf n)))
                        ((vectorp x) (mapc #'walk x))
                        ((consp x)
                         (let* ((head (car x)) (doc (cdr (assq head drgnx-lint-kit--doc-at))) (i 0) (skip nil))
                           (when (and (eq head 'defface) (symbolp (cadr x)))
                             (let ((name (symbol-name (cadr x))))
                               (when (and faces (string-match-p faces name)
                                          (not (string-match-p drgnx-lint-kit--domain name)))
                                 (cl-incf n)))
                             (setq skip 1))
                           ;; a definer's own name is not a use of it
                           (when (and doc (symbolp (cadr x))) (setq skip 1))
                           (while (consp x)
                             ;; a call of a function that shares a replaced face's name (the wrapper `drgnx-ui-button') is
                             ;; no draw of the face
                             (unless (or (eql i skip) (and doc (= i doc) (stringp (car x)) (consp (cdr x)))
                                         (and (eql i 0) (symbolp (car x)) (memq (car x) old) (fboundp (car x))))
                               (walk (car x)))
                             (setq x (cdr x) i (1+ i)))
                           (when x (walk x)))))))
      (dolist (form (drgnx-lint-kit--forms file)) (walk form)))
    n))

(defun drgnx-lint-kit--camel (face)
  "FACE's `FaceId' variant: drgnx-ui-button → UiButton."
  (mapconcat #'capitalize (split-string (string-remove-prefix "drgnx-" (symbol-name face)) "-") ""))

(defun drgnx-lint-kit-role-rust-count (file entry)
  "How many uses of the `FaceId' variants of the faces ENTRY replaces the Rust FILE has."
  (let ((old (mapcar #'car (plist-get entry :replaces))) (n 0))
    (when old
      (with-temp-buffer
        (insert-file-contents file)
        (dolist (face old)
          (goto-char (point-min))
          (while (re-search-forward (concat "\\_<FaceId::" (drgnx-lint-kit--camel face) "\\_>") nil t) (cl-incf n)))))
    n))

(defun drgnx-lint-kit--role-counts (table &optional root)
  "((FILE ID COUNT)...) of every file under ROOT (default the checkout) holding forms of a role TABLE turns on."
  (let* ((root (or root drgnx-dir)) (on (drgnx-lint-kit--on table)) (out nil))
    (when on
      (dolist (dir '("core" "wb" "modules"))
        (let ((d (expand-file-name dir root)))
          (when (file-directory-p d)
            (dolist (file (directory-files-recursively d "\\.el\\'"))
              (let ((rel (file-relative-name file root)))
                (unless (equal rel "core/drgnx-ui-kit.el")
                  (pcase-dolist (`(,role . ,entry) on)
                    (let ((n (drgnx-lint-kit-role-count file role entry)))
                      (when (> n 0) (push (list rel (car role) n) out))))))))))
      (let ((d (expand-file-name "runtime/crates" root)))
        (when (file-directory-p d)
          (dolist (file (directory-files-recursively d "\\.rs\\'"))
            (let ((rel (file-relative-name file root)))
              (unless (or (string-search "/target/" rel) (member rel drgnx-lint-kit--enum-files)
                          (equal rel "runtime/crates/drgnx-rows/src/kit.rs"))
                (pcase-dolist (`(,role . ,entry) on)
                  (let ((n (drgnx-lint-kit-role-rust-count file entry)))
                    (when (> n 0) (push (list rel (car role) n) out))))))))))
    (sort out (lambda (a b) (or (string< (car a) (car b))
                                (and (equal (car a) (car b)) (string< (symbol-name (cadr a)) (symbol-name (cadr b)))))))))

(defun drgnx-lint-kit--role-fails (counts not-yet)
  "The \"above\" and \"below\" lines of COUNTS against NOT-YET, both ((FILE ID COUNT)...)."
  (let (fails)
    (pcase-dolist (`(,file ,id ,n) counts)
      (let ((allowed (or (nth 2 (cl-find-if (lambda (e) (and (equal (car e) file) (eq (cadr e) id))) not-yet)) 0)))
        (cond ((> n allowed)
               (push (format "%s: %d %s form(s), %d allowed — above: draw it with the kit's %s" file n id allowed id) fails))
              ((< n allowed)
               (push (format "%s: %d %s form(s), %d allowed — below: lower the count in `drgnx-lint-kit--not-yet'"
                             file n id allowed)
                     fails)))))
    (pcase-dolist (`(,file ,id ,allowed) not-yet)
      (unless (cl-find-if (lambda (c) (and (equal (car c) file) (eq (cadr c) id))) counts)
        (push (format "%s: 0 %s form(s), %d allowed — below: remove its row from `drgnx-lint-kit--not-yet'"
                      file id allowed)
              fails)))
    (nreverse fails)))

(ert-deftest drgnx-lint/kit-roles ()
  "Pattern D: no file draws a role the kit owns (its component has `:lint t') more than the allowlist says; a count
that fell must be lowered."
  (let ((fails (drgnx-lint-kit--role-fails (drgnx-lint-kit--role-counts (drgnx-ui-kit-components))
                                           drgnx-lint-kit--not-yet)))
    (when fails (ert-fail (string-join fails "\n")))))

(ert-deftest drgnx-lint/kit-lint-sees-each-form ()
  "Pattern D: a role's new defface, a replaced face's use (Lisp and Rust `FaceId'), a helper's call and a literal each
count once while their component's `:lint' is on, and none while it is off; a docstring is prose."
  (let ((root (make-temp-file "drgnx-lint-kit" t)))
    (unwind-protect
        (let ((table (lambda (lint)
                       `((state-table) (components
                                        (button :lint ,lint :replaces ((drgnx-ui-button . drgnx-kit-button)))
                                        (chip :lint ,lint :helpers (drgnx-decor-chip))
                                        (status-dot :lint ,lint))))))
          (make-directory (expand-file-name "modules/x" root) t)
          (make-directory (expand-file-name "runtime/crates/x/src" root) t)
          (with-temp-file (expand-file-name "modules/x/a.el" root)
            (insert "(defface drgnx-foo-button '((t)) \"A button.\")\n"
                    "(defun f () \"Draws ● in prose.\" (drgnx-decor-chip \"x\") (insert \"●\"))\n"
                    "(defface drgnx-debug-button '((t)) \"A domain face.\")\n"))
          (with-temp-file (expand-file-name "wb/b.el" (progn (make-directory (expand-file-name "wb" root)) root))
            (insert "(defun g () (propertize \"x\" 'face 'drgnx-ui-button))\n"))
          (with-temp-file (expand-file-name "runtime/crates/x/src/a.rs" root)
            (insert "fn f() -> &'static str { FaceId::UiButton.name() }\n"))
          (should (equal (drgnx-lint-kit--role-counts (funcall table t) root)
                         '(("modules/x/a.el" button 1) ("modules/x/a.el" chip 1) ("modules/x/a.el" status-dot 1)
                           ("runtime/crates/x/src/a.rs" button 1) ("wb/b.el" button 1))))
          (should-not (drgnx-lint-kit--role-counts (funcall table nil) root))
          ;; above and below, as the timer lint says them
          (should (string-match-p "above" (car (drgnx-lint-kit--role-fails '(("a.el" chip 2)) '(("a.el" chip 1))))))
          (should (string-match-p "below" (car (drgnx-lint-kit--role-fails '(("a.el" chip 1)) '(("a.el" chip 2)))))))
      (delete-directory root t))))

(provide 'lint-kit-test)
;;; lint-kit-test.el ends here
