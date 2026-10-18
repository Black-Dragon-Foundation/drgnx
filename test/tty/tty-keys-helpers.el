;;; tty-keys-helpers.el --- tty tier: helpers shared by keys-test.el and fallback-test.el -*- lexical-binding: t -*-
;; Not a test file (the runner loads only *-test.el): kkp from DRGNX_USER_ELPA, a client's frame and caps,
;; recording the commands that ran, answering kkp's question, quitting the palette.  Both test files
;; load it once (`featurep'), so no test is defined twice.
(require 'ert)
(require 'drgnx-tty-session)

(defun drgnx-tty-keys-test--pinned ()
  "The kkp entry of the shipped lock (etc/drgnx.lock.eld): (VERSION . SHA256)."
  (let ((e (alist-get 'kkp (plist-get (with-temp-buffer
                                        (insert-file-contents (expand-file-name "../etc/drgnx.lock.eld"
                                                                                drgnx-ui-harness-dir))
                                        (read (current-buffer)))
                                      :packages))))
    (cons (plist-get e :version) (plist-get e :sha256))))

(defun drgnx-tty-keys-test--kkp-dir ()
  "The pinned kkp's directory in DRGNX_USER_ELPA (read-only), or nil."
  (let ((dir (expand-file-name (concat "kkp-" (car (drgnx-tty-keys-test--pinned))) (or (getenv "DRGNX_USER_ELPA") "/nonexistent"))))
    (and (file-directory-p dir) dir)))

(defun drgnx-tty-keys-test--need-kkp ()
  "Skip, saying how to supply it, unless the pinned kkp is in DRGNX_USER_ELPA."
  (unless (drgnx-tty-keys-test--kkp-dir)
    (let ((pin (drgnx-tty-keys-test--pinned)))
      (ert-skip (format "kkp %s not in DRGNX_USER_ELPA: unpack https://melpa.org/packages/kkp-%s.tar (sha256 %s) \
into a directory and set DRGNX_USER_ELPA to it, or point DRGNX_USER_ELPA at an elpa drgnx sync filled"
                        (car pin) (car pin) (cdr pin))))))

(defun drgnx-tty-keys-test--env ()
  "The inner Emacs's extra environment: kkp on its load path (read-only, nothing installed)."
  (list (concat "EMACSLOADPATH=" (drgnx-tty-keys-test--kkp-dir) ":")))

(defun drgnx-tty-keys-test--frame (c)
  "A form, in the inner daemon: the frame of client C (the frame on C's pane's tty)."
  (let ((tty (string-trim (drgnx-tty-keys-test--tmux c "display" "-p" "-t" (plist-get c :target) "#{pane_tty}"))))
    `(seq-find (lambda (f) (equal (terminal-name (frame-terminal f)) ,tty)) (frame-list))))

(defun drgnx-tty-keys-test--tmux (sess &rest args)
  "tmux ARGS on SESS's server; its output (the test fails on an error)."
  (let ((r (apply #'drgnx-tty-session-tmux sess args)))
    (should (eq (car r) 0))
    (cdr r)))

(defun drgnx-tty-keys-test--caps (s c)
  "Client C's terminal's capabilities (its terminal parameter `drgnx-tty-caps')."
  (drgnx-tty-session-eval s `(terminal-parameter (frame-terminal ,(drgnx-tty-keys-test--frame c)) 'drgnx-tty-caps)))

(defconst drgnx-tty-keys-test--record
  '(progn
     (defvar kx-seen nil)
     (setq kx-seen nil)
     (add-hook 'pre-command-hook (lambda () (push (cons this-command (key-description (this-command-keys-vector))) kx-seen)))
     t)
  "A form, in the inner daemon: record each command and the key that ran it in `kx-seen', newest first.")

(defun drgnx-tty-keys-test--kkp-yes (name)
  "A form, in the inner daemon: terminals made from now on say they are NAME (their XTVERSION answer, e.g.
\"kitty(0.40.0)\") and answer kkp's question with yes once the test sends the answer
\(`drgnx-tty-keys-test--answer-kkp'); `kx-kkp-asked' counts the questions."
  `(progn
     (defvar kx-kkp-asked 0)
     (defvar kx-xtversion nil)
     (setq kx-xtversion ,(concat "\eP>|" name "\e\\"))
     ;; as the real one: the answer is also the terminal's parameter
     (advice-add 'drgnx-tty-frames--ask :override
                 (lambda (frame)
                   (set-terminal-parameter (frame-terminal frame) 'drgnx-tty-xtversion kx-xtversion)
                   kx-xtversion)
                 '((name . kx-kkp-yes)))
     ;; the question is not sent (tmux would answer its device-attributes half and so say no): the test answers
     (advice-add 'kkp--query-terminal-async :around
                 (lambda (orig &rest args)
                   (setq kx-kkp-asked (1+ kx-kkp-asked))
                   (cl-letf (((symbol-function 'send-string-to-terminal) #'ignore)) (apply orig args)))
                 '((name . kx-kkp-yes)))
     ;; …and the flags the terminal took are the ones asked for
     (advice-add 'kkp--query-terminal-sync :override
                 (lambda (&rest _) (append (format "\e[?%du" (kkp--calculate-flags-integer)) nil))
                 '((name . kx-kkp-yes)))
     t))

(defconst drgnx-tty-keys-test--kitty "kitty(0.40.0)" "The XTVERSION answer of a kitty.")

(defun drgnx-tty-keys-test--answer-kkp (s c)
  "Answer kkp's question in client C's terminal as a kkp terminal does (flags, then device attributes); wait
until kkp is on there and drgnx marked it."
  (drgnx-tty-session-send c "\e[?0u\e[?62;22c")
  (drgnx-tty-session-wait s `(let ((term (frame-terminal ,(drgnx-tty-keys-test--frame c))))
                               (and (terminal-parameter term 'drgnx-tty-kkp) (kkp--active-p term)))
                          10))

(defun drgnx-tty-keys-test--ran (s command key)
  "Wait until COMMAND ran from KEY (as `drgnx-tty-keys-test--record' saw it)."
  (drgnx-tty-session-wait s `(and (member (cons ',command ,key) kx-seen) t) 10))

(defun drgnx-tty-keys-test--quit (s c caps)
  "C-g in client C (CAPS) until the minibuffer is gone: a C-g that lands while the palette still fills its list
quits only that (\"[Quit]\"), as it would for a person, who presses it again."
  (let ((tries 0))
    (while (and (drgnx-tty-session-eval s '(and (active-minibuffer-window) t)) (< tries 5))
      (drgnx-tty-session-key c "C-g" caps)
      (setq tries (1+ tries))
      (let ((deadline (+ (float-time) 1)))
        (while (and (drgnx-tty-session-eval s '(and (active-minibuffer-window) t)) (< (float-time) deadline))
          (sleep-for 0.05))))
    (should-not (drgnx-tty-session-eval s '(active-minibuffer-window)))))

(provide 'tty-keys-helpers)
;;; tty-keys-helpers.el ends here
