;;; look-echo-gui-test.el --- GUI tests: no echo row; prompts float in a box at the top (run by `drgnx test --ui') -*- lexical-binding: t -*-
;; test-class: cond
;; test-pattern: handshake

;; `drgnx-look-echo-row' `float': a graphical frame made while it is on has no echo row; its minibuffer is a child
;; frame, the box, hidden while nothing asks.  Every kind of prompt shows in the box while it waits (C's prompts are
;; told apart by Nidhogg's `nidhogg-echo-prompt'), the box hides once it is answered, and plain messages and the keys
;; of a prefix go to the status bar.  Each row makes its own frame and turns the feature off again, so the harness's
;; frame keeps its row.

(require 'ert)
(require 'cl-lib)
(require 'seq)
(require 'drgnx-look-gui-fixture (expand-file-name "../fixtures/look-gui-fixture" (file-name-directory (macroexp-file-name))))
(require 'drgnx-wait-fixture (expand-file-name "../fixtures/wait-fixture" (file-name-directory (macroexp-file-name))))
(require 'drgnx-uitest)

(defconst drgnx-look-echo-ui-test--repo
  (expand-file-name "../../" (file-name-as-directory (or (getenv "DRGNX_UI_TEST") default-directory))))
(dolist (d '("core" "wb" "harness"))
  (add-to-list 'load-path (expand-file-name d drgnx-look-echo-ui-test--repo)))
(require 'drgnx)
(add-to-list 'custom-theme-load-path (expand-file-name "themes" drgnx-look-echo-ui-test--repo))
(dolist (m '("drgnx-look" "drgnx-look-echo"))
  (load (expand-file-name (concat "modules/ui/" m) drgnx-look-echo-ui-test--repo) nil t))

(declare-function drgnx-look-echo-on "drgnx-look-echo" ())
(declare-function drgnx-look-echo-off "drgnx-look-echo" ())
(declare-function drgnx-look-echo-box "drgnx-look-echo" (&optional frame))
(declare-function drgnx-look-echo-swap "drgnx-look-echo" (frame))
(declare-function drgnx-look-echo-status-text "drgnx-look-echo" ())
(declare-function drgnx-look-echo-area-on "drgnx-look" ())
(declare-function drgnx-look-echo-area-off "drgnx-look" ())
(defvar drgnx-look-echo-row)

(defun drgnx-look-echo-ui-test--out (name)
  (expand-file-name name (or (getenv "DRGNX_UI_EVIDENCE") temporary-file-directory)))

(defmacro drgnx-look-echo-ui-test--with-frame (var &rest body)
  "BODY with the feature on and VAR a new frame made under it, selected; the frame, the feature and the selection
undone after."
  (declare (indent 1))
  `(let ((was (selected-frame)) (,var nil))
     (drgnx-look-echo-on)
     (unwind-protect
         (progn
           (setq ,var (make-frame '((width . 90) (height . 30))))
           (select-frame-set-input-focus ,var)
           (drgnx-test-wait-presented :frame ,var)
           ,@body)
       (when (frame-live-p ,var) (delete-frame ,var t))
       (drgnx-look-echo-off)
       (when (frame-live-p was) (select-frame-set-input-focus was))
       (message nil)
       (drgnx-test-wait-presented))))

(defun drgnx-look-echo-ui-test--box-text (box)
  "What BOX shows: the active minibuffer's text, else the echo area's."
  (or (and (active-minibuffer-window)
           (with-current-buffer (window-buffer (active-minibuffer-window))
             (buffer-substring-no-properties (point-min) (point-max))))
      (and (current-message) (substring-no-properties (current-message)))
      (ignore box)))

(defvar drgnx-look-echo-ui-test--note nil
  "While a row waits at a prompt: called by the special event `drgnx-look-echo-ui-test-note' (`special-event-map'),
which the prompt's own read runs without returning it.")

(defun drgnx-look-echo-ui-test--note ()
  "The special event's command: call the waiting row's note."
  (interactive)
  (when drgnx-look-echo-ui-test--note (funcall drgnx-look-echo-ui-test--note)))

(define-key special-event-map [drgnx-look-echo-ui-test-note] #'drgnx-look-echo-ui-test--note)

(defun drgnx-look-echo-ui-test--at-prompt (box fn keys)
  "Run FN once the read now starting waits with BOX shown (else after 40 notes: a prompt that never shows it), then
answer with KEYS.  The harness's queue delivers each note to the read itself, so a note runs only while it waits."
  (let ((tries 40))
    (setq drgnx-look-echo-ui-test--note
          (lambda ()
            (if (and (not (frame-visible-p box)) (> (setq tries (1- tries)) 0))
                (drgnx-uitest-enqueue (list 'drgnx-look-echo-ui-test-note))
              (setq drgnx-look-echo-ui-test--note nil)
              (funcall fn)
              (drgnx-uitest-enqueue (append (listify-key-sequence keys) nil)))))
    (drgnx-uitest-enqueue (list 'drgnx-look-echo-ui-test-note))))

(defvar drgnx-look-echo-ui-test--shown nil
  "While a row waits at a prompt: its check, called from `pre-redisplay-functions' until it returns non-nil.")

(defun drgnx-look-echo-ui-test--redisplay (&rest _)
  "One of `pre-redisplay-functions' while a row waits: call its check; done once it says so."
  (when (and drgnx-look-echo-ui-test--shown (funcall drgnx-look-echo-ui-test--shown))
    (drgnx-look-echo-ui-test--unshown)))

(defun drgnx-look-echo-ui-test--unshown ()
  "Stop watching redisplay for the box, and take the marker pause out of the harness's queue."
  (remove-hook 'pre-redisplay-functions #'drgnx-look-echo-ui-test--redisplay)
  (setq drgnx-look-echo-ui-test--shown nil
        drgnx-uitest--queue (seq-remove (lambda (e) (memq (car-safe e) '(drgnx-uitest-pause drgnx-uitest-until)))
                                        drgnx-uitest--queue)))

(defun drgnx-look-echo-ui-test--at-shown (box fn keys)
  "Run FN at the redisplay that shows BOX, which the read now starting does as it waits, then answer with KEYS.
FN only reads the frames' state, which redisplay may.  No note (`drgnx-look-echo-ui-test--at-prompt'): where the box
is slow to show (at 2) a note is sent again, and one that arrives as a read loops is taken from
`unread-command-events' as input, not as a special event: `query-replace' ends on it and puts it back, and the next
read from C (`interactive' \"c\") signals \"Non-character input-event\".  A long pause waits in the
harness's queue until then (the check takes it out), so the session's guard on idle prompts sees an answer
coming through the waits a prompt makes before it shows (`query-replace''s highlighting)."
  (setq drgnx-look-echo-ui-test--shown
        (lambda ()
          (when (frame-visible-p box)
            (funcall fn)
            (drgnx-look-echo-ui-test--unshown)
            (drgnx-uitest-enqueue (append (listify-key-sequence keys) nil))
            t)))
  (add-hook 'pre-redisplay-functions #'drgnx-look-echo-ui-test--redisplay)
  (drgnx-uitest-enqueue (list (cons 'drgnx-uitest-pause 3600))))

(defun drgnx-look-echo-ui-test--ask (form keys &optional command)
  "Run FORM; while it waits, note (VISIBLE TEXT PLACE) of the box, then answer with KEYS.  Return
(SEEN . AFTER-VISIBLE).  COMMAND non-nil: FORM is a command's own read from C, which only the command's end follows
(`post-command-hook', as the command loop runs it).
PLACE is (LEFT TOP WIDTH PARENT-WIDTH PARENT-HEIGHT): the box in its parent's pixels."
  (let* ((box (drgnx-look-echo-box)) seen)
    (drgnx-look-echo-ui-test--at-shown
     box (lambda ()
           (setq seen (list (frame-visible-p box) (drgnx-look-echo-ui-test--box-text box)
                            (list (car (frame-position box)) (cdr (frame-position box))
                                  (frame-pixel-width box) (frame-pixel-width (frame-parent box))
                                  (frame-pixel-height (frame-parent box))))))
     keys)
    (unwind-protect (eval form t) (drgnx-look-echo-ui-test--unshown))
    (when command (run-hooks 'post-command-hook))
    (drgnx-test-wait-presented)
    (cons seen (frame-visible-p box))))

(drgnx-look-gui-deftest drgnx-ui-look-echo/a-new-frame-has-no-echo-row ()
  "A graphical frame made while it is on: its minibuffer is a child frame of it, hidden, and its windows reach its
bottom edge."
  (skip-unless (display-graphic-p))
  (drgnx-look-echo-ui-test--with-frame f
    (let ((box (drgnx-look-echo-box f)))
      (should (framep box))
      (should (eq (frame-parent box) f))
      (should (eq (frame-parameter box 'minibuffer) 'only))
      (should-not (frame-visible-p box))
      (should (= (nth 3 (window-pixel-edges (frame-root-window f))) (frame-inner-height f))))))

(drgnx-look-gui-deftest drgnx-ui-look-echo/every-prompt-shows-in-the-box ()
  "read-key, read-char, read-char-exclusive, y-or-n-p, yes-or-no-p, a password, query-replace, `interactive' \"c\"
and \"k\" (C's own reads): the box shows the prompt while it waits, top-centre in the frame, and hides once answered."
  (skip-unless (display-graphic-p))
  (drgnx-look-echo-ui-test--with-frame f
    (let (fails)
      (pcase-dolist (`(,name ,form ,keys ,want ,command)
                     '((read-key (read-key "Key? ") "k" "Key? ")
                       (read-char (read-char "Char? ") "c" "Char? ")
                       (read-char-exclusive (read-char-exclusive "Excl? ") "c" "Excl? ")
                       (y-or-n (y-or-n-p "Yes? ") "y" "Yes? ")
                       (yes-or-no (yes-or-no-p "Sure? ") "yes\r" "Sure? ")
                       (password (read-passwd "Password: ") "pw\r" "Password: ")
                       (query-replace (with-temp-buffer
                                        (switch-to-buffer (current-buffer))
                                        (insert "aaa") (goto-char (point-min))
                                        (perform-replace "a" "b" t nil nil))
                                      "yq" "Query replacing a with b")
                       (interactive-c (call-interactively (lambda (c) (interactive "cArg: ") c)) "x" "Arg: ")
                       (interactive-k (call-interactively (lambda (k) (interactive "kKeys: ") k)) "x" "Keys: " t)))
        (pcase-let ((`((,visible ,text (,left ,top ,w ,pw ,ph)) . ,after) (drgnx-look-echo-ui-test--ask form keys command)))
          (unless (and visible (stringp text) (string-search want text)
                       (<= (abs (- (+ left (/ w 2)) (/ pw 2))) 2)       ; centred
                       (< 0 top (/ ph 4))                              ; at the top
                       (not after))
            (push (list name :visible visible :text text :place (list left top w pw ph) :after-visible after) fails))))
      (should-not fails))))

(drgnx-look-gui-deftest drgnx-ui-look-echo/messages-and-prefix-keys-go-to-the-status-bar ()
  "A plain message and the keys of a prefix (`nidhogg-echo-prompt' `keys') leave the box hidden and show in the
status bar's text."
  (skip-unless (display-graphic-p))
  (drgnx-look-echo-ui-test--with-frame f
    (let* ((box (drgnx-look-echo-box f)) (born (frame-visible-p box)) calls
           (spy (lambda (orig text)
                  (let ((r (funcall orig text)))
                    (push (list text r (frame-visible-p box) (eq (selected-frame) f) (and (drgnx-look-echo-box) t)) calls)
                    r))))
      (advice-add 'drgnx-look-echo--route :around spy)
      (unwind-protect (message "a plain message") (advice-remove 'drgnx-look-echo--route spy))
      (let ((right-after (frame-visible-p box)))
        (drgnx-test-wait-presented)
        (should-not (and (frame-visible-p box)
                         (list :born born :right-after right-after :calls calls :fns set-message-functions
                               :smf set-message-function :echo (current-message)))))
      (should (equal (drgnx-look-echo-status-text) "a plain message"))
      (let ((nidhogg-echo-prompt 'keys)) (message "C-x-"))
      (drgnx-test-wait-presented)
      (should-not (frame-visible-p box))
      (should (equal (drgnx-look-echo-status-text) "C-x-")))))

(drgnx-look-gui-deftest drgnx-ui-look-echo/swap-keeps-the-layout ()
  "Turning it on swaps a frame with a row for one with the box (and off, back): the window tree, each window's
buffer and point, the selected window, the frame's size and its buffers survive."
  (skip-unless (display-graphic-p))
  (let* ((was (selected-frame))
         (f (make-frame '((width . 90) (height . 30))))
         (a (get-buffer-create "*echo-swap-a*")) (b (get-buffer-create "*echo-swap-b*")) (c (get-buffer-create "*echo-swap-c*"))
         new back)
    (unwind-protect
        (progn
          (select-frame-set-input-focus f)
          (with-current-buffer b (insert "line one\nline two\n") (goto-char 10))
          (let* ((w1 (frame-root-window f)) (w2 (split-window w1 nil 'right)) (w3 (split-window w2 nil 'below)))
            (set-window-buffer w1 a) (set-window-buffer w2 b) (set-window-point w2 10) (set-window-buffer w3 c)
            (select-window w2))
          (drgnx-test-wait-presented :frame f)
          (let ((shape (drgnx-look-echo-ui-test--shape f)) (size (list (frame-text-width f) (frame-text-height f))))
            (drgnx-look-echo-on)
            (setq new (drgnx-look-echo-swap f))
            (drgnx-test-wait-presented :frame new)
            (should-not (frame-live-p f))
            (should (framep (drgnx-look-echo-box new)))
            (should (equal (drgnx-look-echo-ui-test--shape new) shape))
            (should (eq (window-buffer (frame-selected-window new)) b))
            (should (= (window-point (frame-selected-window new)) 10))
            (should (equal (list (frame-text-width new) (frame-text-height new)) size))
            (drgnx-look-echo-off)
            (setq back (drgnx-look-echo-swap new))
            (drgnx-test-wait-presented :frame back)
            (should-not (drgnx-look-echo-box back))
            (should (eq (window-frame (minibuffer-window back)) back))
            (should (equal (drgnx-look-echo-ui-test--shape back) shape))
            (should (cl-every #'buffer-live-p (list a b c)))))
      (drgnx-look-echo-off)
      (dolist (x (list f new back)) (when (frame-live-p x) (delete-frame x t)))
      (mapc #'kill-buffer (list a b c))
      (when (frame-live-p was) (select-frame-set-input-focus was))
      (drgnx-test-wait-presented))))

(defun drgnx-look-echo-ui-test--shape (frame)
  "FRAME's windows as (BUFFER-NAME LEFT RIGHT AT-TOP SELECTED): the columns exactly, the rows only as top or not (a
frame without the echo row gives its windows that row)."
  (mapcar (lambda (w) (list (buffer-name (window-buffer w)) (nth 0 (window-edges w)) (nth 2 (window-edges w))
                            (= 0 (nth 1 (window-edges w))) (eq w (frame-selected-window frame))))
          (window-list frame 'nomini (frame-first-window frame))))

(drgnx-look-gui-deftest drgnx-ui-look-echo/the-box-in-each-theme ()
  "A prompt in the box in the dark, light and high contrast themes: shots for the eye, and the box's surface is the
palette's: the echo area draws `default' as the gap surface, as the palette's minibuffer does (`drgnx-surface-gap')."
  (skip-unless (display-graphic-p))
  (let ((themes custom-enabled-themes))
    (drgnx-look-echo-area-on)
    (unwind-protect
        (dolist (theme '(drgnx-dark drgnx-light drgnx-high-contrast))
          (mapc #'disable-theme custom-enabled-themes)
          (load-theme theme t)
          (drgnx-look-echo-ui-test--with-frame f
            (let ((box (drgnx-look-echo-box f)))
              (drgnx-look-echo-ui-test--at-prompt
               box (lambda () (drgnx-uitest-capture (drgnx-look-echo-ui-test--out (format "echo-box-%s" theme)))) "c")
              (unwind-protect (read-char "Pick a register: ") (setq drgnx-look-echo-ui-test--note nil))
              (with-current-buffer (get-buffer-create " *Echo Area 0*")
                (should (memq 'drgnx-surface-gap (cdr (assq 'default face-remapping-alist))))))))
      (drgnx-look-echo-area-off)
      (mapc #'disable-theme custom-enabled-themes)
      (mapc (lambda (th) (load-theme th t)) (reverse themes)))))

(drgnx-look-gui-deftest drgnx-ui-look-echo/daemon-and-emacsclient ()
  "A daemon with the feature on: the frame `emacsclient -c' makes has the box (hidden) and no echo row; a prompt the
client's frame asks for shows in it."
  (skip-unless (display-graphic-p))
  (let* ((dir (make-temp-file "drgnx-echo-sock" t))
         (sock (expand-file-name "d" dir))
         (client (expand-file-name "emacsclient" invocation-directory))
         (emacs (expand-file-name invocation-name invocation-directory))
         (init (format "(progn (setq server-socket-dir %S) (dolist (d '(\"core\" \"wb\" \"harness\")) (add-to-list 'load-path (expand-file-name d %S))) (require 'drgnx) (load (expand-file-name \"modules/ui/drgnx-look\" %S) nil t) (load (expand-file-name \"modules/ui/drgnx-look-echo\" %S) nil t) (drgnx-look-echo-on))"
                       dir drgnx-look-echo-ui-test--repo drgnx-look-echo-ui-test--repo drgnx-look-echo-ui-test--repo))
         (daemon (make-process :name "echo-daemon" :buffer (get-buffer-create " *echo-daemon*")
                               :command (list emacs "-Q" "--eval" init "--fg-daemon=d")))
         (ask (lambda (form)
                (with-temp-buffer
                  (call-process client nil t nil "-s" sock "-e" form)
                  (buffer-string))))
         res)
    (unwind-protect
        (progn
          (drgnx-test-wait (lambda () (file-exists-p sock)) :what "the daemon's socket" :secs 60)
          (call-process client nil 0 nil "-s" sock "-c" "-n")
          (drgnx-test-wait (lambda () (string-match-p "t" (funcall ask "(and (seq-find (lambda (x) (and (display-graphic-p x) (not (frame-parent x)))) (frame-list)) t)")))
                           :what "the client's frame" :secs 60)
          (setq res (car (read-from-string
                          (funcall ask "(let* ((f (seq-find (lambda (x) (and (display-graphic-p x) (not (frame-parent x)))) (frame-list))) (box (drgnx-look-echo-box f))) (list :box (and box t) :parent (and box (eq (frame-parent box) f)) :hidden (and box (not (frame-visible-p box))) :no-row (= (nth 3 (window-pixel-edges (frame-root-window f))) (frame-inner-height f))))"))))
          (with-temp-file (drgnx-look-echo-ui-test--out "echo-daemon.eld") (pp res (current-buffer)))
          (should (equal res '(:box t :parent t :hidden t :no-row t)))
          (let ((shown (car (read-from-string
                             (funcall ask "(let* ((f (seq-find (lambda (x) (and (display-graphic-p x) (not (frame-parent x)))) (frame-list))) (box (drgnx-look-echo-box f)) seen) (with-selected-frame f (run-at-time 0.3 nil (lambda () (setq seen (frame-visible-p box)) (setq unread-command-events (list ?c)))) (read-char \"Client? \")) seen)")))))
            (should (eq shown t))))
      (ignore-errors (call-process client nil nil nil "-s" sock "-e" "(kill-emacs)"))
      (delete-process daemon)
      (delete-directory dir t))))

(provide 'look-echo-gui-test)
;;; look-echo-gui-test.el ends here
