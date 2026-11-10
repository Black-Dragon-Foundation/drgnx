;;; look-palette-test.el --- the palette: recent commands first, keycaps from the profile, the echo area on the gap -*- lexical-binding: t -*-
;; test-class: det
;; Pattern D (pure): the recent-command history runs on the manual clock with the state directory in a temporary
;; folder; keycaps are a function of a key string; the echo-area remap is read from the buffers' remapping lists.
(require 'ert)
(require 'cl-lib)
(require 'drgnx)
(require 'drgnx-palette)
(load (expand-file-name "test/fixtures/clock-fixture" drgnx-dir) nil t)
(load (expand-file-name "modules/ui/drgnx-look" drgnx-dir) nil t)

(defmacro drgnx-look-palette-test--with-state (&rest body)
  "BODY with the state directory in a temporary folder and no history read yet."
  (declare (indent 0))
  `(let* ((dir (file-name-as-directory (make-temp-file "look-palette" t)))
          (process-environment (cons (concat "XDG_STATE_HOME=" dir) process-environment))
          (drgnx-palette--history :unloaded))
     (unwind-protect (progn ,@body) (delete-directory dir t))))

(ert-deftest drgnx-look-palette/recent-first ()
  "Pattern D, on the manual clock: the command used last ranks first, with its age as text; the history is kept in
the state directory and read back."
  (drgnx-look-palette-test--with-state
    (drgnx-test-with-clock ()
      (drgnx-palette-record 'a)
      (drgnx-test-advance 60)
      (drgnx-palette-record 'b)
      (drgnx-test-advance 120)
      (unless (eql 0 (drgnx-palette-recent-rank 'b))
        (ert-fail (list 'in-memory drgnx-palette--history)))
      (should (= 0 (drgnx-palette-recent-rank 'b)))
      (should (= 1 (drgnx-palette-recent-rank 'a)))
      (should-not (drgnx-palette-recent-rank 'never))
      (should (equal "used 2 min ago" (drgnx-palette-recent-age 'b)))
      (should (equal "used 3 min ago" (drgnx-palette-recent-age 'a)))
      (should-not (drgnx-palette-recent-age 'never))
      (setq drgnx-palette--history :unloaded)                         ; read back from the file
      (unless (eql 0 (drgnx-palette-recent-rank 'b))
        (ert-fail (list 'read-back drgnx-palette--history (drgnx-palette--history-file)
                        (file-exists-p (drgnx-palette--history-file)))))
      (should (= 0 (drgnx-palette-recent-rank 'b)))
      (should (equal '("Y: B" "X: A" "Z: C")
                     (drgnx-palette-sort '("X: A" "Y: B" "Z: C") '(("X: A" . a) ("Y: B" . b) ("Z: C" . c))))))))

(ert-deftest drgnx-look-palette/keycaps-from-the-profile ()
  "Pattern D: the palette's own key in each profile, as keycaps: Ctrl Shift P for vscode and Emacs, Space Space for
Vim; a chord is one cap a key, a function key its number."
  (unless drgnx-keys-profiles
    (setq drgnx-keys-profiles (drgnx-keys-load-profiles (expand-file-name "keys" drgnx-dir))))
  (let ((first-key (lambda (p) (seq-find #'stringp (cdr (assq 'palette (plist-get (alist-get p drgnx-keys-profiles) :bind)))))))
    (should (equal '("Ctrl" "Shift" "P") (drgnx-palette-keycap-names (funcall first-key 'vscode))))
    (should (equal '("Ctrl" "Shift" "P") (drgnx-palette-keycap-names (funcall first-key 'emacs))))
    (should (equal '("Space" "Space") (drgnx-palette-keycap-names (funcall first-key 'vim)))))
  (should (equal '("F1") (drgnx-palette-keycap-names "<f1>")))
  (should (equal '("Alt" "X") (drgnx-palette-keycap-names "M-x")))
  (should (equal '("Space" "F" "F") (drgnx-palette-keycap-names "SPC f f")))
  (let ((caps (cl-letf (((symbol-function 'display-graphic-p) #'always)) (drgnx-palette-keycaps "C-S-p"))))
    (should (equal "Ctrl Shift P" (string-join (split-string (substring-no-properties caps)) " ")))
    (should (equal '(space :width (4)) (get-text-property 0 'display caps)))   ; room inside the cap
    (should (eq 'drgnx-keycap (get-text-property 0 'face caps))))
  ;; a terminal draws no ring: the names alone, one space between
  (should (equal "Ctrl Shift P" (substring-no-properties (drgnx-palette-keycaps "C-S-p")))))

(ert-deftest drgnx-look-palette/echo-area-remap-on-and-off ()
  "Pattern D: the echo area's buffer and every minibuffer draw `default' as the gap surface while the module is on;
off, the buffers have no such entry and the hook is gone."
  (let ((echo (get-buffer-create " *Echo Area 0*")) (mini (get-buffer-create " *Minibuf-look-test*")))
    (unwind-protect
        (progn
          (drgnx-look-echo-area-on)
          (should (memq 'drgnx-look--minibuffer-gap minibuffer-setup-hook))
          (should (memq 'drgnx-look--minibuffer-inactive-gap minibuffer-inactive-mode-hook))
          (with-current-buffer echo (should (eq 'drgnx-surface-gap (cadr (assq 'default face-remapping-alist)))))
          (with-current-buffer mini (drgnx-look--minibuffer-gap)
                               (should (eq 'drgnx-surface-gap (cadr (assq 'default face-remapping-alist)))))
          (drgnx-look-echo-area-off)
          (should-not (memq 'drgnx-look--minibuffer-gap minibuffer-setup-hook))
          (should-not (memq 'drgnx-look--minibuffer-inactive-gap minibuffer-inactive-mode-hook))
          (with-current-buffer echo (should-not (assq 'default face-remapping-alist))))
      (drgnx-look-echo-area-off)
      (kill-buffer mini))))

(ert-deftest drgnx-look-palette/sort-reads-the-history-once ()
  "Sorting the labels for one key reads the history once, whatever the number of labels, and keeps the order of the
rest."
  (drgnx-look-palette-test--with-state
    (drgnx-test-with-clock ()
      (drgnx-palette-record 'a)
      (drgnx-test-advance 60)
      (drgnx-palette-record 'c)
      (let* ((cands (mapcar (lambda (i) (cons (format "Cmd: %d" i) (intern (format "k%d" i)))) (number-sequence 1 300)))
             (cands (append cands '(("X: A" . a) ("Z: C" . c))))
             (labels (mapcar #'car cands)) (reads 0) (orig (symbol-function 'drgnx-palette--history)))
        (cl-letf (((symbol-function 'drgnx-palette--history) (lambda () (cl-incf reads) (funcall orig))))
          (let ((sorted (drgnx-palette-sort labels cands)))
            (should (= reads 1))
            (should (equal (seq-take sorted 3) '("Z: C" "X: A" "Cmd: 1")))
            (should (equal (cddr sorted) (seq-take labels 300)))))))))

(defun drgnx-look-palette-test--faces (face)
  "FACE (a text property value) as a flat list of face names and plists."
  (if (and (consp face) (not (keywordp (car face)))) face (list face)))

(defun drgnx-look-palette-test--boxed-p (face)
  "Non-nil when FACE carries the row's inside box."
  (cl-some (lambda (f) (and (consp f) (plist-get f :box))) (drgnx-look-palette-test--faces face)))

(ert-deftest drgnx-look-palette/the-current-row-is-one-rounded-inset-run ()
  "Pattern D, palette.html `.row.sel': the current candidate is one rounded fill, 6 logical pixels in from the
popup's sides: an inset before it (outside the fill), the text and a stretch to 6 pixels short of the right edge in the
current face with the row's inside box (one box run: the stretch ends it, so its right corners are drawn), then a
plain newline (no fill past the row).  Every row gets the same left inset, so the text does not move."
  (load (expand-file-name "modules/extra/drgnx-completion" drgnx-dir) nil t)
  (let* ((cand (let ((s (concat "Run Tests" "\n"))) (add-face-text-property 0 (length s) 'vertico-current t s) s))
         (row (drgnx-completion--row cand t))
         (n (length row)))
    (should (equal "\n" (substring row -1)))
    (should-not (memq 'vertico-current (drgnx-look-palette-test--faces (get-text-property (1- n) 'face row))))
    (should (get-text-property 0 'display row))                                         ; the left inset
    (should-not (memq 'vertico-current (drgnx-look-palette-test--faces (get-text-property 0 'face row))))
    (should (string-search "Run Tests" row))
    (cl-loop for i from 1 below (1- n)
             do (should (memq 'vertico-current (drgnx-look-palette-test--faces (get-text-property i 'face row))))
             do (should (drgnx-look-palette-test--boxed-p (get-text-property i 'face row))))
    (should (string-match-p "align-to" (format "%S" (get-text-property (- n 2) 'display row))))
    (let ((other (drgnx-completion--row (copy-sequence "Run Test at Point\n") nil)))
      (should (get-text-property 0 'display other))
      (should (equal "Run Test at Point\n" (substring other 1)))
      (should-not (drgnx-look-palette-test--boxed-p (get-text-property 1 'face other))))))

(ert-deftest drgnx-look-palette/secondary-text-on-the-current-row-is-muted ()
  "Pattern D, the look's contrast rule: on the current candidate, text in the subtle colour (a keycap, an
annotation) is `drgnx-selected-secondary' (muted: subtle is 3.8:1 on the dark selection, 4.3 on the light); the
candidate's own text keeps its face; other rows keep subtle.  Under each drgnx theme the face is at least 4.5:1 on
the selection (7 in high contrast)."
  (load (expand-file-name "modules/extra/drgnx-completion" drgnx-dir) nil t)
  (load (expand-file-name "themes/drgnx-theme-gen" drgnx-dir) nil t)
  (pcase-dolist (`(,theme . ,bar) '((drgnx-dark . 4.5) (drgnx-light . 4.5) (drgnx-high-contrast . 7.0)))
    (unwind-protect
        (progn
          (mapc #'disable-theme custom-enabled-themes)
          (load-theme theme t)
          (let* ((cand (concat "Run Tests" (propertize "  C-; F" 'face 'drgnx-keycap)
                               (propertize "  Tests" 'face 'completions-annotations) "\n"))
                 (row (drgnx-completion--row (let ((s (copy-sequence cand)))
                                               (add-face-text-property 0 (length s) 'vertico-current t s) s)
                                             t))
                 (other (drgnx-completion--row (copy-sequence cand) nil))
                 (at (lambda (s text) (drgnx-look-palette-test--faces (get-text-property (string-search text s) 'face s)))))
            (should (memq 'drgnx-selected-secondary (funcall at row "C-; F")))
            (should (memq 'drgnx-selected-secondary (funcall at row "  Tests")))
            (should-not (memq 'drgnx-selected-secondary (funcall at row "Run")))
            (should-not (memq 'drgnx-selected-secondary (funcall at other "C-; F")))
            (let ((ratio (drgnx-color-contrast (face-foreground 'drgnx-selected-secondary nil t)
                                               (face-background 'drgnx-selected nil t))))
              (should (>= ratio bar)))))
      (mapc #'disable-theme custom-enabled-themes))))

(ert-deftest drgnx-look-palette/a-row-is-icon-title-category-and-keys ()
  "Pattern D: palette.html's row.  The shown row is the title without its category (the matched letters keep their
faces) after an icon; the annotation is the category in the subtle colour and no doc; keycaps sit at the right edge;
a group's title is the group's name in its own face (no count, no rule line)."
  (let ((drgnx-commands--table (make-hash-table :test #'eq)) (drgnx-commands--order nil) (meta nil))
    (drgnx-command-define 'look-palette-test-run :title "Run Tests in This File" :category "Tests"
                          :doc "Run every test of the file." :command #'ignore)
    (cl-letf (((symbol-function 'completing-read)
               (lambda (_prompt table &rest _) (setq meta (completion-metadata "" table nil)) "")))
      (drgnx-palette))
    (let* ((label "Tests: Run Tests in This File")
           (lit (concat (propertize "Tests: Run" 'face 'completions-common-part) " Tests in This File"))
           (group (completion-metadata-get meta 'group-function))
           (shown (funcall group lit t))
           (note (funcall (completion-metadata-get meta 'annotation-function) label)))
      (should (string-suffix-p "Run Tests in This File" shown))
      (should-not (string-search "Tests: " shown))
      (should (eq 'completions-common-part (get-text-property (string-search "Run" shown) 'face shown)))
      (should (string-search "Tests" note))
      (should-not (string-search "every test" note))
      (should (memq 'drgnx-text-subtle (ensure-list (get-text-property (string-search "Tests" note) 'face note))))
      (should (equal "Commands" (string-trim (substring-no-properties (funcall group label nil)))))
      (let ((title (funcall group label nil)))
        (should (eq 'drgnx-palette-group (get-text-property (string-search "Commands" title) 'face title))))))
  ;; keys: right-aligned caps on a graphical frame
  (let ((note (cl-letf (((symbol-function 'display-graphic-p) #'always))
                (drgnx-palette--annotation "Tests" nil "C-; f"))))
    (should (string-search "Ctrl" note))
    (should (seq-some (lambda (i) (eq :align-to (car-safe (cdr-safe (get-text-property i 'display note)))))
                      (number-sequence 0 (1- (length note)))))))

(provide 'look-palette-test)
;;; look-palette-test.el ends here
