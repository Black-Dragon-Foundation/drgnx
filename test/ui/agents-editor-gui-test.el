;;; agents-editor-gui-test.el --- GUI measurements: drawing agent ranges beside diff-hl (run by `drgnx test --ui') -*- lexical-binding: t -*-
;; test-class: det
;; Pattern D: every picture is taken after `drgnx-test-wait-presented'.  These rows are design measurements: they
;; prototype the visible-rows rebuild of ring and gutter overlays, a per-line fringe `before-string' beside diff-hl
;; (with `diff-hl-highlight-function' wrapped, through its sync, async and flydiff updates) and the one-column margin
;; form, and print what they measured (`S1: ...' lines).  The numbers are in docs/develop/agents-editor.md.  The pixel
;; rows run in the dark, the light and the high-contrast theme, at whatever scale the session has (DRGNX_UI_SCALE: 1, 2).

(require 'ert)
(require 'cl-lib)
(require 'subr-x)
(require 'seq)
(require 'benchmark)
(require 'drgnx-wait-fixture (expand-file-name "../fixtures/wait-fixture" (file-name-directory (macroexp-file-name))))
(require 'drgnx-uitest)

(defconst agents-editor-gui--repo
  (expand-file-name "../../" (file-name-as-directory (or (getenv "DRGNX_UI_TEST") default-directory))))
(dolist (d '("core" "wb" "harness"))
  (add-to-list 'load-path (expand-file-name d agents-editor-gui--repo)))
(require 'drgnx)
(load (expand-file-name "themes/drgnx-theme-gen" agents-editor-gui--repo) nil t)
(load (expand-file-name "modules/ui/drgnx-decor" agents-editor-gui--repo) nil t)

(declare-function drgnx-decor-box "drgnx-decor")
(defvar diff-hl-highlight-function)
(defvar diff-hl-update-async)
(declare-function diff-hl-mode "diff-hl")
(declare-function diff-hl-update "diff-hl")
(declare-function diff-hl-flydiff-mode "diff-hl-flydiff")
(declare-function diff-hl-flydiff-update "diff-hl-flydiff")

;;;; Prototype: the faces, bitmaps and the visible-rows rebuild

(defconst agents-editor-gui--themes '((dark . drgnx-dark) (light . drgnx-light) (hc . drgnx-high-contrast)))
(defconst agents-editor-gui--faces
  '(font-lock-keyword-face font-lock-string-face font-lock-type-face font-lock-function-name-face
                           font-lock-constant-face)
  "Stand-ins for the five agents' colours (the identity faces arrive with the module).")

(defun agents-editor-gui--define-bitmaps ()
  "The three gutter forms: a solid bar (changed), a hollow bar (pending), a hatched bar (conflict)."
  (define-fringe-bitmap 'agents-editor-gui-bar [#x3c] 1 8 '(top t))
  (define-fringe-bitmap 'agents-editor-gui-hollow [#x24] 1 8 '(top t))
  (define-fringe-bitmap 'agents-editor-gui-hatch [#x30 #x18 #x0c #x06 #x03 #x81 #xc0 #x60] 8 8 '(top t)))

(defun agents-editor-gui--theme (theme)
  (mapc #'disable-theme custom-enabled-themes)
  (load-theme theme t))

(defun agents-editor-gui--rgb (face)
  (let ((c (or (face-foreground face nil t) (face-background face nil t))))
    (mapcar (lambda (v) (round (/ v 257.0))) (color-values c))))

(defun agents-editor-gui--ranges (n-ranges first len step)
  "A line table for N-RANGES ranges of LEN lines: line -> [AGENT STATE RANGE FIRST-P LAST-P].
Agent = range mod 5, state cycles changed, pending, conflict, read."
  (let ((table (make-hash-table)))
    (dotimes (r n-ranges)
      (let ((start (+ first (* r step))) (state (nth (% r 4) '(changed pending conflict read))))
        (dotimes (i len)
          (puthash (+ start i) (vector (% r 5) state r (= i 0) (= i (1- len))) table))))
    table))

(defvar agents-editor-gui--box-cache (make-hash-table :test #'equal))

(defun agents-editor-gui--ring-face (agent first-p last-p)
  "A ring row's face: the card box of its place (open at the joins), in AGENT's colour."
  (let ((key (list agent first-p last-p (car custom-enabled-themes) agents-editor-gui--ring-form)))
    (or (gethash key agents-editor-gui--box-cache)
        (and (eq agents-editor-gui--ring-form 'tint)
             (puthash key (list :background (face-foreground (nth agent agents-editor-gui--faces) nil t))
                      agents-editor-gui--box-cache))
        (puthash key
                 (let* ((base (drgnx-decor-box (cond ((and first-p last-p) 'drgnx-card-single)
                                                     (first-p 'drgnx-card-top) (last-p 'drgnx-card-bottom)
                                                     (t 'drgnx-card-mid))))
                        (box (plist-put (copy-sequence base) :color
                                        (face-foreground (nth agent agents-editor-gui--faces) nil t))))
                   (list :box box))
                 agents-editor-gui--box-cache))))

(defun agents-editor-gui--gutter-spec (agent state)
  (propertize " " 'display
              `((left-fringe ,(pcase state ('pending 'agents-editor-gui-hollow) ('conflict 'agents-editor-gui-hatch)
                                     (_ 'agents-editor-gui-bar))
                             ,(nth agent agents-editor-gui--faces)))))

(defun agents-editor-gui--rows (win start)
  "Rows WIN shows from START: its pixel height over the line height at START (the frame's own line count is
the default font's, not a scaled buffer's)."
  (with-current-buffer (window-buffer win)
    (save-excursion (goto-char start)
                    (1+ (ceiling (window-body-height win t) (max 1 (line-pixel-height)))))))

(defvar agents-editor-gui--priority nil "An overlay priority for the gutter overlays, or nil.")
(defvar agents-editor-gui--ring-form 'box "`box' (the card box) or `tint' (a background only), for the cost comparison.")
(defvar agents-editor-gui--skip nil "Parts the rebuild leaves out, for the cost breakdown: `ring' and/or `gutter'.")

(defvar-local agents-editor-gui--slots nil "A vector of (GUTTER-OV . RING-OV), reused across rebuilds.")
(defvar-local agents-editor-gui--active 0)
(defvar-local agents-editor-gui--table nil)

(defun agents-editor-gui--rebuild (win &optional start)
  "Put one gutter overlay and one ring overlay on each visible row that lies in a range of the table."
  (with-current-buffer (window-buffer win)
    (let* ((start (or start (window-start win))) (rows (agents-editor-gui--rows win start))
           (line (line-number-at-pos start)) (i 0) (table agents-editor-gui--table))
      (unless agents-editor-gui--slots (setq agents-editor-gui--slots (make-vector 400 nil)))
      (save-excursion
        (goto-char start)
        (dotimes (_ rows)
          (when-let* ((hit (gethash line table)))
            (let* ((slot (or (aref agents-editor-gui--slots i)
                             (aset agents-editor-gui--slots i (cons (make-overlay 1 1) (make-overlay 1 1)))))
                   (bol (line-beginning-position)) (eol (line-end-position))
                   (g (car slot)) (r (cdr slot))
                   (key (list (aref hit 0) (aref hit 1) (aref hit 3) (aref hit 4))))
              (move-overlay g bol bol (current-buffer))
              (move-overlay r bol eol (current-buffer))
              (unless (equal (overlay-get g 's1-key) key)
                (overlay-put g 's1-key key)
                (unless (memq 'gutter agents-editor-gui--skip)
                  (overlay-put g 'before-string (agents-editor-gui--gutter-spec (aref hit 0) (aref hit 1))))
                (unless (memq 'ring agents-editor-gui--skip)
                  (overlay-put r 'face (agents-editor-gui--ring-face (aref hit 0) (aref hit 3) (aref hit 4))))
                (overlay-put g 'priority agents-editor-gui--priority)
                (overlay-put g 'agents-editor-gui t))
              (cl-incf i)))
          (forward-line 1) (cl-incf line)))
      (let ((j i))
        (while (< j agents-editor-gui--active)
          (when-let* ((slot (aref agents-editor-gui--slots j)))
            (delete-overlay (car slot)) (delete-overlay (cdr slot)))
          (cl-incf j)))
      (setq agents-editor-gui--active i))))

(defun agents-editor-gui--clear ()
  (remove-overlays nil nil 'agents-editor-gui t)
  (when agents-editor-gui--slots
    (dotimes (j (length agents-editor-gui--slots))
      (when-let* ((slot (aref agents-editor-gui--slots j)))
        (overlay-put (car slot) 's1-key nil) (overlay-put (car slot) 'before-string nil)
        (overlay-put (cdr slot) 'face nil)
        (delete-overlay (car slot)) (delete-overlay (cdr slot)))))
  (setq agents-editor-gui--active 0))

(defun agents-editor-gui--pct (sorted p)
  (aref sorted (min (1- (length sorted)) (floor (* p (length sorted))))))

(defun agents-editor-gui--stats (ms)
  (let ((v (vconcat (sort (copy-sequence ms) #'<))))
    (list :n (length v) :p50 (agents-editor-gui--pct v 0.5) :p95 (agents-editor-gui--pct v 0.95)
          :max (aref v (1- (length v))))))

(defun agents-editor-gui--note (fmt &rest args)
  "Print a measurement and append it to s1.txt in the evidence folder, when there is one."
  (let ((line (apply #'format fmt args)) (dir (getenv "DRGNX_UI_EVIDENCE")))
    (message "%s" line)
    (when (and dir (file-directory-p dir))
      (ignore-errors (write-region (concat line "\n") nil (expand-file-name "s1.txt" dir) t 'silent)))))

(defun agents-editor-gui--png (name)
  "A picture of the frame as NAME.png in the evidence folder (when there is one)."
  (let ((dir (getenv "DRGNX_UI_EVIDENCE")))
    (when (and dir (file-directory-p dir))
      (condition-case err
          (let ((coding-system-for-write 'binary))
            (with-temp-buffer
              (set-buffer-multibyte nil)
              (insert (if (fboundp 'x-export-frames) (x-export-frames (drgnx-uitest-root-frame) 'png)
                        (glitnir-snapshot (drgnx-uitest-root-frame) 'png)))
              (write-region nil nil (expand-file-name (concat name ".png") dir) nil 'silent)))
        (error (agents-editor-gui--note "S1 picture %s failed: %S" name err))))))

;;;; Pixels

(defun agents-editor-gui--row-xy (win line)
  "(Y-DEVICE-MID . X-DEVICE-LEFT) of LINE's row in WIN: the window's left edge and the row's middle, in snapshot pixels."
  (with-current-buffer (window-buffer win)
    (save-excursion
      (goto-char (point-min)) (forward-line (1- line))
      (let* ((posn (posn-at-point (point) win)) (xy (posn-x-y posn))
             (origin (drgnx-uitest--text-origin win)) (s (drgnx-uitest-device-scale (selected-frame))))
        (cons (round (* s (+ (cdr origin) (cdr xy) (/ (frame-char-height) 2.0))))
              (round (* s (nth 0 (window-pixel-edges win)))))))))

(defun agents-editor-gui--owners (snap win line candidates &optional extra-cols)
  "Count, over the gutter cells (fringe, margin) of LINE's row, the pixels within 40 of each of CANDIDATES
\((NAME . RGB)); the alist of NAME to count."
  (let* ((yx (agents-editor-gui--row-xy win line)) (s (drgnx-uitest-device-scale (selected-frame)))
         (w (round (* s (+ (car (window-fringes win)) (* (or extra-cols 0) (frame-char-width)))))) (counts nil))
    (pcase-dolist (`(,name . ,_) candidates) (push (cons name 0) counts))
    (cl-loop for dy from -2 to 2
             do (dotimes (dx w)
                  (let ((px (cdr (drgnx-uitest-pixel snap (+ (cdr yx) dx) (+ (car yx) dy)))))
                    (pcase-dolist (`(,name . ,rgb) candidates)
                      (when (cl-every (lambda (a b) (<= (abs (- a b)) 40)) px rgb)
                        (cl-incf (alist-get name counts)))))))
    (nreverse counts)))

(defun agents-editor-gui--owner (counts)
  (let ((best (car (sort (copy-sequence counts) (lambda (a b) (> (cdr a) (cdr b)))))))
    (if (>= (cdr best) 3) (car best) 'none)))

;;;; Row 1: the visible-rows rebuild

(ert-deftest agents-editor-gui/s1-visible-rows-rebuild ()
  "Measure the rebuild of ring and gutter overlays on a scroll of a 120-row window, 5 agents and 20 ranges (the
bar is 2 ms); then the cost of the redisplay the overlays add; then a picture in each theme."
  (skip-unless (display-graphic-p))
  (drgnx-uitest-bare-frame)
  (agents-editor-gui--define-bitmaps)
  (with-current-buffer (get-buffer-create "*s1-rows*")
    (erase-buffer)
    (dotimes (i 3000) (insert (format "line %d of the sample file with some text on it\n" (1+ i))))
    (setq-local cursor-type nil truncate-lines t)
    (set-window-buffer (selected-window) (current-buffer))
    (let ((win (selected-window)) (scale 0))
      (while (and (< (agents-editor-gui--rows win (point-min)) 120) (> scale -12))
        (text-scale-set (cl-decf scale)) (redisplay t))
      (setq agents-editor-gui--table (agents-editor-gui--ranges 20 40 20 30))
      (let ((rows (agents-editor-gui--rows win (point-min))) direct hooked bare)
        (should (>= rows 80))
        ;; direct: the rebuild alone, 200 scrolls of 37 lines
        (dotimes (k 200)
          (let ((pos (save-excursion (goto-char (point-min)) (forward-line (* 3 (% k 100))) (point))))
            (set-window-start win pos)
            (push (* 1000 (benchmark-elapse (agents-editor-gui--rebuild win pos))) direct)))
        ;; redisplay with no overlays against redisplay with the rebuild on `window-scroll-functions'
        (agents-editor-gui--clear)
        (dotimes (k 60)
          (set-window-start win (save-excursion (goto-char (point-min)) (forward-line (* 5 k)) (point)))
          (push (* 1000 (benchmark-elapse (redisplay t))) bare))
        (add-hook 'window-scroll-functions #'agents-editor-gui--scroll nil t)
        (unwind-protect
            (dotimes (k 60)
              (set-window-start win (save-excursion (goto-char (point-min)) (forward-line (+ 2 (* 5 k))) (point)))
              (push (* 1000 (benchmark-elapse (redisplay t))) hooked))
          (remove-hook 'window-scroll-functions #'agents-editor-gui--scroll t))
        (dolist (skip '((ring) (gutter)))
          (let ((agents-editor-gui--skip skip) ms)
            (agents-editor-gui--clear)
            (add-hook 'window-scroll-functions #'agents-editor-gui--scroll nil t)
            (unwind-protect
                (dotimes (k 60)
                  (set-window-start win (save-excursion (goto-char (point-min)) (forward-line (+ 2 (* 5 k))) (point)))
                  (push (* 1000 (benchmark-elapse (redisplay t))) ms))
              (remove-hook 'window-scroll-functions #'agents-editor-gui--scroll t))
            (agents-editor-gui--note "S1 redisplay with only the %s: %S" (if (equal skip '(ring)) "gutter" "ring")
                                     (agents-editor-gui--stats ms))))
        (let ((agents-editor-gui--ring-form 'tint) (agents-editor-gui--skip '(gutter)) ms)
          (agents-editor-gui--clear)
          (add-hook 'window-scroll-functions #'agents-editor-gui--scroll nil t)
          (unwind-protect
              (dotimes (k 60)
                (set-window-start win (save-excursion (goto-char (point-min)) (forward-line (+ 2 (* 5 k))) (point)))
                (push (* 1000 (benchmark-elapse (redisplay t))) ms))
            (remove-hook 'window-scroll-functions #'agents-editor-gui--scroll t))
          (agents-editor-gui--note "S1 redisplay with only a background tint ring: %S" (agents-editor-gui--stats ms)))
        (let ((d (agents-editor-gui--stats direct)) (b (agents-editor-gui--stats bare))
              (h (agents-editor-gui--stats hooked)))
          (agents-editor-gui--note "S1 rebuild rows=%d active-last=%d direct-ms=%S" rows agents-editor-gui--active d)
          (agents-editor-gui--note "S1 redisplay bare-ms=%S with-overlays-ms=%S glitnir=%S scale=%S" b h
                                   (drgnx-uitest-glitnir-p) (drgnx-uitest-device-scale (selected-frame)))
          (should (<= (plist-get d :p95) 2.0)))
        ;; the picture, both themes
        (set-window-start win (save-excursion (goto-char (point-min)) (forward-line 40) (point)))
        (pcase-dolist (`(,variant . ,theme) agents-editor-gui--themes)
          (agents-editor-gui--theme theme)
          (clrhash agents-editor-gui--box-cache)
          (agents-editor-gui--clear)
          (agents-editor-gui--rebuild win)
          (drgnx-test-wait-presented)
          (agents-editor-gui--png (format "s1-rows-%s" variant))
          (should (> agents-editor-gui--active 0)))
        (agents-editor-gui--clear)
        (mapc #'disable-theme custom-enabled-themes)
        (kill-buffer "*s1-rows*")))))

(defun agents-editor-gui--scroll (win start)
  (agents-editor-gui--rebuild win start))

;;;; Row 2: one fringe owner per line beside diff-hl

(defvar agents-editor-gui--agent-lines nil "The line table the wrapper reads (the module reads the frame's cache).")
(defvar agents-editor-gui--previous nil)

(defun agents-editor-gui--hl-wrapper (ovl type shape)
  "diff-hl's highlight function, skipping the lines an agent owns."
  (unless (gethash (line-number-at-pos (overlay-start ovl)) agents-editor-gui--agent-lines)
    (funcall agents-editor-gui--previous ovl type shape)))

(defun agents-editor-gui--git (dir &rest args)
  (let ((process-environment (append (list (concat "HOME=" dir) "GIT_CONFIG_NOSYSTEM=1") process-environment))
        (default-directory dir))
    (should (zerop (apply #'call-process "git" nil nil nil "-c" "user.name=t" "-c" "user.email=t@t.invalid"
                          "-c" "commit.gpgsign=false" args)))))

(defun agents-editor-gui--repo-file ()
  "A temp git repo with a 300-line file committed, its lines 10-15 and 60-65 then changed on disk."
  (let* ((dir (file-name-as-directory (make-temp-file "s1-repo" t))) (file (expand-file-name "f.txt" dir)))
    (with-temp-file file (dotimes (i 300) (insert (format "row %d\n" (1+ i)))))
    (agents-editor-gui--git dir "init" "-q")
    (agents-editor-gui--git dir "add" "f.txt")
    (agents-editor-gui--git dir "commit" "-q" "-m" "base")
    (with-temp-file file
      (dotimes (i 300)
        (let ((n (1+ i)))
          (insert (if (or (<= 10 n 15) (<= 60 n 65)) (format "changed %d\n" n) (format "row %d\n" n))))))
    file))

(defun agents-editor-gui--hl-lines ()
  (let (lines)
    (dolist (o (overlays-in (point-min) (point-max)))
      (when (overlay-get o 'diff-hl)
        (push (cons (line-number-at-pos (overlay-start o)) (and (overlay-get o 'before-string) t)) lines)))
    (sort lines (lambda (a b) (< (car a) (car b))))))

(defun agents-editor-gui--fringe-line-owner (win line cands)
  (let ((pos (with-current-buffer (window-buffer win)
               (save-excursion (goto-char (point-min)) (forward-line (max 0 (- line 6))) (point)))))
    (set-window-start win pos)
    (set-window-point win (+ pos 2)))      ; point must stay in view or redisplay scrolls back
  (drgnx-test-wait-presented)
  (agents-editor-gui--owner (agents-editor-gui--owners (drgnx-uitest-snapshot) win line cands)))

(ert-deftest agents-editor-gui/s1-fringe-owner-beside-diff-hl ()
  "Pixels: an agent's gutter overlay on a line diff-hl also marks.  With diff-hl's highlight function wrapped the
line shows the agent's bar and the user's own changed lines keep diff-hl's, through diff-hl's sync update, its async
update and flydiff; unwrapped, the owner is whichever the display engine takes (printed).  Both themes."
  (skip-unless (display-graphic-p))
  ;; the GUI session's Emacs does not get DRGNX_USER_ELPA, but `bin/drgnx test --container' mounts it at /elpa
  (let ((elpa (seq-find (lambda (d) (and d (file-expand-wildcards (expand-file-name "diff-hl-*" d))))
                        (list (getenv "DRGNX_USER_ELPA") "/elpa" (expand-file-name "~/.config/emacs/elpa")))))
    (unless elpa
      (agents-editor-gui--note "S1 fringe skipped: no diff-hl (DRGNX_USER_ELPA=%S, /elpa=%S)" (getenv "DRGNX_USER_ELPA")
                               (file-directory-p "/elpa"))
      (ert-skip "no diff-hl"))
    (dolist (d (directory-files elpa t "\\`[^.]")) (when (file-directory-p d) (add-to-list 'load-path d))))
  (require 'diff-hl)
  (require 'diff-hl-flydiff)
  (handler-bind ((error (lambda (e)
                          (agents-editor-gui--note "S1 fringe error %S: %s" e
                                                   (mapconcat #'identity (seq-take (split-string (backtrace-to-string) "\n") 14) " | ")))))
    (agents-editor-gui--fringe-body)))

(defun agents-editor-gui--fringe-body ()
  (drgnx-uitest-bare-frame)
  (agents-editor-gui--define-bitmaps)
  (diff-hl-define-bitmaps)
  (let* ((file (agents-editor-gui--repo-file)) (win (selected-window))
         (buf (find-file-noselect file)) (default-hl (default-value 'diff-hl-highlight-function))
         (default-async diff-hl-update-async) (default-agent-lines agents-editor-gui--agent-lines)
         (verdicts nil))
    (unwind-protect
        (progn
          (set-window-buffer win buf)
          (with-current-buffer buf
            (setq-local cursor-type nil)
            (setq-local agents-editor-gui--table (make-hash-table))
            ;; one agent, changed lines 12-14 (the user's change at 10-15 covers them); the user's own at 60-65
            (dotimes (i 3) (puthash (+ 12 i) (vector 0 'changed 0 (= i 0) (= i 2)) agents-editor-gui--table))
            (setq agents-editor-gui--agent-lines agents-editor-gui--table)
            (setq diff-hl-update-async nil)
            (diff-hl-mode 1))
          (pcase-dolist (`(,variant . ,theme) agents-editor-gui--themes)
            (agents-editor-gui--theme theme)
            (clrhash agents-editor-gui--box-cache)
            (let ((cands `((agent . ,(agents-editor-gui--rgb 'font-lock-keyword-face))
                           (diff-hl-insert . ,(agents-editor-gui--rgb 'diff-hl-insert))
                           (diff-hl-change . ,(agents-editor-gui--rgb 'diff-hl-change)))))
              ;; the agent colour must differ from both diff-hl colours or the pixels prove nothing
              (dolist (n '(diff-hl-insert diff-hl-change))
                (should (cl-some (lambda (a b) (> (abs (- a b)) 60)) (cdr (assq 'agent cands)) (cdr (assq n cands)))))
              (dolist (mode '(unwrapped-late unwrapped-early priority-early sync async flydiff))
                (setq-default diff-hl-highlight-function default-hl)
                (when (memq mode '(sync async flydiff))
                  (setq agents-editor-gui--previous default-hl)
                  (setq-default diff-hl-highlight-function #'agents-editor-gui--hl-wrapper))
                (setq agents-editor-gui--priority (and (eq mode 'priority-early) 100))
                (with-current-buffer buf
                  (agents-editor-gui--clear)
                  (setq diff-hl-update-async (eq mode 'async))
                  (set-buffer-modified-p nil)
                  (diff-hl-remove-overlays)
                  (when (eq mode 'flydiff)
                    (diff-hl-flydiff-mode 1)
                    (save-excursion (goto-char (point-min)) (forward-line 99) (insert "unsaved\n")))
                  (unless (eq mode 'unwrapped-late)   ; ours first, diff-hl's overlays made after: the order of a redraw
                    (agents-editor-gui--rebuild win (save-excursion (goto-char (point-min)) (forward-line 5) (point))))
                  (if (eq mode 'flydiff) (diff-hl-flydiff-update) (diff-hl-update))
                  (drgnx-test-wait (lambda () (cl-some (lambda (o) (overlay-get o 'diff-hl)) (overlays-in 1 (point-max))))
                                   :what "diff-hl overlays")
                  (when (eq mode 'unwrapped-late)
                    (agents-editor-gui--rebuild win (save-excursion (goto-char (point-min)) (forward-line 5) (point)))))
                (let ((agent-line (agents-editor-gui--fringe-line-owner win 13 cands))
                      (user-line (agents-editor-gui--fringe-line-owner win 62 cands))
                      (hl (with-current-buffer buf (agents-editor-gui--hl-lines))))
                  (agents-editor-gui--note "S1 fringe %s %s: agent line 13 owner=%s, user line 62 owner=%s, diff-hl overlays with a spec on 12-14=%S"
                                           variant mode agent-line user-line
                                           (mapcar (lambda (l) (assq l hl)) '(12 13 14)))
                  (push (list variant mode agent-line user-line) verdicts)
                  (when (memq mode '(sync async flydiff))
                    (should (eq agent-line 'agent))
                    (should (memq user-line '(diff-hl-insert diff-hl-change)))
                    (should-not (cl-some #'cdr (mapcar (lambda (l) (assq l hl)) '(12 13 14)))))
                  (when (eq mode 'sync) (agents-editor-gui--png (format "s1-fringe-%s" variant)))
                  (when (eq mode 'flydiff)
                    (with-current-buffer buf (diff-hl-flydiff-mode -1) (set-buffer-modified-p nil)))))))
          (agents-editor-gui--note "S1 fringe verdicts: %S" (nreverse verdicts)))
      (setq-default diff-hl-highlight-function default-hl)
      (setq diff-hl-update-async default-async agents-editor-gui--agent-lines default-agent-lines)
      (mapc #'disable-theme custom-enabled-themes)
      (with-current-buffer buf (set-buffer-modified-p nil) (diff-hl-mode -1))
      (kill-buffer buf)
      (delete-directory (file-name-directory file) t))))

;;;; Row 3: the one-column margin form

(ert-deftest agents-editor-gui/s1-margin-form ()
  "The terminal form (a one-column left margin and a `(margin left-margin)' before-string), drawn here in a GUI
window, where margins work the same way: the marked row has the agent's colour in the margin, its neighbour none."
  (skip-unless (display-graphic-p))
  (drgnx-uitest-bare-frame)
  (with-current-buffer (get-buffer-create "*s1-margin*")
    (erase-buffer)
    (dotimes (i 40) (insert (format "line %d\n" (1+ i))))
    (setq-local cursor-type nil left-margin-width 1 left-fringe-width 0)
    (set-window-buffer (selected-window) (current-buffer))
    (let ((win (selected-window)) (agent (propertize "┃" 'face 'font-lock-keyword-face)))
      (pcase-dolist (`(,variant . ,theme) agents-editor-gui--themes)
        (agents-editor-gui--theme theme)
        (remove-overlays nil nil 'agents-editor-gui t)
        (save-excursion
          (goto-char (point-min)) (forward-line 9)
          (let ((o (make-overlay (point) (point))))
            (overlay-put o 'agents-editor-gui t)
            (overlay-put o 'before-string (propertize " " 'display `((margin left-margin) ,agent)))))
        (set-window-start win (point-min))
        (drgnx-test-wait-presented)
        (should (equal (car (window-margins win)) 1))
        (let* ((snap (drgnx-uitest-snapshot))
               (cands `((agent . ,(agents-editor-gui--rgb 'font-lock-keyword-face))))
               (on (cdar (agents-editor-gui--owners snap win 10 cands 1)))
               (off (cdar (agents-editor-gui--owners snap win 12 cands 1))))
          (agents-editor-gui--note "S1 margin %s: marked-row pixels=%d, unmarked=%d" variant on off)
          (agents-editor-gui--png (format "s1-margin-%s" variant))
          (should (>= on 3))
          (should (= off 0))))
      (mapc #'disable-theme custom-enabled-themes)
      (kill-buffer "*s1-margin*"))))

(provide 'agents-editor-gui-test)
;;; agents-editor-gui-test.el ends here

;;;; Row 3: the module's own drawing (cursors, rings, tags, the gutter strip) in a real frame

(defun agents-editor-gui--p3-frame (n)
  "A frame of five agents and the gutter ranges around them; N makes its version."
  (list :version n :agents
        (list (list :ordinal 1 :session "s1" :handle "Opus" :mode "editing" :line 30 :line_end 30 :col 4)
              (list :ordinal 2 :session "s2" :handle "Codex" :mode "reading" :line 35 :line_end 42 :col 0)
              (list :ordinal 3 :session "s3" :handle "Gemini" :mode "pending" :line 50 :line_end 55 :col 0)
              (list :ordinal 4 :session "s4" :handle "Kimi" :mode "editing" :line 60 :line_end 60 :col 0
                    :projected '(:worktree_label "rp-df-hub"))
              (list :ordinal 5 :session "s5" :handle "Deep" :mode "reading"))
        :gutter '((:session "s1" :kind "changed" :start 20 :end 24 :help "Opus · changed in step 3")
                  (:session "s3" :kind "pending" :start 50 :end 55 :help "Gemini · about to change")
                  (:session "s2" :kind "conflict" :start 70 :end 72 :help "Codex · conflicts with your change"))))

(ert-deftest agents-editor-gui/p3-drawn-frame ()
  "The module's drawing of one frame (a bar, a tinted read range, a dashed pending range, a projected tag, the strip)
in the dark, the light and the high-contrast theme: pictures, the gutter and tint pixels, and the time of an apply and a scroll rebuild
\(recorded as `P3 ...' lines; the verdict waits for the gate)."
  (skip-unless (display-graphic-p))
  (drgnx-uitest-bare-frame)
  (load (expand-file-name "modules/ui/drgnx-look-derive" agents-editor-gui--repo) nil t)
  (load (expand-file-name "modules/tools/drgnx-agents-editor-draw" agents-editor-gui--repo) nil t)
  (let ((buf (get-buffer-create "*p3-draw*")) (win (selected-window)))
    (with-current-buffer buf
      (erase-buffer)
      (dotimes (i 400) (insert (format "line %d of the sample file with some text on it\n" (1+ i))))
      (setq-local cursor-type nil truncate-lines t)
      (goto-char (point-min)))
    (set-window-buffer win buf)
    (let ((scale 0))          ; small text: the window shows rows 15 to 90
      (while (and (< (agents-editor-gui--rows win (point-min)) 80) (> scale -12))
        (with-current-buffer buf (text-scale-set (cl-decf scale))) (redisplay t)))
    (set-window-start win (with-current-buffer buf (save-excursion (goto-char (point-min)) (forward-line 14) (point))))
    (unwind-protect
        (handler-bind ((error (lambda (e) (agents-editor-gui--note "P3 error %S: %s" e
                                                                   (mapconcat #'identity (seq-take (split-string (backtrace-to-string) "\n") 14) " | ")))))
          (pcase-dolist (`(,variant . ,theme) agents-editor-gui--themes)
            (agents-editor-gui--theme theme)
            (when (fboundp 'drgnx-look-derive) (drgnx-look-derive))
            (drgnx-agent-identity-clear)
            (drgnx-agents-editor-draw-clear buf)
            (let ((ms nil))
              (dotimes (i 100)
                (push (* 1000 (benchmark-elapse (drgnx-agents-editor-draw--apply buf (agents-editor-gui--p3-frame i)))) ms))
              (agents-editor-gui--note "P3 apply %s scale=%S: %S" variant (drgnx-uitest-device-scale (selected-frame))
                                       (agents-editor-gui--stats ms)))
            (let ((ms nil))
              (dotimes (k 60)
                (set-window-start win (with-current-buffer buf (save-excursion (goto-char (point-min)) (forward-line (+ 14 (% k 20))) (point))))
                (push (* 1000 (benchmark-elapse (drgnx-agents-editor-draw--rebuild-buffer buf))) ms))
              (agents-editor-gui--note "P3 rebuild %s: %S" variant (agents-editor-gui--stats ms)))
            (set-window-start win (with-current-buffer buf (save-excursion (goto-char (point-min)) (forward-line 14) (point))))
            (set-window-point win (window-start win))
            (drgnx-agents-editor-draw--rebuild-buffer buf)
            (drgnx-test-wait-presented)
            (agents-editor-gui--note "P3 window %s: rows=%S height=%S start-line=%S visible22=%S" variant
                                     (agents-editor-gui--rows win (window-start win)) (window-body-height win)
                                     (with-current-buffer buf (line-number-at-pos (window-start win)))
                                     (with-current-buffer buf (save-excursion (goto-char (point-min)) (forward-line 21)
                                                                              (pos-visible-in-window-p (point) win))))
            (agents-editor-gui--png (format "p3-drawn-%s" variant))
            ;; the strip: line 22 shows the agent's colour in the fringe, line 40 (nothing there) does not
            (let* ((snap (drgnx-uitest-snapshot))
                   (colour (agents-editor-gui--rgb (plist-get (drgnx-agent-identity 1) :face)))
                   (own (agents-editor-gui--owner (agents-editor-gui--owners snap win 22 `((agent . ,colour)))))
                   (none (agents-editor-gui--owner (agents-editor-gui--owners snap win 40 `((agent . ,colour))))))
              (agents-editor-gui--note "P3 strip %s: line 22 owner=%S line 40 owner=%S" variant own none)
              (should (eq own 'agent))
              (should (eq none 'none))
              ;; the read range's tint: along line 38's text the default background is gone, along line 45's it stays
              (let* ((s (drgnx-uitest-device-scale (selected-frame)))
                     (x0 (+ (cdr (agents-editor-gui--row-xy win 38)) (round (* s (+ (car (window-fringes win)) 8)))))
                     (bg (cdr (drgnx-uitest-pixel snap (+ x0 (round (* s 400))) (car (agents-editor-gui--row-xy win 45)))))
                     (count (lambda (line)
                              (let ((n 0) (y (car (agents-editor-gui--row-xy win line))))
                                (dotimes (dx 120) (when (equal bg (cdr (drgnx-uitest-pixel snap (+ x0 dx) y))) (cl-incf n)))
                                n)))
                     (tinted (funcall count 38)) (plain (funcall count 45)))
                (agents-editor-gui--note "P3 tint %s: default-background pixels in 120 along line 38 (read range) %d, line 45 %d"
                                         variant tinted plain)
                (should (< tinted (/ plain 4)))))))
      (drgnx-agents-editor-draw-clear buf)
      (mapc #'disable-theme custom-enabled-themes)
      (kill-buffer buf))))

;;;; The agent panel scene (the look's agent-panel.html), in each theme and at the session's scale

(defvar drgnx-agent-panel--snap)

(ert-deftest agents-editor-gui/p3-agent-panel-scene ()
  "The panel of one agent drawn from fixture state (a snapshot with chips, a read, an edit with a card waiting and a
subagent's step) in the dark, the light and the high-contrast theme: a picture of each (`p3-panel-VARIANT.png' in the
evidence folder) and a check that text was drawn in the window (more than one colour of pixels).  The verdict on the look
waits for the gate, by eye."
  (skip-unless (display-graphic-p))
  (drgnx-uitest-bare-frame)
  (load (expand-file-name "modules/ui/drgnx-look-derive" agents-editor-gui--repo) nil t)
  (add-to-list 'load-path (expand-file-name "modules/tools" agents-editor-gui--repo))
  (require 'drgnx-agent-panel)
  (let ((win (selected-window)) buf)
    (cl-letf (((symbol-function 'drgnx-hub-call) (lambda (&rest _) 1)))
      (setq buf (drgnx-agent-panel-buffer "s1"))
      (unwind-protect
          (with-current-buffer buf
            (drgnx-agent-panel--take-snapshot
             (list :id "s1" :name "Opus" :status "waiting" :mode "default" :model "opus" :context 42
                   :permissions (list (list :id 7 :title "Run make test" :tool (list :id "t2")
                                            :options (list (list :optionId "allow" :kind "allow_once")
                                                           (list :optionId "always" :kind "allow_always")
                                                           (list :optionId "no" :kind "reject_once"))))))
            (drgnx-agent-panel--take-entries
             (list (list 0 (list :type "user" :text "make the tests pass"))
                   (list 1 (list :type "tool" :id "t1" :title "Read src/main.el" :kind "read" :status "completed"))
                   (list 2 (list :type "tool" :id "t2" :title "Run make test" :kind "execute" :status "pending"))
                   (list 3 (list :type "agent" :text "Two tests fail; looking at the first."))))
            (set-window-buffer win buf)
            (pcase-dolist (`(,variant . ,theme) agents-editor-gui--themes)
              (agents-editor-gui--theme theme)
              (when (fboundp 'drgnx-look-derive) (drgnx-look-derive))
              (drgnx-view-draw-now drgnx-view)
              (redisplay t)
              (drgnx-test-wait-presented)
              (agents-editor-gui--png (format "p3-panel-%s" variant))
              (let* ((snap (drgnx-uitest-snapshot)) (seen (make-hash-table :test #'equal)))
                (dotimes (i 40)
                  (puthash (cdr (drgnx-uitest-pixel snap (+ 20 (* i 7)) (* 2 (drgnx-uitest-device-scale (selected-frame))
                                                                           (+ 8 (* i 3)))))
                           t seen))
                (agents-editor-gui--note "P3 panel %s scale=%S: %d colours sampled" variant
                                         (drgnx-uitest-device-scale (selected-frame)) (hash-table-count seen))
                (should (> (hash-table-count seen) 1)))))
        (when (buffer-live-p buf) (kill-buffer buf))
        (mapc #'disable-theme custom-enabled-themes)))))

(provide 'agents-editor-gui-test)
;;; agents-editor-gui-test.el ends here
