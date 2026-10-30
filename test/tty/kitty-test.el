;;; kitty-test.el --- tty tier, the exit test: emacsclient -t in a real kitty -*- lexical-binding: t -*-
;; Run under `drgnx-run-ert-batch' (temp HOME and XDG dirs).  One drgnx daemon under headless mutter and a kitty on
;; that display running `emacsclient -t' (`drgnx-tty-session-kitty-start').  Keys go in through kitty's own encoder
;; (`kitten @ send-key'), mouse reports as raw bytes (`send-text'); the screen comes from `get-text', the clipboard
;; from `wl-paste' on the session's display.  kitty is installed only in test/container/Containerfile.tty: anywhere
;; else every test skips (bin/drgnx test --container --tty).  kkp comes from DRGNX_USER_ELPA, as in keys-test.el.
(require 'ert)
(require 'drgnx-tty-session)
(unless (featurep 'tty-keys-helpers)
  (load (expand-file-name "tty-keys-helpers" (file-name-directory (or load-file-name buffer-file-name))) nil t))

(defmacro drgnx-tty-kitty-test--with (spec &rest body)
  "Run BODY with (car SPEC) a kitty session, kkp on its daemon's load path when DRGNX_USER_ELPA has it; stop it
afterwards.  (cdr SPEC) :kkp t: skip unless kkp is there; :size: kitty's size in cells (default 120x40)."
  (declare (indent 1))
  `(progn
     (drgnx-tty-session-kitty-require)
     ,@(when (plist-get (cdr spec) :kkp) '((drgnx-tty-keys-test--need-kkp)))
     (let* ((root (make-temp-file "drgnx-kitty" t))
            (process-environment (cons (concat "DRGNX_UI_STATE=" root) process-environment))
            (,(car spec) nil))
       (unwind-protect
           (progn
             (setq ,(car spec) (drgnx-tty-session-kitty-start
                                :size ,(plist-get (cdr spec) :size)
                                :env (and (drgnx-tty-keys-test--kkp-dir) (drgnx-tty-keys-test--env))))
             (drgnx-tty-session-wait-screen ,(car spec) "\\*\\(?:scratch\\|drgnx start\\)\\*" 30)
             ,@body)
         (when ,(car spec) (drgnx-tty-session-kitty-stop ,(car spec)))
         (delete-directory root t)))))

(defconst drgnx-tty-kitty-test--frame
  '(seq-find (lambda (f) (and (frame-parameter f 'client) (not (display-graphic-p f)))) (frame-list))
  "A form, in the daemon: kitty's frame (the one terminal client).")

