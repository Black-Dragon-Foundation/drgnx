;;; tty-sheet-test.el --- batch tests: the shared surfaces show keys as this terminal can send them -*- lexical-binding: t -*-
;; Batch Emacs has no terminal: the selected frame's terminal and its parameters are stubbed (the caps drgnx
;; found, and for a legacy one the fallback table the layer would hold).  The layer itself is tested in
;; tty-fallback-test.el and test/tty/fallback-test.el.
(require 'ert)
(require 'drgnx-palette)
(require 'drgnx-tty-fallback)

(defconst tty-sheet-test--keys '("C-S-p" "C-S-f" "C-c a" "C-k C-S-f") "The keys of the test commands: the profile's keys.")

(defconst tty-sheet-test--legacy '(:id vte :keys legacy :folded nil :colors 256) "A VTE's caps.")
(defconst tty-sheet-test--kkp '(:id kitty :keys kkp :folded nil :colors 256) "A kitty's caps.")

(defun tty-sheet-test--noop () (interactive) nil)

(defmacro tty-sheet-test--on (caps &rest body)
  "BODY with three commands (palette on C-S-p, search on C-S-f, plain on C-c a) and the selected frame a terminal
frame with CAPS; for legacy CAPS the terminal holds the fallback table of the three keys (`drgnx-tty-fallback' on).
CAPS nil is a graphical frame."
  (declare (indent 1))
  `(let ((drgnx-commands--table (make-hash-table :test #'eq)) (drgnx-commands--order nil)
         (drgnx-surfaces-contexts nil)
         (params (make-hash-table :test #'equal)) (caps ,caps)
         (drgnx-tty-fallback t) (drgnx-tty-chord-prefix "<f6>"))
     (drgnx-command-define 'palette :title "Command Palette" :category "Commands" :command #'tty-sheet-test--noop)
     (drgnx-command-define 'search :title "Search in Project" :category "Search" :command #'tty-sheet-test--noop)
     (drgnx-command-define 'plain :title "Plain" :category "Search" :command #'tty-sheet-test--noop)
     (drgnx-command-define 'chain :title "Chain" :category "Search" :command #'tty-sheet-test--noop)
     (pcase-dolist (`(,id . ,key) '((palette . "C-S-p") (search . "C-S-f") (plain . "C-c a") (chain . "C-k C-S-f")))
       (setf (drgnx-cmd-bound (drgnx-commands-get id)) (list (cons key nil))))
     (when caps
       (puthash '(kx-sheet . drgnx-tty-caps) caps params)
       (when (eq (plist-get caps :keys) 'legacy)
         (puthash '(kx-sheet . drgnx-tty-fallback-table)
                  (drgnx-tty-fallback-for-terminal
                   (drgnx-tty-fallback-table tty-sheet-test--keys :global global-map :profile tty-sheet-test--keys
                                             :prefix "<f6>")
                   caps)
                  params)))
     (cl-letf (((symbol-function 'frame-terminal) (lambda (&optional _) 'kx-sheet))
               ((symbol-function 'display-graphic-p) (lambda (&optional _) (null caps)))
               ((symbol-function 'terminal-parameter) (lambda (term p) (gethash (cons term p) params)))
               ((symbol-function 'set-terminal-parameter) (lambda (term p v) (puthash (cons term p) v params))))
       ,@body)))

(defun tty-sheet-test--key (id) (drgnx-surfaces-key (drgnx-commands-get id)))

(defun tty-sheet-test--sheet ()
  "The key sheet's text."
  (drgnx-surfaces-cheatsheet)
  (prog1 (with-current-buffer "*drgnx keys*" (buffer-string))
    (kill-buffer "*drgnx keys*")))

(defconst tty-sheet-test--heading "Keys this terminal cannot send, and what to press here")

(defun tty-sheet-test--line (text pattern)
  "The first line of TEXT matching PATTERN, or nil."
  (seq-find (lambda (l) (string-match-p pattern l)) (split-string text "\n")))

(ert-deftest drgnx-surfaces/the-sheet-lists-keys-this-terminal-cannot-send ()
  ;; a legacy terminal: C-S-p has no Alt+Shift key (ESC P starts a terminal's reply), only F6 then p
  (tty-sheet-test--on tty-sheet-test--legacy
    (let ((sheet (tty-sheet-test--sheet)))
      (should (string-search tty-sheet-test--heading sheet))
      (let ((p (tty-sheet-test--line (substring sheet (string-search tty-sheet-test--heading sheet)) "C-S-p"))
            (f (tty-sheet-test--line (substring sheet (string-search tty-sheet-test--heading sheet)) "C-S-f")))
        (should (string-match-p "Command Palette" p))
        (should (string-match-p "F6 p" p))
        (should-not (string-search "Alt+Shift" p))
        (should (string-search "Alt+Shift+F" f))
        (should (string-match-p "F6 f" f)))
      ;; a key the terminal sends is not in the section
      (should-not (tty-sheet-test--line (substring sheet (string-search tty-sheet-test--heading sheet)) "C-c a"))))
  ;; kkp, and a graphical frame: no section
  (tty-sheet-test--on tty-sheet-test--kkp
    (should-not (string-search tty-sheet-test--heading (tty-sheet-test--sheet))))
  (tty-sheet-test--on nil
    (should-not (string-search tty-sheet-test--heading (tty-sheet-test--sheet)))))

(ert-deftest drgnx-surfaces/the-sheet-shows-what-to-type-for-a-chord-sequence ()
  ;; a sequence with a chord a legacy terminal cannot send is typed with that chord mapped, not "cannot send"
  (tty-sheet-test--on tty-sheet-test--legacy
    (let* ((sheet (tty-sheet-test--sheet))
           (section (substring sheet (string-search tty-sheet-test--heading sheet)))
           (line (tty-sheet-test--line section "C-k C-S-f")))
      (should line)
      (should (string-search "Ctrl+K Alt+Shift+F" line))
      (should (string-search "Ctrl+K F6 f" line))
      (should-not (string-search "cannot send" line)))
    ;; where Alt+Shift+F is bound by the buffer's mode, the F6 form is the one given
    (with-temp-buffer
      (use-local-map (let ((m (make-sparse-keymap))) (define-key m (key-parse "M-F") #'ignore) m))
      (let* ((sheet (tty-sheet-test--sheet))
             (line (tty-sheet-test--line (substring sheet (string-search tty-sheet-test--heading sheet)) "C-k C-S-f")))
        (should (string-search "Ctrl+K F6 f" line))
        (should-not (string-search "cannot send" line))))))

(ert-deftest drgnx-surfaces/menus-show-the-key-that-is-right-in-every-buffer ()
  ;; the menu bar keeps its text while the buffer changes: the F6 form, never an Alt+Shift key a mode may rebind
  (tty-sheet-test--on tty-sheet-test--legacy
    (let ((cmd (drgnx-commands-get 'search)))
      (should (equal (drgnx-surfaces-key cmd) "M-F"))
      (should (equal (drgnx-surfaces-key cmd 'menu) "<f6> f"))
      (with-temp-buffer
        (use-local-map (let ((m (make-sparse-keymap))) (define-key m (key-parse "M-F") #'ignore) m))
        (should (equal (drgnx-surfaces-key cmd 'menu) "<f6> f")))
      (should (equal (drgnx-surfaces-key (drgnx-commands-get 'plain) 'menu) "C-c a"))
      (should (equal (drgnx-surfaces-key (drgnx-commands-get 'chain) 'menu) "C-k <f6> f"))))
  (tty-sheet-test--on tty-sheet-test--kkp
    (should (equal (drgnx-surfaces-key (drgnx-commands-get 'search) 'menu) "C-S-f")))
  (tty-sheet-test--on nil
    (should (equal (drgnx-surfaces-key (drgnx-commands-get 'search) 'menu) "C-S-f"))))

(ert-deftest drgnx-surfaces/the-sheet-says-so-when-the-layer-is-off ()
  (tty-sheet-test--on tty-sheet-test--legacy
    (let ((drgnx-tty-fallback nil))
      (let* ((sheet (tty-sheet-test--sheet)) (section (substring sheet (string-search tty-sheet-test--heading sheet))))
        (should (string-match-p "C-S-p.*cannot send it" (tty-sheet-test--line section "C-S-p")))
        (should-not (string-search "F6" section))))))

(ert-deftest drgnx-surfaces/the-sheet-rows-show-the-key-this-terminal-sends ()
  (tty-sheet-test--on tty-sheet-test--legacy
    (let ((sheet (tty-sheet-test--sheet)))
      (should (string-match-p "<f6> p +Command Palette" sheet))
      (should (string-match-p "M-F +Search in Project" sheet))
      (should (string-match-p "C-c a +Plain" sheet))))
  (tty-sheet-test--on nil
    (should (string-match-p "C-S-p +Command Palette" (tty-sheet-test--sheet)))))

(ert-deftest drgnx-surfaces/the-key-follows-the-selected-frame ()
  (tty-sheet-test--on tty-sheet-test--legacy
    (should (equal (tty-sheet-test--key 'palette) "<f6> p"))
    (should (equal (tty-sheet-test--key 'search) "M-F"))
    (should (equal (tty-sheet-test--key 'plain) "C-c a")))
  (tty-sheet-test--on tty-sheet-test--kkp
    (should (equal (tty-sheet-test--key 'palette) "C-S-p")))
  (tty-sheet-test--on nil
    (should (equal (tty-sheet-test--key 'palette) "C-S-p"))))

(defun tty-sheet-test--palette-annotation (label)
  "The palette's annotation for LABEL, asked the way a completion UI asks: from the minibuffer's buffer."
  (let (note)
    (cl-letf (((symbol-function 'completing-read)
               (lambda (_prompt table &rest _)
                 (setq note (with-temp-buffer
                              (funcall (completion-metadata-get (completion-metadata "" table nil) 'annotation-function) label)))
                 "")))
      (drgnx-palette))
    note))

(ert-deftest drgnx-surfaces/the-palette-shows-the-key-this-terminal-can-send ()
  (tty-sheet-test--on tty-sheet-test--legacy
    (should (string-match-p "<f6> p" (tty-sheet-test--palette-annotation "Commands: Command Palette")))
    (should (string-match-p "M-F" (tty-sheet-test--palette-annotation "Search: Search in Project")))
    ;; in a buffer whose mode binds Alt+Shift+F: the command is asked from there, so it is F6 then f
    (with-temp-buffer
      (use-local-map (let ((m (make-sparse-keymap))) (define-key m (key-parse "M-F") #'ignore) m))
      (should (string-match-p "<f6> f" (tty-sheet-test--palette-annotation "Search: Search in Project")))))
  (tty-sheet-test--on nil
    (should (string-match-p "C-S-p" (tty-sheet-test--palette-annotation "Commands: Command Palette")))))

(ert-deftest drgnx-surfaces/menus-follow-the-terminal-they-are-shown-on ()
  ;; the menu bar is global: its :keys texts are rebuilt when the selected frame's terminal is another one
  (tty-sheet-test--on tty-sheet-test--legacy
    (let ((drgnx-surfaces--menu-signature nil) (built nil))
      (cl-letf (((symbol-function 'drgnx-surfaces-build-menus) (lambda () (push (tty-sheet-test--key 'palette) built))))
        (drgnx-surfaces--update-menus)
        (drgnx-surfaces--update-menus)             ; same terminal, same state: nothing to do
        (should (equal built '("<f6> p")))
        (set-terminal-parameter 'kx-sheet 'drgnx-tty-caps tty-sheet-test--kkp)   ; kkp came on
        (set-terminal-parameter 'kx-sheet 'drgnx-tty-fallback-table nil)
        (drgnx-surfaces--update-menus)
        (should (equal built '("C-S-p" "<f6> p")))))))

(provide 'tty-sheet-test)
;;; tty-sheet-test.el ends here
