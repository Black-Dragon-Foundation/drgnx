;;; mod-tty-clipboard-test.el --- batch tests: ui/terminal — copy to the local clipboard through OSC 52 -*- lexical-binding: t -*-
;; Batch Emacs has no terminal: the terminal, its parameters and its identity are stubbed (as in
;; mod-tty-frames-test.el); the too-long copy runs the real xterm.el method on the batch terminal.  The tty tier
;; (test/tty/clipboard-test.el) runs the real thing in tmux.
(require 'ert)
(require 'drgnx)
(load (expand-file-name "modules/ui/drgnx-tty-frames" drgnx-dir) nil t)
(load (expand-file-name "modules/ui/drgnx-tty-clipboard" drgnx-dir) nil t)

(defvar drgnx-tty-clip-test--tmux nil
  "What the fake tmux of these tests says (`drgnx-tty-frames--tmux-options'): nil is a tmux that cannot be asked.")

(defmacro drgnx-tty-clip-test--terminal (id params &rest body)
  "BODY with a fake terminal kx-a of kind ID (a symbol of `drgnx-tty-terminals') holding PARAMS (an alist);
`reports' counts the terminal-report rewrites.  tmux's options are `drgnx-tty-clip-test--tmux', never a
real tmux (this Emacs may be inside the user's)."
  (declare (indent 2))
  `(let ((table (make-hash-table :test #'equal))
         (reports 0))
     (pcase-dolist (`(,k . ,v) ,params) (puthash (cons 'kx-a k) v table))
     (cl-letf (((symbol-function 'drgnx-tty-frames--tmux-options) (lambda (&rest _) drgnx-tty-clip-test--tmux))
               ((symbol-function 'frame-terminal) (lambda (&optional _) 'kx-a))
               ((symbol-function 'terminal-name) (lambda (&optional term) (symbol-name term)))
               ((symbol-function 'terminal-live-p) (lambda (_term) t))
               ((symbol-function 'terminal-parameter)
                (lambda (term p) (gethash (cons (or term 'kx-a) p) table)))
               ((symbol-function 'set-terminal-parameter)
                (lambda (term p v) (puthash (cons (or term 'kx-a) p) v table)))
               ((symbol-function 'drgnx-tty-frames--identity) (lambda (_frame) (list :id ,id :outer nil :version "1")))
               ((symbol-function 'drgnx-tty-frames-refresh-report) (lambda (frame) (setq reports (1+ reports)) (drgnx-tty-frame-caps frame)))
               ((symbol-function 'display-color-cells) (lambda (&optional _) 256)))
       ,@body)))

(ert-deftest drgnx-tty-clip/tmux-gets-copy ()
  ;; Emacs's xterm.el leaves tmux without it
  (drgnx-tty-clip-test--terminal 'tmux nil
    (should-not (plist-get (drgnx-tty-frame-caps) :osc52))
    (drgnx-tty-clip-setup (selected-frame))
    (should (eq (terminal-parameter nil 'xterm--set-selection) t))
    (should (plist-get (terminal-parameter nil 'drgnx-tty-caps) :osc52))
    (should (= reports 1))))

(ert-deftest drgnx-tty-clip/kitty-under-203-gets-copy ()
  ;; a kitty whose version answer was under 203: Emacs left copy off
  (drgnx-tty-clip-test--terminal 'kitty nil
    (drgnx-tty-clip-setup (selected-frame))
    (should (eq (terminal-parameter nil 'xterm--set-selection) t))
    (should (plist-get (terminal-parameter nil 'drgnx-tty-caps) :osc52)))
  ;; one Emacs turned on already is left as it is, and the report is not written again
  (drgnx-tty-clip-test--terminal 'kitty '((xterm--set-selection . t))
    (drgnx-tty-clip-setup (selected-frame))
    (should (eq (terminal-parameter nil 'xterm--set-selection) t))
    (should (= reports 0))))

(ert-deftest drgnx-tty-clip/vte-gets-none ()
  (drgnx-tty-clip-test--terminal 'vte nil
    (drgnx-tty-clip-setup (selected-frame))
    (should-not (terminal-parameter nil 'xterm--set-selection))
    (should-not (plist-get (terminal-parameter nil 'drgnx-tty-caps) :osc52))
    (should (= reports 0))))

(ert-deftest drgnx-tty-clip/a-frame-that-went-while-asked-is-left-alone ()
  ;; the terminal was killed while drgnx waited for its answer: nothing asked, nothing signalled
  (drgnx-tty-clip-test--terminal 'tmux nil
    (cl-letf (((symbol-function 'frame-live-p) (lambda (_f) nil))
              ((symbol-function 'frame-terminal) (lambda (&rest _) (ert-fail "the dead frame's terminal was read"))))
      (should-not (drgnx-tty-clip-setup (selected-frame))))
    (should-not (terminal-parameter nil 'xterm--set-selection)))
  ;; the frame is live but its terminal went
  (drgnx-tty-clip-test--terminal 'tmux nil
    (cl-letf (((symbol-function 'terminal-live-p) (lambda (_t) nil)))
      (should-not (drgnx-tty-clip-setup (selected-frame))))
    (should-not (terminal-parameter nil 'xterm--set-selection))))

(defmacro drgnx-tty-clip-test--copy-in-tmux (options &rest body)
  "BODY in a fake tmux terminal whose options are OPTIONS, after `drgnx-tty-clip-setup'; `sent' is what
reaches the terminal, newest first."
  (declare (indent 1))
  `(let ((drgnx-tty-clip-test--tmux ,options) sent)
     (drgnx-tty-clip-test--terminal 'tmux nil
       (drgnx-tty-clip-setup (selected-frame))
       (unwind-protect
           (cl-letf (((symbol-function 'send-string-to-terminal) (lambda (s &optional _) (push s sent))))
             ,@body)
         (advice-remove 'gui-backend-set-selection #'drgnx-tty-clip--guard)))))

(ert-deftest drgnx-tty-clip/tmux-with-set-clipboard-on-sends-the-plain-sequence ()
  (drgnx-tty-clip-test--copy-in-tmux '(:set-clipboard "on" :allow-passthrough "on")
    (should (plist-get (terminal-parameter nil 'drgnx-tty-caps) :osc52))
    (gui-backend-set-selection 'CLIPBOARD "hi")
    (should (equal sent '("\e]52;c;aGk=\a")))))

(ert-deftest drgnx-tty-clip/tmux-passthrough-wraps-the-sequence ()
  ;; set-clipboard keeps programs out, allow-passthrough lets the sequence through: tmux's DCS wrapper, ESC doubled
  (dolist (pass '("on" "all"))
    (drgnx-tty-clip-test--copy-in-tmux `(:set-clipboard "external" :allow-passthrough ,pass)
      (should (plist-get (terminal-parameter nil 'drgnx-tty-caps) :osc52))
      (gui-backend-set-selection 'CLIPBOARD "hi")
      (should (equal sent '("\ePtmux;\e\e]52;c;aGk=\a\e\\"))))))

(ert-deftest drgnx-tty-clip/tmux-under-term-screen-sends-no-screen-dcs ()
  ;; TERM=screen (tmux's old default) makes xterm.el wrap in screen's DCS, which tmux ignores
  (drgnx-tty-clip-test--copy-in-tmux '(:set-clipboard "on")
    (set-terminal-parameter nil 'terminal-initted 'terminal-init-screen)
    (gui-backend-set-selection 'CLIPBOARD "hi")
    (should (equal sent '("\e]52;c;aGk=\a")))))

(ert-deftest drgnx-tty-clip/tmux-without-a-way-keeps-the-copy-in-drgnx ()
  (dolist (options '((:set-clipboard "external" :allow-passthrough "off")
                     (:set-clipboard "off")))      ; an older tmux has no allow-passthrough
    (drgnx-tty-clip-test--copy-in-tmux options
      (should-not (terminal-parameter nil 'xterm--set-selection))
      (should-not (plist-get (terminal-parameter nil 'drgnx-tty-caps) :osc52))
      (gui-backend-set-selection 'CLIPBOARD "hi")
      (should-not sent)))
  ;; a tmux drgnx cannot ask (TERM=tmux-* over SSH): the plain sequence, as before
  (drgnx-tty-clip-test--copy-in-tmux nil
    (gui-backend-set-selection 'CLIPBOARD "hi")
    (should (equal sent '("\e]52;c;aGk=\a")))))

(ert-deftest drgnx-tty-clip/a-tmux-set-up-again-follows-its-options ()
  ;; `tmux source ~/.tmux.conf' between two windows: the second setup sees the new options
  (let ((drgnx-tty-clip-test--tmux '(:set-clipboard "external")))
    (drgnx-tty-clip-test--terminal 'tmux nil
      (drgnx-tty-clip-setup (selected-frame))
      (should-not (terminal-parameter nil 'xterm--set-selection))
      (setq drgnx-tty-clip-test--tmux '(:set-clipboard "on"))
      (drgnx-tty-clip-setup (selected-frame))
      (should (eq (terminal-parameter nil 'xterm--set-selection) t))
      (setq drgnx-tty-clip-test--tmux '(:set-clipboard "off"))
      (drgnx-tty-clip-setup (selected-frame))
      (should-not (terminal-parameter nil 'xterm--set-selection)))))

(ert-deftest drgnx-tty-clip/read-is-off-by-default ()
  (should-not drgnx-tty-clipboard-read)
  (dolist (id '(tmux kitty vte))
    (drgnx-tty-clip-test--terminal id nil
      (drgnx-tty-clip-setup (selected-frame))
      (should-not (terminal-parameter nil 'xterm--get-selection)))))

(ert-deftest drgnx-tty-clip/a-read-the-user-turned-on-survives-setup ()
  ;; getSelection through Emacs's own `xterm-extra-capabilities': the default nil does not take it away
  (drgnx-tty-clip-test--terminal 'kitty '((xterm--get-selection . t))
    (drgnx-tty-clip-setup (selected-frame))
    (should (eq (terminal-parameter nil 'xterm--get-selection) t))
    ;; nor does turning the setting off, which only undoes what the setting did
    (cl-letf (((symbol-function 'drgnx-tty-frames--tty-frames) (lambda () (list (selected-frame)))))
      (customize-set-variable 'drgnx-tty-clipboard-read nil))
    (should (eq (terminal-parameter nil 'xterm--get-selection) t))))

(ert-deftest drgnx-tty-clip/read-when-asked ()
  (let ((drgnx-tty-clipboard-read t))
    (drgnx-tty-clip-test--terminal 'kitty nil
      (drgnx-tty-clip-setup (selected-frame))
      (should (eq (terminal-parameter nil 'xterm--get-selection) t))))
  ;; changing the setting reaches the terminals already open, both ways
  (drgnx-tty-clip-test--terminal 'kitty nil
    (cl-letf (((symbol-function 'drgnx-tty-frames--tty-frames) (lambda () (list (selected-frame)))))
      (let ((drgnx-tty-clipboard-read nil))
        (customize-set-variable 'drgnx-tty-clipboard-read t)
        (should (eq (terminal-parameter nil 'xterm--get-selection) t))
        (customize-set-variable 'drgnx-tty-clipboard-read nil)
        (should-not (terminal-parameter nil 'xterm--get-selection))))))

(ert-deftest drgnx-tty-clip/an-overlong-copy-warns-once-without-sit-for ()
  (require 'term/xterm)
  (let (sent messages)
    (drgnx-tty-clip--install)
    (set-terminal-parameter nil 'xterm--set-selection t)
    (set-terminal-parameter nil 'drgnx-tty-clip-warned nil)
    (unwind-protect
        (cl-letf (((symbol-function 'sit-for) (lambda (&rest _) (ert-fail "sit-for was called")))
                  ((symbol-function 'send-string-to-terminal) (lambda (s &optional _) (push s sent)))
                  ((symbol-function 'message) (lambda (fmt &rest args) (push (apply #'format fmt args) messages))))
          (gui-backend-set-selection 'CLIPBOARD (make-string 100001 ?a))
          (gui-backend-set-selection 'CLIPBOARD (make-string 100001 ?a))
          (should-not sent)
          (should (equal messages
                         '("too long for the terminal's clipboard (100001 characters); kept in drgnx")))
          ;; a copy that fits still goes out
          (gui-backend-set-selection 'CLIPBOARD "hello drgnx")
          (should (equal sent (list (concat "\e]52;c;" (base64-encode-string "hello drgnx") "\a")))))
      (advice-remove 'gui-backend-set-selection #'drgnx-tty-clip--guard)
      (set-terminal-parameter nil 'xterm--set-selection nil)
      (set-terminal-parameter nil 'drgnx-tty-clip-warned nil))))

(ert-deftest drgnx-tty-clip/the-limit-is-the-encoded-length ()
  ;; xterm.el refuses when the base64 text is over `xterm-max-cut-length': 75001 bytes encode to 100004 characters
  (should (drgnx-tty-clip--too-long-p (make-string 75001 ?a)))
  (should-not (drgnx-tty-clip--too-long-p (make-string 75000 ?a)))
  ;; bytes, not characters
  (should (drgnx-tty-clip--too-long-p (make-string 40000 ?é))))

;;; mod-tty-clipboard-test.el ends here