(defun drgnx-tty-kitty-test--in (s form)
  "FORM's value in the daemon of S with kitty's frame selected."
  (drgnx-tty-session-eval s `(with-selected-frame ,drgnx-tty-kitty-test--frame ,form)))

(defun drgnx-tty-kitty-test--caps (s)
  (drgnx-tty-session-eval s `(terminal-parameter (frame-terminal ,drgnx-tty-kitty-test--frame) 'drgnx-tty-caps)))

(defun drgnx-tty-kitty-test--kkp-on (s)
  "Wait until kkp is on in kitty's terminal and drgnx marked it."
  (drgnx-tty-session-wait s `(let ((term (frame-terminal ,drgnx-tty-kitty-test--frame)))
                               (and (terminal-parameter term 'drgnx-tty-kkp) (kkp--active-p term)))
                          10))

(defun drgnx-tty-kitty-test--quit (s)
  "ctrl+g through kitty until the minibuffer is gone (a C-g while the palette fills its list quits only that)."
  (let ((tries 0))
    (while (and (drgnx-tty-session-eval s '(and (active-minibuffer-window) t)) (< tries 5))
      (drgnx-tty-session-kitty-key s "ctrl+g")
      (setq tries (1+ tries))
      (let ((deadline (+ (float-time) 1)))
        (while (and (drgnx-tty-session-eval s '(and (active-minibuffer-window) t)) (< (float-time) deadline))
          (sleep-for 0.05))))
    (should-not (drgnx-tty-session-eval s '(active-minibuffer-window)))))

;;;; Keys

(ert-deftest drgnx-kitty/kkp-is-active ()
  (drgnx-tty-kitty-test--with (s :kkp t)
    (drgnx-tty-kitty-test--kkp-on s)
    (let ((caps (drgnx-tty-kitty-test--caps s)))
      (should (eq (plist-get caps :id) 'kitty))
      (should (eq (plist-get caps :keys) 'kkp)))))

(ert-deftest drgnx-kitty/the-fallback-layer-is-inactive ()
  ;; kitty sends every chord: no Alt+Shift or F6 layer, and no hint about one
  (drgnx-tty-kitty-test--with (s :kkp t)
    (drgnx-tty-kitty-test--kkp-on s)
    (should-not (drgnx-tty-session-eval s `(terminal-parameter (frame-terminal ,drgnx-tty-kitty-test--frame)
                                                               'drgnx-tty-fallback)))
    (should-not (drgnx-tty-kitty-test--in s '(functionp (lookup-key input-decode-map "\eF"))))
    ;; Alt+Shift+P and F6 reach commands of the test's own as themselves.  Alt+Shift+P is M-P from a keyboard (kitty
    ;; reports the shifted key, P); send-key has no keyboard layout, so kitty reports no shifted key and kkp names it
    ;; M-S-p.  Either way it is Alt+Shift+P, never the palette.
    (drgnx-tty-session-eval
     s '(progn
          (defun kx-meta-p () (interactive))
          (defun kx-f6 () (interactive))
          (push (list (cons t (let ((m (make-sparse-keymap)))
                                (define-key m (kbd "M-P") #'kx-meta-p)
                                (define-key m (kbd "M-S-p") #'kx-meta-p)
                                (define-key m [f6] #'kx-f6)
                                m)))
                emulation-mode-map-alists)
          t))
    (drgnx-tty-session-eval s drgnx-tty-keys-test--record)
    (drgnx-tty-session-kitty-key s "alt+shift+p")
    (drgnx-tty-session-wait s '(seq-find (lambda (e) (and (eq (car e) 'kx-meta-p) (member (cdr e) '("M-P" "M-S-p"))))
                                         kx-seen)
                            10)
    (should-not (drgnx-tty-session-eval s '(assq 'drgnx-palette kx-seen)))
    (should-not (drgnx-tty-session-eval s '(active-minibuffer-window)))
    (drgnx-tty-session-kitty-key s "f6")
    (drgnx-tty-keys-test--ran s 'kx-f6 "<f6>")
    ;; no hint: none was recorded for kitty, none was said — after the moment it would have come (0.5 s), so the
    ;; check cannot pass early
    (sleep-for 1)
    (let ((hint (drgnx-tty-session-eval s '(drgnx-tty-fallback-hint-text))))
      (should-not (memq 'kitty (plist-get (drgnx-tty-session-eval s '(drgnx-tty--read-report)) :hinted)))
      (should-not (drgnx-tty-session-eval s `(with-current-buffer "*Messages*" (string-search ,hint (buffer-string)))))
      (should-not (string-search "can't send Ctrl+Shift" (drgnx-tty-session-screen s))))))

(ert-deftest drgnx-kitty/emacsclient-t-handles-c-s-chords ()
  ;; the VS Code keys, each sent by kitty's own encoder.  28 lines: the layout (ui/terminal-layout) shows the panel
  ;; from 30 lines, and ctrl+` below opens it
  (drgnx-tty-kitty-test--with (s :kkp t :size "120x28")
    (drgnx-tty-kitty-test--kkp-on s)
    (drgnx-tty-session-eval s drgnx-tty-keys-test--record)
    ;; ctrl+shift+p: the palette's prompt
    (drgnx-tty-session-kitty-key s "ctrl+shift+p")
    (drgnx-tty-keys-test--ran s 'drgnx-palette "C-S-p")
    (drgnx-tty-session-wait-screen s "Command (# for a code question)")
    (drgnx-tty-kitty-test--quit s)
    ;; ctrl+shift+f: Search in Project
    (drgnx-tty-session-kitty-key s "ctrl+shift+f")
    (drgnx-tty-keys-test--ran s 'drgnx-wb-view-search "C-S-f")
    (drgnx-tty-session-wait-screen s "SEARCH")
    (drgnx-tty-kitty-test--quit s)
    ;; ctrl+shift+e: the Explorer is selected
    (drgnx-tty-session-kitty-key s "ctrl+shift+e")
    (drgnx-tty-keys-test--ran s 'drgnx-wb-view-explorer "C-S-e")
    (drgnx-tty-session-wait s `(with-current-buffer (window-buffer (frame-selected-window ,drgnx-tty-kitty-test--frame))
                                 (derived-mode-p 'drgnx-explorer-mode)))
    ;; ctrl+`: the panel, its tab row with the Terminal tab
    (should-not (drgnx-tty-session-eval s `(drgnx-wb-area-window 'panel ,drgnx-tty-kitty-test--frame)))
    (drgnx-tty-session-kitty-key s "ctrl+`")
    (drgnx-tty-keys-test--ran s 'drgnx-wb-toggle-panel "C-`")
    (drgnx-tty-session-wait s `(drgnx-wb-area-window 'panel ,drgnx-tty-kitty-test--frame))
    (drgnx-tty-session-wait-screen s "Problems +Output +Results +Terminal" 10)
    ;; ctrl+.: the code actions (Quick Fix)
    (drgnx-tty-session-kitty-key s "ctrl+.")
    (drgnx-tty-keys-test--ran s 'drgnx-lang-quick-fix "C-.")))

(ert-deftest drgnx-kitty/c-g-interrupts-a-blocking-call ()
  ;; under kkp C-g is an escape sequence; around a program Emacs waits for, kitty sends the plain byte again
  (drgnx-tty-kitty-test--with (s :kkp t)
    (drgnx-tty-kitty-test--kkp-on s)
    (let ((started (expand-file-name "block-started" (plist-get s :run))))
      (drgnx-tty-session-eval
       s `(progn
            (defvar kx-returned nil)
            (defun kx-block ()
              (interactive)
              (write-region "" nil ,started nil 'silent)
              (unwind-protect (call-process "sleep" nil nil nil "30")
                (setq kx-returned (float-time))))
            (push (list (cons t (let ((m (make-sparse-keymap))) (define-key m [f12] #'kx-block) m)))
                  emulation-mode-map-alists)
            t))
      (drgnx-tty-session-kitty-key s "f12")
      (let ((deadline (+ (float-time) 10)))
        (while (and (not (file-exists-p started)) (< (float-time) deadline)) (sleep-for 0.05)))
      (should (file-exists-p started))
      ;; kkp gives kitty its plain keys back as the program starts
      (sleep-for 0.5)
      (let ((sent (float-time)))
        (drgnx-tty-session-kitty-key s "ctrl+g")
        (should (< (- (drgnx-tty-session-wait s 'kx-returned 10) sent) 2)))
      ;; and the chords are back afterwards
      (drgnx-tty-kitty-test--kkp-on s)
      (drgnx-tty-session-eval s drgnx-tty-keys-test--record)
      (drgnx-tty-session-kitty-key s "ctrl+shift+p")
      (drgnx-tty-keys-test--ran s 'drgnx-palette "C-S-p")
      (drgnx-tty-kitty-test--quit s))))

;;;; The mouse

(defun drgnx-tty-kitty-test--project (s)
  "The fixture project (a.txt, b.txt of 300 lines) in the Explorer of kitty's frame and a.txt in its editor, on the
screen.  Returns its directory."
  (let ((dir (expand-file-name "project" (plist-get s :run))))
    (make-directory dir t)
    (with-temp-file (expand-file-name "a.txt" dir) (insert "alpha beta gamma\n"))
    (with-temp-file (expand-file-name "b.txt" dir) (dotimes (i 300) (insert (format "line %d\n" (1+ i)))))
    (drgnx-tty-kitty-test--in s `(progn (drgnx-explorer-set-roots (list ,dir))
                                        (drgnx-wb-show-sidebar)
                                        (drgnx-wb-show-in-editor (find-file-noselect ,(expand-file-name "a.txt" dir)) t)
                                        t))
    (drgnx-tty-session-wait-screen s "EXPLORER")
    (drgnx-tty-session-wait-screen s "alpha beta gamma")
    (drgnx-tty-session-wait-screen s "b\\.txt")
    dir))

(defconst drgnx-tty-kitty-test--editor-buffer
  `(with-selected-frame ,drgnx-tty-kitty-test--frame (buffer-name (window-buffer (drgnx-wb-editor-window))))
  "A form, in the daemon: the name of the buffer in kitty's editor window.")

(ert-deftest drgnx-kitty/emacsclient-t-handles-the-mouse ()
  (drgnx-tty-kitty-test--with (s)
    (drgnx-tty-kitty-test--project s)
    ;; a click on the Explorer's b.txt row opens it
    (let ((row (drgnx-tty-session-wait-screen s "^  b\\.txt")))
      (drgnx-tty-session-kitty-text s (drgnx-tty-session--click-bytes (car row) (cdr row))))
    (drgnx-tty-session-wait s `(equal ,drgnx-tty-kitty-test--editor-buffer "b.txt"))
    (drgnx-tty-session-wait-screen s "line 3\\b")
    ;; the wheel over it scrolls it
    (let ((start `(with-selected-frame ,drgnx-tty-kitty-test--frame
                    (with-selected-window (drgnx-wb-editor-window) (line-number-at-pos (window-start)))))
          (pos (drgnx-tty-session-find s "line 3\\b")))
      (should (= (drgnx-tty-session-eval s start) 1))
      (drgnx-tty-session-kitty-text s (drgnx-tty-session--wheel-bytes (car pos) (cdr pos) 'down))
      (should (> (drgnx-tty-session-wait s `(let ((n ,start)) (and (> n 1) n))) 1)))))

;;;; Copy, colours

(ert-deftest drgnx-kitty/copy-reaches-the-clipboard ()
  ;; the VS Code profile end to end: Shift+Right five times, Ctrl+C; kitty puts the OSC 52 copy on the clipboard
  (drgnx-tty-kitty-test--with (s)
    (drgnx-tty-kitty-test--in s '(progn (switch-to-buffer (get-buffer-create "*copy*"))
                                        (insert "hello drgnx")
                                        (goto-char (point-min))
                                        t))
    (dotimes (_ 5) (drgnx-tty-session-kitty-key s "shift+right"))
    (drgnx-tty-session-wait s '(with-current-buffer "*copy*" (and (use-region-p) (= (- (region-end) (region-beginning)) 5))))
    (drgnx-tty-session-kitty-key s "ctrl+c")
    (drgnx-tty-session-wait s '(equal (car kill-ring) "hello"))
    (let ((deadline (+ (float-time) 5)))
      (while (and (not (equal (drgnx-tty-session-kitty-clipboard s) "hello")) (< (float-time) deadline))
        (sleep-for 0.1)))
    (should (equal (drgnx-tty-session-kitty-clipboard s) "hello"))))

(ert-deftest drgnx-kitty/true-colour ()
  (drgnx-tty-kitty-test--with (s)
    (should (= (drgnx-tty-session-eval s `(display-color-cells ,drgnx-tty-kitty-test--frame)) 16777216))))

(provide 'kitty-test)
;;; kitty-test.el ends here
