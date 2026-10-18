;;; drgnx-wm-other-test.el --- live: move and restore across monitors under KWin; niri on its one output -*- lexical-binding: t -*-
;; Each test runs only in its compositor's tier, in the window managers' image (test/container/Containerfile.wm):
;; `DRGNX_TEST_SELECTOR='"^drgnx-wm/"' bin/drgnx test --container --ui --compositor kwin' (or `niri'); elsewhere
;; it is skipped.  The sessions are daemons of the `drgnx' config with monitors of 1280x800 in a temp state root;
;; `emacsclient -c' opens the main window, as a user does.  Which monitor a frame is on is Emacs' own answer
;; (`frame-monitor-attributes', from the compositor's Wayland output events), not the adapter's.
;; niri runs nested in a headless sway and has exactly one output there: its move between outputs cannot run.
(require 'ert)
(require 'seq)
(require 'subr-x)
(require 'drgnx-ui)

;;;; Helpers

(defun drgnx-wm-other--eval (sess form)
  "FORM's value (any Lisp value, printed) from SESS."
  (car (read-from-string
        (plist-get (drgnx-ui-call sess (format "(drgnx-uitest--json (list :v (prin1-to-string %s)))" form)) :v))))

(defun drgnx-wm-other--until (thunk &optional seconds)
  "Call THUNK every 0.2 s until it returns non-nil (that value) or SECONDS (default 8) pass (nil)."
  (let ((deadline (+ (float-time) (or seconds 8))) r)
    (while (and (not (setq r (funcall thunk))) (< (float-time) deadline))
      (sleep-for 0.2))
    r))

(defmacro drgnx-wm-other--in-root (root &rest body)
  "BODY with ROOT a temp directory that is the harness state root (and where saved layouts go)."
  (declare (indent 1))
  `(let* ((,root (make-temp-file "drgnx-wmo" t))
          (process-environment (cons (concat "DRGNX_UI_STATE=" ,root) process-environment)))
     (unwind-protect (progn ,@body) (delete-directory ,root t))))

