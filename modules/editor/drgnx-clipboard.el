;;; drgnx-clipboard.el --- Module editor/clipboard: living with OS clipboard managers -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Clipboard managers (GPaste, Clipboard Indicator, Klipper, CopyQ, Maccy, Windows clipboard history) keep every
;; change of the system clipboard.  Emacs clashes with them in three ways; this module deals with each.
;;
;; - Kills: Emacs puts every kill (C-k, M-d, ...) on the system clipboard, so a manager's history fills with
;;   fragments.  With `drgnx-clipboard-kills' `region' (the default) only the commands of
;;   `drgnx-clipboard-commands' (copy and cut) push; the rest stay in the kill ring.  A command that copies on
;;   purpose binds `drgnx-clipboard-force'.  This is also what a terminal's OSC 52 copy goes through.
;; - A clipboard owner that does not answer: reading the clipboard waits for the owner, and Emacs by default waits
;;   for ever.  `drgnx-clipboard-read-timeout' sets the wait (when the user did not), and a read that fails gives
;;   nil, so a yank pastes from the kill ring (one message per session).
;; - Selecting text: a manager that syncs the selection (PRIMARY) with the clipboard makes every selection in Emacs
;;   a history entry.  drgnx finds Klipper, CopyQ and GPaste doing that and, with
;;   `drgnx-clipboard-publish-selection' `auto', turns `select-active-regions' off.
;;
;; Nothing here prompts or waits: the manager check reads two small config files and /proc, and GPaste's settings
;; are asked from `gsettings' asynchronously (1 s at most).  See docs/guide/editing.md.

