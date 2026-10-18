;;; tty-onboard-test.el --- batch tests: the onboarding daemon step names good terminals and recommends one -*- lexical-binding: t -*-
;; Nothing touches the machine: config, state and data are temp dirs, PATH is empty (no capable terminal installed),
;; the system is a fixture os-release, and every program run is recorded.  A terminal frame is the batch frame with
;; the terminal parameter `drgnx-tty-caps' that drgnx sets when a terminal opens (never asked here).
(require 'ert)
(require 'cl-lib)
(require 'drgnx-onboard)
(require 'drgnx-tty)
(require 'drgnx-tty-recommend)

(defconst tty-onboard-test--root
  (expand-file-name "../../" (file-name-directory (or load-file-name buffer-file-name))))

(defun tty-onboard-test--fedora-45 ()
  (let ((system-type 'gnu/linux))
    (drgnx-tty-os (expand-file-name "test/fixtures/os-release/fedora-45" tty-onboard-test--root))))

(defmacro tty-onboard-test--daemon-step (caps &rest body)
  "BODY with the daemon step's message in `message' and the programs run in `programs'; the selected frame a terminal
frame with CAPS (nil: none known).  Linux, Fedora 45, no installed terminal, nothing asked, nothing installed."
  (declare (indent 1))
  `(let* ((root (file-name-as-directory (make-temp-file "drgnx-tty-onboard" t)))
          (process-environment (append (list (concat "DRGNX_CONFIG_DIR=" root "config") (concat "XDG_STATE_HOME=" root "state")
                                             (concat "DRGNX_DATA_DIR=" root "data") (concat "PATH=" root "bin")
                                             "DISPLAY=" "WAYLAND_DISPLAY=" "SSH_CONNECTION=" "SSH_TTY=")
                                       process-environment))
          (exec-path (list (concat root "bin")))
          (drgnx-modules--state nil) (programs nil) (caps ,caps) message
          (call-process (symbol-function 'call-process)) (fedora (tty-onboard-test--fedora-45)))
     (make-directory (concat root "config") t)
     (unwind-protect
         (cl-letf (((symbol-function 'drgnx-platform) (lambda () 'linux))
                   ((symbol-function 'drgnx-tty-os) (lambda (&rest _) fedora))
                   ((symbol-function 'call-process)
                    (lambda (program &rest args) (push program programs) (apply call-process program args)))
                   ((symbol-function 'start-process) (lambda (&rest args) (push (nth 2 args) programs) nil))
                   ((symbol-function 'y-or-n-p) (lambda (&rest _) (error "Asked")))
                   ((symbol-function 'yes-or-no-p) (lambda (&rest _) (error "Asked"))))
           (set-terminal-parameter nil 'drgnx-tty-caps caps)
           (unwind-protect
               (progn (setq message (nth 2 (car (drgnx-onboard-run :only '(daemon) :non-interactive t))))
                      ,@body)
             (set-terminal-parameter nil 'drgnx-tty-caps nil)))
       (delete-directory root t))))

(ert-deftest drgnx-onboard/the-daemon-step-names-good-terminals ()
  ;; no terminal frame: the paragraph of the terminals drgnx works best in, after the step's own result
  (tty-onboard-test--daemon-step nil
    (should (string-search "drgnx works best in" message))
    (should (string-search "WezTerm" message))
    (should (string-search (drgnx-tty-onboard-note) message))
    (should (string-search "keeps running in the background" message))
    ;; the terminal part ends where the desktop part (the window manager, M12c) begins
    (should (string-search (concat (drgnx-tty-onboard-note) "; desktop: ") message))
    (should-not (string-search "cannot send C-S- chords and the like" message))))

(ert-deftest drgnx-onboard/run-in-a-terminal-shows-its-row ()
  ;; a kitty: its row (what works, what it keeps), and no recommendation, as it sends every key
  (tty-onboard-test--daemon-step '(:id kitty :keys kkp :c-g waits :folded nil :osc52 t :colors 16777216 :mouse t)
    (should (string-search (drgnx-tty-onboard-note 'kitty) message))
    (should (string-search "keeps 62 shortcuts for itself" message))
    (should-not (string-search "sudo dnf install" message))
    (should-not (string-search "cannot send C-S- chords and the like" message))))

(ert-deftest drgnx-onboard/a-limited-terminal-gets-the-recommendation ()
  ;; a VTE (Ptyxis, GNOME Terminal) on Fedora 45: its row, then what to install; nothing is installed
  (tty-onboard-test--daemon-step '(:id vte :keys legacy :c-g always :folded nil :osc52 nil :colors 256 :mouse t)
    (should (string-search (drgnx-tty-onboard-note 'vte) message))
    (should (string-search "This terminal cannot send C-S- chords and the like." message))
    ;; the recommender's first two choices on Fedora (xterm, foot); kitty is the one onboarding names in its paragraph
    (should (string-search "sudo dnf install foot" message))
    (should (string-search (concat (plist-get (drgnx-tty-recommendation '(:keys legacy) (tty-onboard-test--fedora-45)) :text)
                                   "; desktop: ")
                           message))
    (should-not (seq-intersection programs '("dnf" "sudo" "rpm-ostree" "apt" "pacman" "brew")))
    (should-not (seq-find (lambda (p) (and (stringp p) (string-match-p "dnf\\|install" p))) programs))))

(provide 'tty-onboard-test)
;;; tty-onboard-test.el ends here
