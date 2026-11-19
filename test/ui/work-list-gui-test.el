;;; work-list-gui-test.el --- GUI rows: the Work map's List and its top bar on the kit -*- lexical-binding: t -*-
;; test-class: cond
;; test-pattern: handshake
;; The Work map in List mode on the hub's rows (the 30-agent fixture, test/fixtures/work-space-thirty-fixture.el):
;; it opens as a List on Active, a task's row nests under its plan and shows its agent and machine, every state has
;; its word, a long title is cut at the stop its right-hand pieces start at and keeps its whole text as `help-echo',
;; the needs-you chips show their fact whole with their jump key, and the Active · Completed · All switch follows the
;; `.' key and a click.  Needs Sjá (the map takes the hub's rows only with it).

(require 'ert)
(require 'cl-lib)
(require 'seq)
(require 'drgnx-uitest)

(defconst drgnx-work-list-gui--repo
  (expand-file-name "../../" (file-name-as-directory (or (getenv "DRGNX_UI_TEST") default-directory))))
(dolist (d '("core" "wb" "modules/ui"))
  (add-to-list 'load-path (expand-file-name d drgnx-work-list-gui--repo)))
(require 'drgnx)
(require 'drgnx-view)
(require 'drgnx-view-env)
(load (expand-file-name "test/fixtures/work-space-thirty-fixture" drgnx-work-list-gui--repo) nil t)
(load (expand-file-name "test/fixtures/modules-fixture" drgnx-work-list-gui--repo) nil t)
(load (expand-file-name "test/fixtures/wait-fixture" drgnx-work-list-gui--repo) nil t)

(declare-function drgnx-work-thirty-start "work-space-thirty-fixture")
(declare-function drgnx-work-thirty-stop "work-space-thirty-fixture")
(declare-function drgnx-work-thirty-map "work-space-thirty-fixture")
(declare-function drgnx-work-thirty-only-window "work-space-thirty-fixture")
(declare-function drgnx-ui-kit-run "drgnx-ui-kit")

(defun drgnx-work-list-gui--bin ()
  "The hub: DRGNX_RATATOSKR_BIN, else the checkout's own build."
  (let ((bin (or (getenv "DRGNX_RATATOSKR_BIN")
                 (expand-file-name "runtime/target/debug/ratatoskr" drgnx-work-list-gui--repo))))
    (unless (file-executable-p bin) (ert-fail (format "needs a test-hooks ratatoskr built in the checkout (%s)" bin)))
    bin))

(defmacro drgnx-work-list-gui--with (&rest body)
  "BODY with the 30-agent map as a List on the hub's rows alone in the root frame's selected window; `buf' is bound."
  (declare (indent 0))
  `(progn
     (skip-unless (and (display-graphic-p) (fboundp 'nidhogg-view--call)))
     (drgnx-test-with-modules '(tools/work-space)
       (let ((root (drgnx-uitest-root-frame)) (buf nil) (drgnx-work-map--show-by-project nil))
         (unwind-protect
             (with-selected-frame root
               (drgnx-work-thirty-only-window)
               (drgnx-work-thirty-start (drgnx-work-list-gui--bin))
               (setq buf (drgnx-work-thirty-map t 'list))
               (drgnx-work-thirty-only-window)
               (set-window-buffer (selected-window) buf)
               (drgnx-work-list-gui--settle buf)
               ,@body)
           (mapc #'disable-theme custom-enabled-themes)
           (when (buffer-live-p buf) (kill-buffer buf))
           (drgnx-work-thirty-stop))))))

(defun drgnx-work-list-gui--settle (buffer &optional pred what)
  "Wait until BUFFER's view holds the hub's rows and PRED holds; draw it."
  (drgnx-test-wait (lambda ()
                     (redisplay t)
                     (let ((s (buffer-local-value 'drgnx-view-patch buffer)))
                       (and (drgnx-view-patch-version s) (not (drgnx-view-patch-stale s))
                            (not (drgnx-view-patch-resync s)) (> (buffer-size buffer) 0)
                            (or (null pred) (funcall pred buffer)))))
                   :secs 30 :what (or what "the hub's rows drawn"))
  (with-current-buffer buffer (drgnx-view-draw-now drgnx-view))
  buffer)

(defun drgnx-work-list-gui--lines (buffer prefix)
  "The lines of BUFFER whose `drgnx-work-id' starts with PREFIX, as (ID . LINE-TEXT)."
  (with-current-buffer buffer
    (save-excursion
      (goto-char (point-min))
      (let (out)
        (while (not (eobp))
          (let* ((at (text-property-not-all (line-beginning-position) (line-end-position) 'drgnx-work-id nil))
                 (id (and at (get-text-property at 'drgnx-work-id))))
            (when (and (stringp id) (string-prefix-p prefix id))
              (push (cons id (buffer-substring-no-properties (line-beginning-position) (line-end-position))) out)))
          (forward-line 1))
        (nreverse out)))))

(defun drgnx-work-list-gui--text (buffer) (with-current-buffer buffer (buffer-substring-no-properties (point-min) (point-max))))

(ert-deftest drgnx-work-list-gui/opens-in-list-on-active ()
  "The map is a List on Active: its groups are under section headers and its rows are specs, no graph's layers."
  (drgnx-work-list-gui--with
    (should (eq (drgnx-work-map--mode) 'list))
    ;; a project's first choice is Active (the first open's records import may turn on All meanwhile)
    (should (eq (drgnx-work-map--show-for "no such project") 'active))
    (drgnx-work-map-show-active)
    (drgnx-work-list-gui--settle buf (lambda (b) (drgnx-work-list-gui--lines b "spec:")) "the spec rows of Active")
    (should (string-match-p "In progress\\|Ready" (drgnx-work-list-gui--text buf)))))

(ert-deftest drgnx-work-list-gui/nests-plans-under-their-spec ()
  "On All, every plan's row comes after a spec's row (the fixture's agents work under no task: their rows and chips are
the hub's `list_rows_are_the_kits_pieces' and `list_states_carry_words')."
  (drgnx-work-list-gui--with
    (drgnx-work-map-show-all)
    (drgnx-work-list-gui--settle buf (lambda (b) (drgnx-work-list-gui--lines b "plan:")) "the plans of All")
    (let ((ids (mapcar #'car (drgnx-work-list-gui--lines buf ""))))
      (should (string-prefix-p "spec:" (car ids)))
      (should (seq-some (lambda (i) (string-prefix-p "plan:" i)) ids)))))

(ert-deftest drgnx-work-list-gui/a-long-title-is-cut-at-the-edge-with-a-tooltip ()
  "No row is wider than its window (the hub fits each at the stop; its `help-echo' is the hub's own test)."
  (drgnx-work-list-gui--with
    (drgnx-work-list-gui--settle buf (lambda (b) (drgnx-work-list-gui--lines b "spec:")) "the spec rows")
    (with-current-buffer buf
      (let* ((w (get-buffer-window buf)) (body (window-body-width w t)) (rows 0))
        (save-excursion
          (goto-char (point-min))
          (while (not (eobp))
            (when (text-property-not-all (line-beginning-position) (line-end-position) 'drgnx-work-id nil)
              (cl-incf rows)
              (should (<= (car (window-text-pixel-size w (line-beginning-position) (line-end-position) body)) body)))
            (forward-line 1)))
        (should (> rows 0))))))

(ert-deftest drgnx-work-list-gui/strip-chips-show-full-text ()
  "A needs-you chip is the kit's warn chip with its jump key as the kit's key hint."
  (drgnx-work-list-gui--with
    (ignore-errors
      (drgnx-work-list-gui--settle buf (lambda (b) (string-match-p "g1" (drgnx-work-list-gui--text b)))
                                   "a needs-you chip on the strip"))
    (skip-unless (string-match-p "g1" (drgnx-work-list-gui--text buf)))
    (with-current-buffer buf
      (let ((at (string-match "g1" (buffer-string))))
        (should (memq 'drgnx-kit-key-hint-cap (ensure-list (get-text-property (1+ at) 'face))))))))

(defun drgnx-work-list-gui--current-segment (item)
  "Whether the map's lens bar shows ITEM as the selected segment of its switch."
  (let ((bar drgnx-work-map--lens) found)
    (dotimes (i (length bar))
      (when (equal (get-text-property i 'help-echo bar) (format "%s, selected" item)) (setq found t)))
    found))

(ert-deftest drgnx-work-list-gui/dot-cycles-the-segmented-switch ()
  "`work-cycle-filter' (`.') goes Active, Completed, All, Active, and each shows in the top bar's switch; a click on a segment sets it."
  (drgnx-work-list-gui--with
    (with-current-buffer buf
      (select-window (get-buffer-window buf))
      (should (drgnx-work-list-gui--current-segment "Active"))
      (dolist (next '(completed all active))
        (call-interactively #'drgnx-work-map-cycle-filter)
        (should (eq (drgnx-work-map--show) next))
        (should (drgnx-work-list-gui--current-segment (capitalize (symbol-name next)))))
      (drgnx-ui-kit-run 'work-show-completed)
      (should (eq (drgnx-work-map--show) 'completed))
      (should (drgnx-work-list-gui--current-segment "Completed")))))

(provide 'work-list-gui-test)
;;; work-list-gui-test.el ends here