;;; Code:
(require 'cl-lib)
(require 'subr-x)
(require 'drgnx-modules)

(defvar x-selection-timeout)
(defvar pgtk-selection-timeout)

;;;; Settings

(defcustom drgnx-clipboard-kills 'region
  "Which kills reach the system clipboard.
`region': only the commands of `drgnx-clipboard-commands' (copy and cut); every other kill (C-k, M-d, ...) stays
in the kill ring, so a clipboard manager's history is not flooded.  `all': Emacs's own behaviour."
  :type '(choice (const :tag "Copy and cut only" region) (const :tag "Every kill (Emacs's default)" all))
  :group 'drgnx)

(defcustom drgnx-clipboard-commands
  '(kill-region kill-ring-save clipboard-kill-region clipboard-kill-ring-save drgnx-editing-copy drgnx-editing-cut
                cua-cut-region cua-copy-region evil-yank evil-delete drgnx-explorer-copy-path
                drgnx-explorer-copy-relative-path drgnx-buffers-copy-path-row)
  "Commands whose kills reach the system clipboard when `drgnx-clipboard-kills' is `region'.
Code that copies on purpose can bind `drgnx-clipboard-force' instead."
  :type '(repeat symbol) :group 'drgnx)

(defvar drgnx-clipboard-force nil
  "Non-nil (let-bound): a kill made now reaches the system clipboard, whatever the command.")

(defcustom drgnx-clipboard-read-timeout 1.5
  "Seconds drgnx waits for the clipboard owner to answer a paste (nil: leave Emacs's setting).
Applies to `x-selection-timeout' and `pgtk-selection-timeout' when they are at their standard value, 0 (wait
as long as it takes).  On a timeout the paste comes from the kill ring."
  :type '(choice (const :tag "Leave as it is" nil) number) :group 'drgnx)

(defcustom drgnx-clipboard-publish-selection 'auto
  "Whether selecting text publishes it (PRIMARY selection), which a syncing clipboard manager records.
`auto': off (`select-active-regions' nil) while a manager that syncs the selection with the clipboard is found
(Klipper, CopyQ, GPaste), otherwise as it is.  t: always on.  nil: always off."
  :type '(choice (const :tag "Off when a manager syncs" auto) (const :tag "Always on" t) (const :tag "Always off" nil))
  :group 'drgnx
  :initialize #'custom-initialize-default
  :set (lambda (sym val)
         (set-default sym val)
         (when (fboundp 'drgnx-clipboard--apply-publish) (drgnx-clipboard--apply-publish))))

;;;; Kills

(defvar drgnx-clipboard--orig-cut nil "The `interprogram-cut-function' drgnx wrapped.")
(defvar drgnx-clipboard--orig-paste nil "The `interprogram-paste-function' drgnx wrapped.")
(defvar drgnx-clipboard--installed nil "Non-nil while the wrappers are in place.")
(defvar drgnx-clipboard--decision nil
  "What the running command's first kill decided: `pushed' (it reached the clipboard) or `blocked'.
Later kills of the same command follow it: a command such as `kill-whole-line' kills in steps and sets
`this-command' to `kill-region' after the first, which must not turn the rest into a copy.")

(defun drgnx-clipboard--new-command ()
  "`pre-command-hook': the next command decides afresh."
  (setq drgnx-clipboard--decision nil))

(defun drgnx-clipboard--command-ok-p ()
  "Non-nil when the running command is one of `drgnx-clipboard-commands'."
  (or (memq this-command drgnx-clipboard-commands) (memq real-this-command drgnx-clipboard-commands)))

(defun drgnx-clipboard--cut (text)
  "`interprogram-cut-function': give TEXT to the wrapped function when this kill may reach the clipboard.
The command's first kill decides for the whole command: a copy or cut reaches the clipboard once, any other
kill never (`drgnx-clipboard-force' and `drgnx-clipboard-kills' `all' skip the decision)."
  (when drgnx-clipboard--orig-cut
    (cond ((or drgnx-clipboard-force (eq drgnx-clipboard-kills 'all))
           (funcall drgnx-clipboard--orig-cut text))
          (drgnx-clipboard--decision nil)
          ((drgnx-clipboard--command-ok-p)
           (setq drgnx-clipboard--decision 'pushed)
           (funcall drgnx-clipboard--orig-cut text))
          (t (setq drgnx-clipboard--decision 'blocked)))))

(defvar drgnx-clipboard--warned nil "Non-nil once the slow-owner message was shown this session.")

(defun drgnx-clipboard--paste ()
  "`interprogram-paste-function': the wrapped function's answer; nil, with one message, when it fails
(an owner that did not answer in time), so the paste comes from the kill ring."
  (when drgnx-clipboard--orig-paste
    (condition-case nil
        (funcall drgnx-clipboard--orig-paste)
      (error
       (unless drgnx-clipboard--warned
         (setq drgnx-clipboard--warned t)
         (message "drgnx: the clipboard owner didn't answer in %s s; pasted from Emacs's own copies"
                  (format "%g" (or drgnx-clipboard-read-timeout 0))))
       nil))))

;;;; Read timeout

(defvar drgnx-clipboard--timeout-set nil "Alist VARIABLE → the value drgnx gave it (so it is only put back if unchanged).")

(defun drgnx-clipboard--apply-timeout ()
  "Give the selection timeout variables `drgnx-clipboard-read-timeout' (ms) where they are at the standard 0."
  (when (numberp drgnx-clipboard-read-timeout)
    (dolist (var '(x-selection-timeout pgtk-selection-timeout))
      (when (and (boundp var) (eql (symbol-value var) 0))
        (let ((ms (round (* 1000 drgnx-clipboard-read-timeout))))
          (set var ms)
          (setf (alist-get var drgnx-clipboard--timeout-set) ms))))))

(defun drgnx-clipboard--restore-timeout ()
  (pcase-dolist (`(,var . ,ms) drgnx-clipboard--timeout-set)
    (when (and (boundp var) (eql (symbol-value var) ms)) (set var 0)))
  (setq drgnx-clipboard--timeout-set nil))

;;;; Finding a syncing manager

(defvar drgnx-clipboard--state nil
  "What the last check found: (:manager SYMBOL-or-nil :checked t :changed (VARIABLE …) :settings ALIST).")

(defvar drgnx-clipboard--saved-regions nil "Cons (ORIGINAL) of `select-active-regions' before drgnx changed it.")

(defun drgnx-clipboard--graphical-p (&optional frame)
  "Non-nil when FRAME (default: the selected frame) is on X11 or Wayland."
  (and (memq (window-system frame) '(x pgtk)) t))

(defun drgnx-clipboard--process-names ()
  "The names (comm) of the running processes, from /proc (nil where there is none).  Cheap, never blocks."
  (when (file-directory-p "/proc/self")
    (let (names)
      (dolist (pid (directory-files "/proc" nil "\\`[0-9]+\\'"))
        (when-let* ((name (ignore-errors
                            (with-temp-buffer
                              (insert-file-contents (format "/proc/%s/comm" pid))
                              (string-trim (buffer-string))))))
          (push name names)))
      names)))

(defun drgnx-clipboard--config-file (relative)
  "RELATIVE (a path under the XDG config directory) as a file name."
  (expand-file-name relative (or (getenv "XDG_CONFIG_HOME") (expand-file-name ".config" (getenv "HOME")))))

(defun drgnx-clipboard--file-has (file regexp)
  "Non-nil when FILE exists and a line of it matches REGEXP (the file is read, never written)."
  (and (file-readable-p file)
       (ignore-errors
         (with-temp-buffer
           (insert-file-contents file nil 0 65536)
           (goto-char (point-min))
           (re-search-forward regexp nil t)))
       t))

(defun drgnx-clipboard--klipper-p (procs)
  "Klipper syncs the clipboard and the selection: its config says so and it (or plasmashell) runs."
  (and (or (member "klipper" procs) (member "plasmashell" procs))
       (drgnx-clipboard--file-has (drgnx-clipboard--config-file "klipperrc") "^SyncClipboards=true\\s-*$")))

(defun drgnx-clipboard--copyq-p (procs)
  "CopyQ runs and takes the selection (check_selection) or copies it to the clipboard (copy_selection)."
  (and (member "copyq" procs)
       (drgnx-clipboard--file-has (drgnx-clipboard--config-file "copyq/copyq.conf")
                                  "^\\(?:copy_selection\\|check_selection\\)=true\\s-*$")))

(defun drgnx-clipboard--gpaste-ask (done)
  "Ask `gsettings' (asynchronously, 1 s at most) whether GPaste syncs the selection and the clipboard; call
DONE once with t or nil.  Without gsettings, DONE gets nil at once."
  (let ((program (executable-find "gsettings"))
        (keys '("synchronize-clipboards" "primary-to-history"))
        (answers nil) (procs nil) (finished nil) (timer nil))
    (cl-flet ((finish (ok)
                (unless finished
                  (setq finished t)
                  (when (timerp timer) (cancel-timer timer))
                  (dolist (p procs) (when (process-live-p p) (delete-process p)))
                  (funcall done ok))))
      (if (not program)
          (finish nil)
        (setq timer (run-at-time 1 nil (lambda () (finish nil))))
        (dolist (key keys)
          (let ((key key) (out ""))
            (push (condition-case nil
                      (make-process
                       :name (format "drgnx-gpaste-%s" key) :buffer nil :noquery t :connection-type 'pipe
                       :command (list program "get" "org.gnome.GPaste" key)
                       :filter (lambda (_p s) (setq out (concat out s)))
                       :sentinel (lambda (p _e)
                                   (unless (process-live-p p)
                                     (push (cons key (equal (string-trim out) "true")) answers)
                                     (when (= (length answers) (length keys))
                                       (finish (cl-every #'cdr answers))))))
                    (error nil))
                  procs)))
        (unless (cl-every #'identity procs) (finish nil))))))

(defun drgnx-clipboard--found (manager)
  "Record MANAGER (a symbol or nil) as found and apply `drgnx-clipboard-publish-selection'."
  (setq drgnx-clipboard--state (plist-put (plist-put drgnx-clipboard--state :manager manager) :checked t))
  (drgnx-clipboard--apply-publish))

(defvar drgnx-clipboard--generation 0 "Counts the checks, so a late GPaste answer to an older one is dropped.")
(defvar drgnx-clipboard--graphical-seen nil "Non-nil once a check has run on an X11 or Wayland frame.")

(defun drgnx-clipboard-detect (&optional frame)
  "Look for a clipboard manager that syncs the selection with the clipboard, on FRAME (default: the selected one;
only X11 and Wayland frames are looked at).  Klipper and CopyQ are known at once; GPaste's answer comes within
a second, and the setting follows it.  Never blocks, never prompts."
  (let ((generation (cl-incf drgnx-clipboard--generation)))
    (setq drgnx-clipboard--state nil)
    (if (not (drgnx-clipboard--graphical-p frame))
        (drgnx-clipboard--found nil)
      (setq drgnx-clipboard--graphical-seen t)
      (let ((procs (drgnx-clipboard--process-names)))
        (cond ((drgnx-clipboard--klipper-p procs) (drgnx-clipboard--found 'klipper))
              ((drgnx-clipboard--copyq-p procs) (drgnx-clipboard--found 'copyq))
              (t (drgnx-clipboard--found nil)
                 (drgnx-clipboard--gpaste-ask
                  (lambda (ok)
                    (when (and ok (= generation drgnx-clipboard--generation))
                      (drgnx-clipboard--found 'gpaste))))))))))

(defun drgnx-clipboard--frame-hook (frame)
  "`after-make-frame-functions': the first X11 or Wayland frame (a daemon has none at startup) starts the check."
  (when (and (not drgnx-clipboard--graphical-seen) (drgnx-clipboard--graphical-p frame))
    (drgnx-clipboard-detect frame)))

;;;; Publishing the selection

(defun drgnx-clipboard--apply-publish ()
  "Set `select-active-regions' as `drgnx-clipboard-publish-selection' says (given the manager found)."
  (let* ((manager (plist-get drgnx-clipboard--state :manager))
         (mode drgnx-clipboard-publish-selection)
         (want (cond ((eq mode t) '(t)) ((null mode) '(nil)) (manager '(nil)))))
    (cond (want
           (unless (equal (list select-active-regions) want)
             (unless drgnx-clipboard--saved-regions
               (setq drgnx-clipboard--saved-regions (list select-active-regions)))
             (setq select-active-regions (car want))
             (setq drgnx-clipboard--state (plist-put drgnx-clipboard--state :changed '(select-active-regions)))))
          (drgnx-clipboard--saved-regions        ; the manager is gone: put it back
           (setq select-active-regions (car drgnx-clipboard--saved-regions)
                 drgnx-clipboard--saved-regions nil)
           (setq drgnx-clipboard--state (plist-put drgnx-clipboard--state :changed nil))))))

;;;; Install

(defun drgnx-clipboard-install ()
  "Put the wrappers and the read timeout in place (once); then look for a syncing manager."
  (unless drgnx-clipboard--installed
    (setq drgnx-clipboard--installed t
          drgnx-clipboard--orig-cut (default-value 'interprogram-cut-function)
          drgnx-clipboard--orig-paste (default-value 'interprogram-paste-function))
    (set-default 'interprogram-cut-function #'drgnx-clipboard--cut)
    (set-default 'interprogram-paste-function #'drgnx-clipboard--paste)
    (add-hook 'pre-command-hook #'drgnx-clipboard--new-command)
    (add-hook 'after-make-frame-functions #'drgnx-clipboard--frame-hook)
    (drgnx-clipboard--apply-timeout))
  (drgnx-clipboard-detect))

(defun drgnx-clipboard-uninstall ()
  "Put everything back as it was."
  (when drgnx-clipboard--installed
    (when (eq (default-value 'interprogram-cut-function) #'drgnx-clipboard--cut)
      (set-default 'interprogram-cut-function drgnx-clipboard--orig-cut))
    (when (eq (default-value 'interprogram-paste-function) #'drgnx-clipboard--paste)
      (set-default 'interprogram-paste-function drgnx-clipboard--orig-paste))
    (remove-hook 'pre-command-hook #'drgnx-clipboard--new-command)
    (remove-hook 'after-make-frame-functions #'drgnx-clipboard--frame-hook)
    (drgnx-clipboard--restore-timeout)
    (when drgnx-clipboard--saved-regions
      (setq select-active-regions (car drgnx-clipboard--saved-regions)
            drgnx-clipboard--saved-regions nil))
    (setq drgnx-clipboard--installed nil drgnx-clipboard--orig-cut nil drgnx-clipboard--orig-paste nil
          drgnx-clipboard--state nil drgnx-clipboard--graphical-seen nil)
    (cl-incf drgnx-clipboard--generation)))

;;;; Doctor

(defun drgnx-clipboard-doctor-facts ()
  "What the doctor shows, as a plist, from what the last check found (nothing is run or waited for):
:manager (klipper, copyq, gpaste or nil), :checked, :kills, :read-timeout (seconds in effect, nil: none),
:publish-selection (the setting), :select-active-regions (in effect), :changed (what drgnx changed)."
  (let ((ms (cl-some (lambda (v) (and (boundp v) (symbol-value v))) '(x-selection-timeout pgtk-selection-timeout))))
    (list :manager (plist-get drgnx-clipboard--state :manager)
          :checked (plist-get drgnx-clipboard--state :checked)
          :kills drgnx-clipboard-kills
          :read-timeout (and (numberp ms) (> ms 0) (/ ms 1000.0))
          :publish-selection drgnx-clipboard-publish-selection
          :select-active-regions select-active-regions
          :changed (plist-get drgnx-clipboard--state :changed))))

(defun drgnx-clipboard--problems ()
  "Module doctor: a manager that syncs the selection while `drgnx-clipboard-publish-selection' publishes it."
  (let ((manager (plist-get drgnx-clipboard--state :manager)))
    (when (and manager select-active-regions (eq drgnx-clipboard-publish-selection t))
      (list (format "%s syncs the selection with the clipboard, and drgnx-clipboard-publish-selection is t: every selection becomes a clipboard entry"
                    manager)))))

(drgnx-module-define 'editor/clipboard
                     :doc "Clipboard managers: only copy and cut reach the clipboard, a stuck owner never freezes a paste, selecting does not fill the history."
                     :stage 'startup
                     :setup #'drgnx-clipboard-install
                     :doctor #'drgnx-clipboard--problems)

(provide 'drgnx-clipboard)
;;; drgnx-clipboard.el ends here
