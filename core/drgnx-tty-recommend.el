;;; drgnx-tty-recommend.el --- Terminals: recommend one that sends every key -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; For a terminal window that cannot send C-S- chords (a legacy terminal), say which terminal would: the capable
;; ones already installed first, else the exact install command for this system (or the download page).  Read
;; only: nothing here runs an installer, `sudo', a package manager or a terminal; it looks at PATH and, on
;; macOS, at the application folders, and reads /etc/os-release.  So it is safe in batch and never blocks.
;;
;; - `drgnx-tty-capable-terminals': the terminals, best first.  modifyOtherKeys ones come first, because
;;   there C-g keeps stopping busy Lisp; under the kitty keyboard protocol (kitty, foot) the terminal sends C-g
;;   as an escape sequence, which Emacs reads only between commands.
;; - `drgnx-tty-os', `drgnx-tty-install-command', `drgnx-tty-installed-capable', `drgnx-tty-recommendation'.
;; - `drgnx-tty-open-in' and `drgnx-tty-capable-terminal-argv': an opt-in way to let `drgnx -t' open in one.
;; See docs/guide/terminal.md.

;;; Code:
(require 'seq)
(require 'subr-x)
(require 'drgnx-paths)
(require 'drgnx-tty)
(require 'drgnx-tty-fallback)

(defconst drgnx-tty--capable-entries
  '((wezterm :name "WezTerm" :binary "wezterm" :argv ("start" "--") :display any
             :arch "wezterm" :cask "wezterm" :mac-app "WezTerm.app" :url "https://wezterm.org/installation.html")
    (ghostty :name "Ghostty" :binary "ghostty" :argv ("-e") :display any :mac-open t
             :arch "ghostty" :cask "ghostty" :mac-app "Ghostty.app" :url "https://ghostty.org/docs/install/binary")
    (xterm :name "xterm" :binary "xterm" :argv ("-e") :display x11
           :dnf "xterm" :apt "xterm" :arch "xterm" :url "https://invisible-island.net/xterm/")
    (foot :name "foot" :binary "foot" :argv nil :display wayland
          :dnf "foot" :apt "foot" :arch "foot" :url "https://codeberg.org/dnkl/foot")
    (kitty :name "kitty" :binary "kitty" :argv ("--") :display any
           :dnf "kitty" :apt "kitty" :arch "kitty" :cask "kitty" :mac-app "kitty.app"
           :url "https://sw.kovidgoyal.net/kitty/binary/")
    (alacritty :name "Alacritty" :binary "alacritty" :argv ("-e") :display any
               :dnf "alacritty" :apt "alacritty" :arch "alacritty" :cask "alacritty" :mac-app "Alacritty.app"
               :url "https://alacritty.org/"))
  "The terminals that can send every key: (ID . PLIST), in no order
\(`drgnx-tty-capable-terminals' orders them).
PLIST: :name; :binary and :argv (what follows it to run a command in the terminal); :display (`any', `x11' or
`wayland': the display it needs on Linux); :dnf, :apt, :arch the package names, :cask the Homebrew cask and
:mac-app the application bundle (a key is absent where there is none); :mac-open non-nil when the terminal's
command line cannot start its window on macOS, so it is started with `open -na APP --args' (Ghostty says so in its
own help; WezTerm's and kitty's bundled commands do start the window, and Alacritty's binary is run directly);
:url the download page.

On image-based Fedora the Fedora packages go through `rpm-ostree install' (the same packages as dnf, so the same
index check); WezTerm and foot have Flatpaks on Flathub, but a Flatpak terminal runs its shell inside the
sandbox, where drgnx and emacsclient are not, so they are not suggested; kitty and Ghostty have none.

Package names were checked against the distributions' indexes on 2026-10-18: Arch (extra) has kitty, foot, ghostty,
wezterm, xterm and alacritty; Fedora 44 has kitty, foot, xterm and alacritty; Debian 13 and Ubuntu 26.04 have kitty,
foot, xterm and alacritty; Homebrew has the casks kitty, ghostty, wezterm and alacritty.
The RHEL clones (Rocky, Alma) have kitty only in EPEL, which is not on by default,
and Amazon Linux has none: both get the download pages.")

(defconst drgnx-tty-capable-terminals
  (delq nil (mapcar (lambda (id) (assq id drgnx-tty--capable-entries)) drgnx-tty-best-order))
  "The entries of `drgnx-tty--capable-entries' in the order of `drgnx-tty-best-order' (best first).")

;;;; Which system

(defconst drgnx-tty--os-release-files '("/etc/os-release" "/usr/lib/os-release")
  "Where Linux keeps its identity, in the order of the os-release specification.")

(defconst drgnx-tty-ostree-file "/run/ostree-booted"
  "Exists on an image-based system (Fedora Silverblue, Kinoite, Bazzite…): the system is read-only, dnf cannot
install, `rpm-ostree' layers a package instead.")

(defun drgnx-tty--os-field (key)
  "The value of KEY= in the current buffer (an os-release file), unquoted, or nil."
  (goto-char (point-min))
  (when (re-search-forward (format "^%s=\\(.*\\)$" key) nil t)
    (let ((value (string-trim (match-string 1) "[\"' \t]+" "[\"' \t]+")))
      (and (not (string-empty-p value)) value))))

(defun drgnx-tty-os (&optional os-release-file)
  "Which system this is: (:system `linux' or `macos' :ostree BOOL :ids (ID ID_LIKE…)).
:ostree is non-nil on an image-based Linux (`drgnx-tty-ostree-file' exists).
The ids come from OS-RELEASE-FILE (default /etc/os-release, else /usr/lib/os-release), lower case, nil on macOS
or when there is no readable file."
  (let ((system (drgnx-platform)))
    (list :system system
          :ostree (and (eq system 'linux) (file-exists-p drgnx-tty-ostree-file) t)
          :ids (when-let* (((eq system 'linux))
                           (file (or os-release-file (seq-find #'file-readable-p drgnx-tty--os-release-files)))
                           ((file-readable-p file)))
                 (with-temp-buffer
                   (insert-file-contents file nil 0 8192)
                   (delete-dups
                    (mapcar #'downcase
                            (delq nil (cons (drgnx-tty--os-field "ID")
                                            (split-string (or (drgnx-tty--os-field "ID_LIKE") "")))))))))))

(defun drgnx-tty--family (os)
  "The package-manager family of OS (from `drgnx-tty-os'): `macos', `fedora', `debian', `arch', or nil."
  (let ((ids (plist-get os :ids)))
    (cond ((eq (plist-get os :system) 'macos) 'macos)
          ;; RHEL clones list fedora in ID_LIKE but are not Fedora; Amazon Linux likewise (see the defconst)
          ((member (car ids) '("rhel" "centos" "rocky" "almalinux" "ol" "amzn")) nil)
          (t (seq-some (lambda (id)
                         (pcase id ("fedora" 'fedora) ("arch" 'arch) ((or "debian" "ubuntu") 'debian)))
                       ids)))))

(defun drgnx-tty-install-command (terminal os)
  "The exact command that installs TERMINAL (a symbol of `drgnx-tty-capable-terminals') on OS, or its download
page when the system's packages do not have it, or nil when there is no such terminal for OS (foot on macOS).
Never runs it."
  (when-let* ((entry (alist-get terminal drgnx-tty-capable-terminals)))
    (let* ((family (drgnx-tty--family os))
           (pkg (lambda (key) (plist-get entry key))))
      (pcase family
        ('macos (when-let* ((cask (funcall pkg :cask))) (concat "brew install --cask " cask)))
        ('fedora (if-let* ((p (funcall pkg :dnf)))
                     ;; image-based: `rpm-ostree install' layers the package (it asks for a restart)
                     (concat (if (plist-get os :ostree) "rpm-ostree install " "sudo dnf install ") p)
                   (funcall pkg :url)))
        ('debian (if-let* ((p (funcall pkg :apt))) (concat "sudo apt install " p) (funcall pkg :url)))
        ('arch (if-let* ((p (funcall pkg :arch))) (concat "sudo pacman -S " p) (funcall pkg :url)))
        (_ (funcall pkg :url))))))

;;;; Which are installed

(defcustom drgnx-tty-mac-app-dirs '("/Applications" "~/Applications")
  "The folders drgnx looks in for the capable terminals' macOS applications (on top of PATH)."
  :type '(repeat directory) :group 'drgnx)

(defun drgnx-tty--executable (terminal)
  "The file that runs TERMINAL: on PATH, else (macOS) inside its application bundle; nil when not installed."
  (when-let* ((entry (alist-get terminal drgnx-tty-capable-terminals))
              (binary (plist-get entry :binary)))
    (or (executable-find binary)
        (when-let* (((eq (drgnx-platform) 'macos))
                    (app (plist-get entry :mac-app)))
          (seq-some (lambda (dir)
                      (let ((file (expand-file-name (concat app "/Contents/MacOS/" binary) dir)))
                        (and (file-executable-p file) (not (file-directory-p file)) file)))
                    drgnx-tty-mac-app-dirs)))))

(defun drgnx-tty-installed-capable ()
  "The capable terminals installed here, in the order of `drgnx-tty-capable-terminals'."
  (seq-filter #'drgnx-tty--executable (mapcar #'car drgnx-tty-capable-terminals)))

;;;; The recommendation

(defun drgnx-tty--name (terminal)
  (plist-get (alist-get terminal drgnx-tty-capable-terminals) :name))

(defun drgnx-tty--keeps-c-g-p (terminal)
  "Non-nil when TERMINAL has modifyOtherKeys (so C-g stops busy Lisp), by its row in `drgnx-tty-terminals'."
  (plist-get (drgnx-tty-terminal terminal) :mok))

(defun drgnx-tty-terminal-caveat (terminal)
  "What TERMINAL lacks that the others have, from its row in `drgnx-tty-terminals', as one phrase such as
\"xterm: no clipboard copy over SSH, 256 colours\", or nil when it lacks nothing."
  (let* ((row (drgnx-tty-terminal terminal))
         (lacks (delq nil (list (and row (not (plist-get row :osc52)) "no clipboard copy over SSH")
                                (and row (not (plist-get row :truecolor)) "256 colours")))))
    (when lacks (format "%s: %s" (drgnx-tty--name terminal) (string-join lacks ", ")))))

(defun drgnx-tty--fallback-hint ()
  "The sentence that says how to type the keys a legacy terminal cannot send, from the fallback layer's rules
\(core/drgnx-tty-fallback.el): Alt+Shift where it is free, `drgnx-tty-chord-prefix' then the key always, and
Ctrl+Shift+P, whose Alt+Shift+P a terminal's replies start with, through the prefix."
  (format "Until then: Alt+Shift or %s then the key (%s for Ctrl+Shift+P)."
          (drgnx-tty-fallback-label drgnx-tty-chord-prefix)
          (drgnx-tty-fallback-label (drgnx-tty-fallback--prefix-of (aref (key-parse "C-S-p") 0) drgnx-tty-chord-prefix))))

(defun drgnx-tty--install-choices (os)
  "The first two terminals to install on OS, as ((TERMINAL . COMMAND)…): those with a package command first,
in the order of `drgnx-tty-capable-terminals', then download pages."
  (let* ((all (delq nil (mapcar (lambda (entry)
                                  (when-let* ((cmd (drgnx-tty-install-command (car entry) os)))
                                    (cons (car entry) cmd)))
                                drgnx-tty-capable-terminals)))
         (packages (seq-remove (lambda (choice) (string-prefix-p "https://" (cdr choice))) all)))
    (seq-take (append packages (seq-remove (lambda (choice) (memq choice packages)) all)) 2)))

(defun drgnx-tty-recommendation (caps os)
  "What to tell a terminal window with CAPS (`drgnx-tty-frame-caps') on system OS (`drgnx-tty-os').
Nil when the terminal sends every key (`:keys' is `kkp' or `mok'); else
\(:installed TERMINALS :install ((TERMINAL . COMMAND)…) :text STRING).  Installed capable terminals come first;
only when there is none, the first two install commands.  Read-only."
  (unless (memq (plist-get caps :keys) '(kkp mok))
    (let* ((installed (drgnx-tty-installed-capable))
           (install (unless installed (drgnx-tty--install-choices os)))
           (lines
            (if installed
                (mapcar (lambda (term)
                          (format "%s is installed: run drgnx -t from %s.%s%s" (drgnx-tty--name term) (drgnx-tty--name term)
                                  (if (drgnx-tty--keeps-c-g-p term) ""
                                    " It works, but C-g cannot stop busy Lisp there.")
                                  (if-let* ((caveat (drgnx-tty-terminal-caveat term))) (concat " " caveat ".") "")))
                        installed)
              (cons (concat "To get every key, install a terminal that sends them (drgnx never installs one for you): "
                            (mapconcat (lambda (choice) (format "%s: %s" (drgnx-tty--name (car choice)) (cdr choice)))
                                       install "; ")
                            ".")
                    (delq nil (mapcar (lambda (choice)
                                        (when-let* ((caveat (drgnx-tty-terminal-caveat (car choice)))) (concat caveat ".")))
                                      install))))))
      (list :installed installed :install install
            :text (string-join (append (list "This terminal cannot send C-S- chords and the like.") lines
                                       (and (seq-some (lambda (choice) (string-prefix-p "rpm-ostree" (cdr choice))) install)
                                            (list "(rpm-ostree layers the package: restart to use it.)"))
                                       (list (drgnx-tty--fallback-hint)))
                               " ")))))

;;;; Opening drgnx -t in a capable terminal

(defcustom drgnx-tty-open-in nil
  "Let `drgnx -t' open in a terminal that sends every key.
Nil: off, `drgnx -t' runs in the terminal you ran it in.  `auto': the first installed terminal of
`drgnx-tty-capable-terminals' that fits your display.  Or one terminal's name (wezterm, ghostty, xterm, foot,
kitty, alacritty).  Never used over SSH or without a display."
  :type '(choice (const :tag "Off" nil) (const :tag "The first installed" auto)
                 (symbol :tag "A terminal"))
  :group 'drgnx)

(defun drgnx-tty--env-set-p (name)
  (not (string-empty-p (or (getenv name) ""))))

(defun drgnx-tty--display-fits-p (kind)
  "Non-nil when a display of KIND (`any', `x11' or `wayland') is reachable from here."
  (or (eq (drgnx-platform) 'macos)
      (pcase kind
        ('wayland (drgnx-tty--env-set-p "WAYLAND_DISPLAY"))
        ('x11 (drgnx-tty--env-set-p "DISPLAY"))
        (_ (or (drgnx-tty--env-set-p "WAYLAND_DISPLAY") (drgnx-tty--env-set-p "DISPLAY"))))))

(defun drgnx-tty--argv (terminal file)
  "The argv prefix that runs a command in TERMINAL, whose executable is FILE."
  (let ((entry (alist-get terminal drgnx-tty-capable-terminals)))
    (if (and (plist-get entry :mac-open) (eq (drgnx-platform) 'macos))
        ;; the command line cannot start the window: ask macOS to open the application (it does not wait)
        (append (list (or (executable-find "open") "/usr/bin/open") "-na"
                      (if (string-match "\\`\\(.*\\.app\\)/Contents/" file) (match-string 1 file) (plist-get entry :mac-app))
                      "--args")
                (plist-get entry :argv))
      (cons file (plist-get entry :argv)))))

(defun drgnx-tty--choice ()
  "The terminal `drgnx-tty-open-in' picks, as (ID . ARGV), or nil: when it is off, when no such terminal is
installed or fits the display, over SSH, or with no display."
  (unless (or (null drgnx-tty-open-in)
              (drgnx-tty--env-set-p "SSH_CONNECTION") (drgnx-tty--env-set-p "SSH_TTY"))
    (seq-some (lambda (terminal)
                (when-let* ((entry (alist-get terminal drgnx-tty-capable-terminals))
                            ((drgnx-tty--display-fits-p (plist-get entry :display)))
                            (file (drgnx-tty--executable terminal)))
                  (cons terminal (drgnx-tty--argv terminal file))))
              (if (eq drgnx-tty-open-in 'auto)
                  (mapcar #'car drgnx-tty-capable-terminals)
                (list drgnx-tty-open-in)))))

(defun drgnx-tty-capable-terminal ()
  "The id of the terminal `drgnx-tty-capable-terminal-argv' runs, or nil.  Say its `drgnx-tty-terminal-caveat'
when it has one (xterm)."
  (car (drgnx-tty--choice)))

(defun drgnx-tty-capable-terminal-argv ()
  "The argv prefix that runs a command in a capable terminal, per `drgnx-tty-open-in', or nil: when it is off,
when no such terminal is installed or fits the display, over SSH, or with no display.  Append the command.
On macOS, Ghostty is started with `open -na APP --args -e', which returns at once and does not wait for the
command."
  (cdr (drgnx-tty--choice)))

(provide 'drgnx-tty-recommend)
;;; drgnx-tty-recommend.el ends here