(defconst drgnx-wm-other--session-lisp
  "(progn
     (defvar drgnx-wmt-main nil) (defvar drgnx-wmt-aux nil) (defvar drgnx-wmt-result nil)
     (defun drgnx-wmt-gui-frames ()
       (seq-filter (lambda (f) (and (display-graphic-p f) (not (frame-parent f)))) (frame-list)))
     (defun drgnx-wmt-aux-frame ()
       (seq-find (lambda (f) (eq (frame-parameter f 'drgnx-frame-role) 'aux)) (drgnx-wmt-gui-frames)))
     (defun drgnx-wmt-monitor (f)
       (let ((g (alist-get 'geometry (frame-monitor-attributes f))))
         (cond ((null g) nil) ((= (car g) 0) 1) ((= (car g) 1280) 2) (t (car g)))))
     (defun drgnx-wmt-call (fn &rest args)
       (setq drgnx-wmt-result 'pending)
       (apply fn (append args (list (lambda (r) (setq drgnx-wmt-result r)))))
       t)
     t)"
  "Defined in every session: the graphical windows, the aux one, which monitor (1 or 2) Emacs says a frame is on,
and a way to call an asynchronous function whose answer lands in `drgnx-wmt-result'.")

(defun drgnx-wm-other--start (compositor monitors saved)
  "Start a daemon session under COMPOSITOR with MONITORS outputs, its layout file SAVED; return the session."
  (let* ((s (drgnx-ui-start "drgnx" "1280x800" 60 t monitors compositor))
         (sess (drgnx-ui-own-session (plist-get s :name))))
    (drgnx-wm-other--eval sess (format "(progn (setq drgnx-persist-file %S) %s)" saved drgnx-wm-other--session-lisp))
    sess))

(defun drgnx-wm-other--open-main (sess &optional file)
  "Open the main window of SESS (`emacsclient -c'); with FILE, it shows that file.  The frame is `drgnx-wmt-main'."
  (should (eql 0 (plist-get (drgnx-ui-new-frame sess) :exit)))
  (should (drgnx-wm-other--until (lambda () (drgnx-wm-other--eval sess "(and (drgnx-wmt-gui-frames) t)"))))
  ;; the window that is not an aux one: a restore may already have opened its aux window
  (drgnx-wm-other--eval
   sess (format "(progn (setq drgnx-wmt-main (seq-find (lambda (f) (not (eq (frame-parameter f 'drgnx-frame-role) 'aux)))
                                                       (drgnx-wmt-gui-frames)))
                        %s t)"
                (if file (format "(with-selected-frame drgnx-wmt-main (find-file %S) (drgnx-chrome-apply nil t))" file) ""))))

(defun drgnx-wm-other--aux (sess)
  "Move the shown file of SESS's main window into a new window, `drgnx-wmt-aux'; wait until the WM has put it on
a monitor."
  (drgnx-wm-other--eval
   sess "(progn (with-selected-frame drgnx-wmt-main (drgnx-frames-move-editor) (setq drgnx-wmt-aux (selected-frame))) t)")
  (should (drgnx-wm-other--until (lambda () (eql 2 (drgnx-wm-other--eval sess "(length (drgnx-wmt-gui-frames))")))))
  (should (drgnx-wm-other--until
           (lambda () (drgnx-wm-other--eval sess "(and (frame-visible-p drgnx-wmt-aux) (drgnx-wmt-monitor drgnx-wmt-aux))")))))

(defun drgnx-wm-other--call (sess form)
  "Run FORM, a call (FN ARGS…) of an asynchronous function whose last argument is its callback, in SESS: the
callback's value.  Waits at most 8 s."
  (drgnx-wm-other--eval sess (format "(drgnx-wmt-call %s)" form))
  (let ((r (drgnx-wm-other--until (lambda () (let ((v (drgnx-wm-other--eval sess "drgnx-wmt-result")))
                                               (and (not (eq v 'pending)) (list v)))))))
    (should r)
    (car r)))

(defun drgnx-wm-other--move (sess target)
  "`drgnx-monitors-move' of `drgnx-wmt-aux' to TARGET (a number, `next', `previous'): its callback's value."
  (drgnx-wm-other--call sess (format "#'drgnx-monitors-move drgnx-wmt-aux (quote %S)" target)))

(defun drgnx-wm-other--on (sess frame n)
  "Wait until Emacs says FRAME (a form) is on monitor N; non-nil if it is."
  (drgnx-wm-other--until (lambda () (eql n (drgnx-wm-other--eval sess (format "(drgnx-wmt-monitor %s)" frame))))))

;;;; KWin: two virtual outputs

(ert-deftest drgnx-wm/kwin-move-to-monitor-2-and-back ()
  (skip-unless (equal (drgnx-ui-default-compositor) "kwin"))
  (drgnx-wm-other--in-root root
    (let* ((file (expand-file-name "a.txt" root))
           (_ (write-region "a\n" nil file nil 'silent))
           (sess (drgnx-wm-other--start "kwin" 2 (expand-file-name "saved/workbench.eld" root))))
      (unwind-protect
          (progn
            (drgnx-wm-other--open-main sess file)
            (drgnx-wm-other--aux sess)
            ;; Emacs knows it is under KWin, and KWin lists its two outputs with Emacs' geometry
            (should (eq 'kwin (drgnx-wm-other--eval sess "(drgnx-platform-wm drgnx-wmt-aux)")))
            (let ((mons (drgnx-wm-other--call sess "#'drgnx-platform-monitors drgnx-wmt-aux")))
              (should (equal (mapcar (lambda (m) (plist-get m :geometry)) mons) '((0 0 1280 800) (1280 0 1280 800)))))
            (should (drgnx-wm-other--on sess "drgnx-wmt-aux" 1))
            ;; to monitor 2: only the aux window moves
            (should (eq 'ok (drgnx-wm-other--move sess 2)))
            (should (drgnx-wm-other--on sess "drgnx-wmt-aux" 2))
            (should (eql 1 (drgnx-wm-other--eval sess "(drgnx-wmt-monitor drgnx-wmt-main)")))
            ;; Next wraps round to monitor 1
            (should (eq 'ok (drgnx-wm-other--move sess 'next)))
            (should (drgnx-wm-other--on sess "drgnx-wmt-aux" 1))
            (should (eql 1 (drgnx-wm-other--eval sess "(drgnx-wmt-monitor drgnx-wmt-main)"))))
        (drgnx-ui-stop (plist-get sess :name))))))

(ert-deftest drgnx-wm/kwin-restore-puts-the-aux-window-back ()
  (skip-unless (equal (drgnx-ui-default-compositor) "kwin"))
  (drgnx-wm-other--in-root root
    (let ((saved (expand-file-name "saved/workbench.eld" root))
          (file (expand-file-name "a.txt" root)))
      (write-region "a\n" nil file nil 'silent)
      ;; a session leaves its aux window on monitor 2 and stops: the layout is saved
      (let ((sess (drgnx-wm-other--start "kwin" 2 saved)))
        (unwind-protect
            (progn
              (drgnx-wm-other--open-main sess file)
              (drgnx-wm-other--aux sess)
              (should (eq 'ok (drgnx-wm-other--move sess 2)))
              (should (drgnx-wm-other--on sess "drgnx-wmt-aux" 2)))
          (drgnx-ui-stop (plist-get sess :name))))
      (should (string-match-p ":monitors-monitor" (with-temp-buffer (insert-file-contents saved) (buffer-string))))
      ;; the next session restores it there within the restore deadline (5 s); the main window stays where KWin put it
      (let ((sess (drgnx-wm-other--start "kwin" 2 saved)))
        (unwind-protect
            (progn
              (drgnx-wm-other--open-main sess)
              (should (drgnx-wm-other--until (lambda () (drgnx-wm-other--eval sess "(and (drgnx-wmt-aux-frame) t)")) 5))
              (should (drgnx-wm-other--on sess "(drgnx-wmt-aux-frame)" 2))
              (should (eql 1 (drgnx-wm-other--eval sess "(drgnx-wmt-monitor drgnx-wmt-main)")))
              ;; the placement gave the frame its own title back
              (should-not (string-match-p "placing" (drgnx-wm-other--eval sess "(frame-parameter (drgnx-wmt-aux-frame) 'name)"))))
          (drgnx-ui-stop (plist-get sess :name)))))))

;;;; niri: one output (nested in sway)

(ert-deftest drgnx-wm/niri-lists-its-output-and-places-its-own-window ()
  (skip-unless (equal (drgnx-ui-default-compositor) "niri"))
  (drgnx-wm-other--in-root root
    (let ((sess (drgnx-wm-other--start "niri" 1 (expand-file-name "saved/workbench.eld" root))))
      (unwind-protect
          (progn
            (drgnx-wm-other--open-main sess)
            ;; Emacs knows it is under niri, not the sway niri runs in
            (should (eq 'niri (drgnx-wm-other--eval sess "(drgnx-platform-wm drgnx-wmt-main)")))
            ;; niri's one output, with the geometry Emacs sees
            (let ((mons (drgnx-wm-other--call sess "#'drgnx-platform-monitors drgnx-wmt-main"))
                  (geometry (drgnx-wm-other--eval sess "(alist-get 'geometry (frame-monitor-attributes drgnx-wmt-main))")))
              (should (= 1 (length mons)))
              (should (equal (plist-get (car mons) :name) "winit"))
              (should (equal (plist-get (car mons) :geometry) geometry))
              ;; a restore finds Emacs' window by its pid and a temporary title, and gives the title back
              (drgnx-wm-other--eval sess "(progn (set-frame-parameter drgnx-wmt-main 'title \"drgnx-main\") t)")
              (should (eq 'ok (drgnx-wm-other--call sess (format "#'drgnx-platform-place-frame drgnx-wmt-main '%S" (car mons)))))
              (should (equal "drgnx-main" (drgnx-wm-other--eval sess "(frame-parameter drgnx-wmt-main 'title)")))
              ;; a command's move: niri's focused window is Emacs' own, and the frame has focus.  The sway niri runs
              ;; in has no keyboard, so Emacs never gets the focus-in event a real seat gives: the test delivers it
              (drgnx-wm-other--eval sess "(progn (handle-focus-in (list 'focus-in drgnx-wmt-main)) t)")
              (should (eq 'ok (drgnx-wm-other--call sess (format "#'drgnx-platform-move-frame drgnx-wmt-main '%S" (car mons)))))
              ;; an output niri does not have is an error, not niri's silent no-op
              (let ((r (drgnx-wm-other--call sess "#'drgnx-platform-place-frame drgnx-wmt-main '(:name \"nope\" :geometry (1280 0 1280 800))")))
                (should (eq :error (car-safe r)))
                (should (string-match-p "niri has no output named \"nope\"" (cadr r))))
              ;; the command says there is only one monitor
              (let ((r (drgnx-wm-other--call sess "#'drgnx-monitors-move drgnx-wmt-main 'next")))
                (should (equal r (list :error (drgnx-wm-other--eval sess "drgnx-monitors--only-one")))))))
        (drgnx-ui-stop (plist-get sess :name))))))

;;; drgnx-wm-other-test.el ends here
