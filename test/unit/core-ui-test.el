;;; core-ui-test.el --- batch tests: the UI kit in core — glyphs by meaning, status faces, buttons -*- lexical-binding: t -*-
;; The batch terminal is not UTF-8, so each test says which kind of frame it draws on.
(require 'ert)
(require 'cl-lib)
(require 'drgnx-ui-kit)
(require 'drgnx-surfaces)
(require 'drgnx-modules)
(require 'drgnx-onboard)

(defmacro drgnx-ui-test--unicode (&rest body)
  "BODY on a frame that writes UTF-8."
  `(cl-letf (((symbol-function 'drgnx-ui-ascii-frame-p) (lambda (&optional _f) nil))) ,@body))

(defmacro drgnx-ui-test--ascii (&rest body)
  "BODY on a terminal frame that does not write UTF-8."
  `(cl-letf (((symbol-function 'drgnx-ui-ascii-frame-p) (lambda (&optional _f) t))) ,@body))

(ert-deftest drgnx-ui-kit/face-glyph-is-core-and-always-defined ()
  ;; ui/face is a module, not part of core: nothing here loads it
  (should (fboundp 'drgnx-face-glyph))
  (should (boundp 'drgnx-face-glyphs))
  (should-not (featurep 'drgnx-face))
  (drgnx-ui-test--unicode (should (equal (drgnx-face-glyph 'close) "×")))
  (should-not (drgnx-face-glyph 'no-such-glyph)))

(ert-deftest drgnx-ui-kit/meanings-are-separate ()
  (dolist (n '(fail stopped dismiss unqueue info warn))
    (let ((g (alist-get n (default-value 'drgnx-face-glyphs))))
      (should (and (stringp (car g)) (stringp (cdr g))))
      (should (string-match-p "\\`[[:ascii:]]+\\'" (cdr g)))))
  (let ((drgnx-face-glyphs (cons '(close "C" . "c") drgnx-face-glyphs)))
    (drgnx-ui-test--unicode
     (should (equal (drgnx-face-glyph 'close) "C"))
     (should (equal (drgnx-face-glyph 'fail) "✕"))
     (should (equal (drgnx-face-glyph 'dismiss) "×")))))

(ert-deftest drgnx-ui-kit/ascii-glyphs-on-a-non-utf8-terminal ()
  (let ((tty (make-symbol "tty")))
    (cl-letf (((symbol-function 'display-graphic-p) (lambda (&optional f) (not (eq f tty))))
              ((symbol-function 'frame-terminal) (lambda (&optional _f) 'term))
              ((symbol-function 'terminal-coding-system) (lambda (&optional _t) 'iso-latin-1)))
      (should (drgnx-ui-ascii-frame-p tty))
      (should-not (drgnx-ui-ascii-frame-p 'gui))
      (should (equal (drgnx-face-glyph 'fail tty) "X"))
      (should (equal (drgnx-face-glyph 'fail 'gui) "✕")))
    (cl-letf (((symbol-function 'display-graphic-p) (lambda (&optional _f) nil))
              ((symbol-function 'frame-terminal) (lambda (&optional _f) 'term))
              ((symbol-function 'terminal-coding-system) (lambda (&optional _t) 'utf-8-unix)))
      (should-not (drgnx-ui-ascii-frame-p tty))
      (should (equal (drgnx-face-glyph 'fail tty) "✕")))))

(ert-deftest drgnx-ui-kit/tty-popups-ascii-is-the-same-test ()
  (load (expand-file-name "modules/ui/drgnx-tty-popups" drgnx-dir) nil t)
  (should (eq (indirect-function 'drgnx-tty-popups-ascii-p) (indirect-function 'drgnx-ui-ascii-frame-p))))

(ert-deftest drgnx-ui-kit/status-faces-inherit ()
  (pcase-dolist (`(,face . ,parent) '((drgnx-status-ok . success) (drgnx-status-info . shadow) (drgnx-status-warn . warning)
                                      (drgnx-status-fail . error) (drgnx-status-needs-you . error)))
    (should (facep face))
    (should (equal (face-attribute face :inherit nil nil) parent))
    (should-not (cl-some (lambda (a) (stringp (face-attribute face a nil nil))) '(:foreground :background)))))

(ert-deftest drgnx-ui-kit/status-gives-glyph-and-text-in-its-face ()
  (drgnx-ui-test--unicode
   (pcase-dolist (`(,sev ,glyph ,face) '((ok "✓" drgnx-status-ok) (info "ℹ" drgnx-status-info) (warn "⚠" drgnx-status-warn)
                                         (fail "✕" drgnx-status-fail) (needs-you "◐" drgnx-status-needs-you)))
     (let ((s (drgnx-ui-status sev "text")))
       (should (equal (substring-no-properties s) (concat glyph " text")))
       (should (eq (get-text-property 0 'face s) face))
       (should (eq (get-text-property (1- (length s)) 'face s) face)))
     (should (equal (substring-no-properties (drgnx-ui-status sev)) glyph)))))

(ert-deftest drgnx-ui-kit/a-saved-glyph-option-still-applies ()
  ;; the option keeps its name: a value saved by customize before the move (the old 18 entries, with ok and
  ;; waiting restyled, and no fail, stopped, dismiss, unqueue, info or warn) is read by the kit; a name it lacks
  ;; falls back to the default entry
  (let ((drgnx-face-glyphs
         '((handle "⠿" . "::") (close "×" . "x") (branch "⑂" . "Y") (warning "⚠" . "!") (ok "OK" . "ok")
           (busy "◎" . "@") (waiting "W" . "w") (paused "⏸" . "||") (ahead "↑" . "^") (behind "↓" . "v")
           (dot "●" . "*") (circle "○" . "o") (sep " · " . " | ") (flag "⚑" . "#")
           (diamond "◆" . "<>") (search "⌕" . "/") (minimize "–" . "-") (maximize "▢" . "[]"))))
    (should (= (length drgnx-face-glyphs) 18))
    (drgnx-ui-test--unicode
     (should (equal (substring-no-properties (drgnx-ui-status 'ok "fine")) "OK fine"))
     (should (equal (substring-no-properties (drgnx-ui-status 'needs-you)) "W"))
     (should (equal (substring-no-properties (drgnx-ui-status 'fail "failed: x")) "✕ failed: x"))
     (should (equal (substring-no-properties (drgnx-ui-status 'info)) "ℹ"))
     (should (equal (drgnx-face-glyph 'dismiss) "×"))
     (should (equal (drgnx-face-glyph 'bullet) "•")))
    (drgnx-ui-test--ascii
     (should (equal (substring-no-properties (drgnx-ui-status 'ok "fine")) "ok fine"))
     (should (equal (substring-no-properties (drgnx-ui-status 'fail "bad")) "X bad"))
     (should (equal (substring-no-properties (drgnx-ui-status 'warn)) "!")))
    (should-not (drgnx-face-glyph 'no-such-glyph))))

(ert-deftest drgnx-modules/list-statuses-use-the-kit ()
  (let ((drgnx-modules--table '((t/a :stage load) (t/b :stage load) (t/c :stage load) (t/d :stage load)
                                (t/e :stage load)))
        (drgnx-modules--report '((t/a :status ok) (t/b :status failed :error "kaputt") (t/c :status missing-packages :missing (magit))
                                 (t/e :status off))))
    (let ((st (lambda (n) (aref (cadr (assq n (drgnx-modules--entries))) 1))))
      (drgnx-ui-test--unicode
       (should (equal (substring-no-properties (funcall st 't/a)) "✓ ok"))
       (should (eq (get-text-property 0 'face (funcall st 't/a)) 'drgnx-status-ok))
       (should (equal (substring-no-properties (funcall st 't/b)) "✕ failed: kaputt"))
       (should (eq (get-text-property 0 'face (funcall st 't/b)) 'drgnx-status-fail))
       (should (equal (substring-no-properties (funcall st 't/c)) "⚠ needs magit"))
       (should (eq (get-text-property 0 'face (funcall st 't/c)) 'drgnx-status-warn))
       (should (equal (funcall st 't/d) "not run yet"))
       (should (equal (substring-no-properties (funcall st 't/e)) "ℹ off"))       ; turned off in this session
       (should (eq (get-text-property 0 'face (funcall st 't/e)) 'drgnx-status-info)))
      (drgnx-ui-test--ascii
       (should (equal (substring-no-properties (funcall st 't/b)) "X failed: kaputt"))))))

(ert-deftest drgnx-onboard/steps-use-the-kit ()
  (let ((drgnx-onboard--steps '((a :title "A" :order 1) (b :title "B" :order 2) (c :title "C" :order 3) (d :title "D" :order 4)))
        (drgnx-onboard--progress nil))
    (cl-letf (((symbol-function 'drgnx-onboard-state)
               (lambda () '((a :status ok :message "m") (b :status fail :message "m") (c :status info :message "m"))))
              ((symbol-function 'drgnx-onboard--next-button) (lambda (&rest _) nil)))
      (let ((st (lambda (id) (aref (cadr (assq id (drgnx-onboard--entries))) 1))))
        (drgnx-ui-test--unicode
         (should (equal (substring-no-properties (funcall st 'a)) "✓ ok"))
         (should (eq (get-text-property 0 'face (funcall st 'a)) 'drgnx-status-ok))
         (should (equal (substring-no-properties (funcall st 'b)) "✕ fail"))
         (should (eq (get-text-property 0 'face (funcall st 'b)) 'drgnx-status-fail))
         (should (equal (substring-no-properties (funcall st 'c)) "ℹ info"))
         (should (equal (funcall st 'd) "—")))
        (drgnx-ui-test--ascii
         (should (equal (substring-no-properties (funcall st 'b)) "X fail")))))))

;;;; Buttons and the close button

(defvar drgnx-ui-kit-test--ran nil "What the test commands saw, newest first.")

(defun drgnx-ui-kit-test--cmd (&optional n)
  "Record N: 1 when called interactively, nil when funcalled."
  (interactive "p")
  (push n drgnx-ui-kit-test--ran))

(defun drgnx-ui-kit-test--close (event)
  "A close command: it takes the click EVENT."
  (interactive "e")
  (push event drgnx-ui-kit-test--ran))

(defmacro drgnx-ui-kit-test--with-registry (&rest body)
  "BODY with a command table holding only `kit-cmd', no usage counter, and nothing run yet."
  `(let ((drgnx-commands--table (make-hash-table :test #'eq)) (drgnx-commands--order nil)
         (drgnx-surfaces-run-functions nil) (drgnx-ui-kit-test--ran nil))
     (drgnx-command-define 'kit-cmd :title "Kit" :category "Test" :command #'drgnx-ui-kit-test--cmd)
     ,@body))

(defun drgnx-ui-kit-test--press (button key &optional where)
  "Run what KEY is bound to in BUTTON's keymap (its `keymap' in text, its `local-map' on WHERE's line)."
  (call-interactively (lookup-key (get-text-property 0 (if where 'local-map 'keymap) button) key)))

(ert-deftest drgnx-ui-kit/button-runs-a-registry-command-and-counts-usage ()
  (drgnx-ui-kit-test--with-registry
   (let* ((seen nil) (drgnx-surfaces-run-functions (list (lambda (id) (push id seen))))
          (b (drgnx-ui-button "Go" 'kit-cmd :help "Run it")))
     (should (equal (substring-no-properties b) "Go"))
     (should (eq (get-text-property 0 'face b) 'drgnx-ui-button))
     (should (equal (get-text-property 0 'help-echo b) "Run it"))
     (should (eq (get-text-property 0 'mouse-face b) 'highlight))
     (should (get-text-property 0 'follow-link b))
     (drgnx-ui-kit-test--press b (kbd "RET"))
     (drgnx-ui-kit-test--press b [mouse-1])
     ;; run as typed (interactively), through `drgnx-surfaces-run': the run hook (the usage count) sees the id
     (should (equal drgnx-ui-kit-test--ran '(1 1)))
     (should (equal seen '(kit-cmd kit-cmd))))
   (should (equal (face-attribute 'drgnx-ui-button :inherit nil nil) 'button))))

(ert-deftest drgnx-ui-kit/button-runs-a-command-or-a-function ()
  (drgnx-ui-kit-test--with-registry
   (let* ((seen nil) (drgnx-surfaces-run-functions (list (lambda (id) (push id seen)))) (calls nil))
     ;; a command the registry does not know: called interactively, nothing counted
     (drgnx-ui-kit-test--press (drgnx-ui-button "C" #'drgnx-ui-kit-test--cmd) (kbd "RET"))
     (should (equal drgnx-ui-kit-test--ran '(1)))
     ;; a function of no arguments, with its own face and more properties
     (let ((b (drgnx-ui-button "F" (lambda () (push 'fn calls)) :face 'bold :props '(drgnx-ui-kit-test 7))))
       (should (eq (get-text-property 0 'face b) 'bold))
       (should (eq (get-text-property 0 'drgnx-ui-kit-test b) 7))
       (drgnx-ui-kit-test--press b [mouse-1]))
     (should (equal calls '(fn)))
     (should-not seen))))

(ert-deftest drgnx-ui-kit/button-where-header-mode-tab-line ()
  (drgnx-ui-kit-test--with-registry
   (dolist (where '(header-line mode-line tab-line))
     (let ((b (drgnx-ui-button "W" 'kit-cmd :where where)))
       (should-not (get-text-property 0 'keymap b))
       (drgnx-ui-kit-test--press b (vector where 'mouse-1) where)
       ;; one keymap per (ACTION . WHERE): drawing the button again builds nothing
       (should (eq (get-text-property 0 'local-map b)
                   (get-text-property 0 'local-map (drgnx-ui-button "Again" 'kit-cmd :where where))))))
   (should (equal drgnx-ui-kit-test--ran '(1 1 1)))
   (should-not (eq (get-text-property 0 'local-map (drgnx-ui-button "W" 'kit-cmd :where 'mode-line))
                   (get-text-property 0 'local-map (drgnx-ui-button "W" 'kit-cmd :where 'header-line))))))

(ert-deftest drgnx-ui-kit/insert-button ()
  (drgnx-ui-kit-test--with-registry
   (with-temp-buffer
     (insert "a ")
     (drgnx-ui-insert-button "Go" 'kit-cmd :help "Run it")
     (should (equal (buffer-string) "a Go"))
     (should (equal (get-text-property 3 'help-echo) "Run it"))
     (goto-char 3)
     (call-interactively (key-binding (kbd "RET")))
     (should (equal drgnx-ui-kit-test--ran '(1))))))

(ert-deftest drgnx-ui-kit/close-button-is-cached-per-command-and-where ()
  (drgnx-ui-test--unicode
   (let ((a (drgnx-ui-close-button #'drgnx-ui-kit-test--close "Close it" :props '(drgnx-ui-kit-test 1)))
         (b (drgnx-ui-close-button #'drgnx-ui-kit-test--close "Close too"))
         (c (drgnx-ui-close-button #'drgnx-ui-kit-test--close "Close" :where 'tab-line)))
     (should (equal (substring-no-properties a) "×"))
     (should (eq (get-text-property 0 'face a) 'drgnx-ui-close))
     (should (equal (get-text-property 0 'help-echo a) "Close it"))
     (should (eq (get-text-property 0 'mouse-face a) 'highlight))
     (should (eq (get-text-property 0 'drgnx-ui-kit-test a) 1))
     ;; the click runs COMMAND itself, so it gets the event
     (should (eq (lookup-key (get-text-property 0 'local-map a) [header-line mouse-1]) #'drgnx-ui-kit-test--close))
     (should (eq (get-text-property 0 'local-map a) (get-text-property 0 'local-map b)))
     (should (eq (lookup-key (get-text-property 0 'local-map c) [tab-line mouse-1]) #'drgnx-ui-kit-test--close))
     (should-not (eq (get-text-property 0 'local-map a) (get-text-property 0 'local-map c)))))
  (drgnx-ui-test--ascii
   (should (equal (substring-no-properties (drgnx-ui-close-button #'drgnx-ui-kit-test--close "Close")) "x")))
  (should (equal (face-attribute 'drgnx-ui-close :inherit nil nil) 'shadow)))

(ert-deftest drgnx-ui-kit/wb-close-button-is-a-wrapper ()
  (require 'drgnx-wb)
  (drgnx-ui-test--unicode
   (should (equal (drgnx-wb-close-glyph) "×"))
   (let ((w (drgnx-wb-close-button #'drgnx-ui-kit-test--close "Close" 'drgnx-ui-kit-test 'panel))
         (k (drgnx-ui-close-button #'drgnx-ui-kit-test--close "Close")))
     (should (equal (substring-no-properties w) "×"))
     (should (eq (get-text-property 0 'local-map w) (get-text-property 0 'local-map k)))
     (should (eq (get-text-property 0 'face w) 'drgnx-ui-close))
     (should (eq (get-text-property 0 'drgnx-ui-kit-test w) 'panel))))
  (drgnx-ui-test--ascii (should (equal (drgnx-wb-close-glyph) "x")))
  ;; the workbench's close face is the kit's: restyling either restyles the button
  (should (eq (get 'drgnx-wb-close 'face-alias) 'drgnx-ui-close)))

(ert-deftest drgnx-ui-kit/the-three-close-marks-have-an-ascii-form ()
  ;; M12f-AF-1: the Buffers row's close, the find bar's close and the agents queue's unqueue were a literal ×
  (require 'drgnx-buffers)
  (load (expand-file-name "modules/tools/drgnx-replace" drgnx-dir) nil t)
  (load (expand-file-name "modules/tools/drgnx-agents-ui" drgnx-dir) nil t)
  (let ((queue (lambda ()
                 (with-temp-buffer
                   (drgnx-agents-ui-render (drgnx-agents--make :name "q" :status 'busy :queue '("one") :paused nil))
                   (buffer-string))))
        (bar (lambda ()
               (unwind-protect
                   (with-current-buffer (drgnx-replace--bar-buffer)
                     (buffer-substring-no-properties (point-min) (pos-eol)))
                 (when (get-buffer drgnx-replace-bar-buffer-name) (kill-buffer drgnx-replace-bar-buffer-name))))))
    (drgnx-ui-test--ascii
     (with-temp-buffer (should (string-prefix-p "x " (drgnx-buffers--row (current-buffer)))))
     (should (string-search "[↓] [x]" (funcall bar)))
     (should (string-search "one [-]" (funcall queue))))
    (drgnx-ui-test--unicode
     (with-temp-buffer (should (string-prefix-p "× " (drgnx-buffers--row (current-buffer)))))
     (should (string-search "[↓] [×]" (funcall bar)))
     (should (string-search "one [−]" (funcall queue))))))
