;;; drgnx-modal-ui-test.el --- live: Vim keys end to end in a GUI drgnx session (evil from DRGNX_MODAL_ELPA) -*- lexical-binding: t -*-
;; Each test starts a session of config drgnx (the checkout's own init, not the GUI tier's minimal session: evil and
;; drgnx's startup cannot be undone in a shared Emacs), starts evil there and applies a key stack, then presses real
;; keys through the harness queue.  Files are temp dirs; screenshots go to $DRGNX_TEST_SHOTS when set (the UI
;; evidence), else to the run's temp dir.  Without evil the tests skip (docs/develop/harness.md, "Modal tests").
(require 'ert)
(require 'cl-lib)
(require 'drgnx-ui)
(load (expand-file-name "test/fixtures/modal-session" drgnx-ui-repo-dir) nil t)

(defun drgnx-modal-ui-test--project (files)
  "A temp git project holding FILES ((NAME . TEXT)…, NAME may have a folder); its directory, with a slash."
  (let ((dir (file-name-as-directory (make-temp-file "drgnx-modal-ui" t))))
    (pcase-dolist (`(,name . ,text) files)
      (make-directory (file-name-directory (expand-file-name name dir)) t)
      (write-region text nil (expand-file-name name dir) nil 'silent))
    (call-process "git" nil nil nil "-C" dir "init" "-q")
    dir))

(defun drgnx-modal-ui-test--text (sess)
  (drgnx-modal-session-eval sess '(buffer-substring-no-properties (point-min) (point-max))))

(defun drgnx-modal-ui-test--where (sess)
  "The selected window's buffer, its evil state, line and column, in SESS."
  (drgnx-modal-session-eval sess '(list (buffer-name) (bound-and-true-p evil-state) (line-number-at-pos) (current-column))))

(defun drgnx-modal-ui-test--row (sess)
  "The line number and the trimmed text of point's line in the selected window, in SESS."
  (drgnx-modal-session-eval sess '(list (line-number-at-pos) (string-trim (buffer-substring-no-properties (pos-bol) (pos-eol))))))

(defun drgnx-modal-ui-test--prompt-p (sess prefix)
  (let ((p (drgnx-modal-session-prompt sess))) (and p (string-prefix-p prefix p))))

;;;; Editing

(ert-deftest drgnx-ui-modal/edit-like-vim ()
  (drgnx-modal-session-with (sess)
    (let* ((dir (drgnx-modal-ui-test--project '(("edit.txt" . "alpha beta gamma\none two three\nfoo bar\nlast foo line\n"))))
           (file (expand-file-name "edit.txt" dir)))
      (unwind-protect
          (progn
            (drgnx-modal-session-eval sess `(progn (find-file ,file) (goto-char (point-min)) t))
            (should (equal (drgnx-modal-ui-test--where sess) '("edit.txt" normal 1 0)))
            ;; change a word, back to normal
            (drgnx-modal-session-act sess "w" "c i w" '(:type "BETA") "<escape>")
            (should (equal (drgnx-modal-ui-test--text sess) "alpha BETA gamma\none two three\nfoo bar\nlast foo line\n"))
            (should (eq (cadr (drgnx-modal-ui-test--where sess)) 'normal))
            ;; delete a line, put it back below, undo, redo
            (drgnx-modal-session-act sess "d d")
            (should (equal (drgnx-modal-ui-test--text sess) "one two three\nfoo bar\nlast foo line\n"))
            (drgnx-modal-session-act sess "p")
            (should (equal (drgnx-modal-ui-test--text sess) "one two three\nalpha BETA gamma\nfoo bar\nlast foo line\n"))
            (drgnx-modal-session-act sess "u")
            (should (equal (drgnx-modal-ui-test--text sess) "one two three\nfoo bar\nlast foo line\n"))
            (drgnx-modal-session-act sess "C-r")
            (should (equal (drgnx-modal-ui-test--text sess) "one two three\nalpha BETA gamma\nfoo bar\nlast foo line\n"))
            ;; a count, then repeat
            (drgnx-modal-session-act sess "g g" "3 j" "x" ".")
            (should (equal (drgnx-modal-ui-test--text sess) "one two three\nalpha BETA gamma\nfoo bar\nlast foo li\n"))
            ;; record a macro in register a, play it on the next line
            (drgnx-modal-session-act sess "g g" "q a" "A" '(:type "!") "<escape>" "j" "q" "@ a")
            (should (equal (drgnx-modal-ui-test--text sess) "one two three!\nalpha BETA gamma!\nfoo bar\nlast foo li\n"))
            ;; search, next, previous
            (drgnx-modal-session-act sess "g g" "/" '(:type "foo") "RET")
            (should (equal (drgnx-modal-ui-test--where sess) '("edit.txt" normal 3 0)))
            (drgnx-modal-session-act sess "n")
            (should (equal (drgnx-modal-ui-test--where sess) '("edit.txt" normal 4 5)))
            (drgnx-modal-session-act sess "N")
            (should (equal (drgnx-modal-ui-test--where sess) '("edit.txt" normal 3 0)))
            ;; shift two lines right in visual-line state
            (drgnx-modal-session-act sess "g g" "V j >")
            (should (equal (drgnx-modal-ui-test--text sess) "    one two three!\n    alpha BETA gamma!\nfoo bar\nlast foo li\n"))
            ;; insert in front of a block of two lines
            (drgnx-modal-session-act sess "g g" "C-v j I" '(:type "#") "<escape>")
            (should (equal (drgnx-modal-ui-test--text sess) "#    one two three!\n#    alpha BETA gamma!\nfoo bar\nlast foo li\n"))
            ;; an ex substitution on line 3, then :w
            (drgnx-modal-session-act sess "3 G" ":" '(:type "s/a/b/") "RET")
            (should (equal (drgnx-modal-ui-test--text sess) "#    one two three!\n#    alpha BETA gamma!\nfoo bbr\nlast foo li\n"))
            (should (drgnx-modal-session-eval sess '(buffer-modified-p)))
            (drgnx-modal-session-act sess ":" '(:type "w") "RET")
            (should-not (drgnx-modal-session-eval sess '(buffer-modified-p)))
            (should (equal (with-temp-buffer (insert-file-contents file) (buffer-string))
                           "#    one two three!\n#    alpha BETA gamma!\nfoo bbr\nlast foo li\n")))
        (delete-directory dir t)))))

;;;; The leader

(ert-deftest drgnx-ui-modal/leader-everywhere ()
  (drgnx-modal-session-with (sess)
    (let ((dir (drgnx-modal-ui-test--project '(("main.el" . "(message \"hi\")\n") ("notes.txt" . "notes\n")))))
      (unwind-protect
          (progn
            (drgnx-modal-session-eval sess `(progn (find-file ,(expand-file-name "notes.txt" dir))
                                                   (drgnx-explorer-set-roots (list ,dir)) t))
            ;; SPC alone: which-key lists the leader, its prefixes once with which-key's "+"
            (drgnx-modal-session-act sess "SPC")
            (should (drgnx-modal-session-until sess '(and (get-buffer-window " *which-key*") t)))
            (let ((popup (drgnx-modal-session-eval
                          sess '(with-current-buffer " *which-key*" (buffer-substring-no-properties (point-min) (point-max))))))
              (should (string-match-p "f : \\+File" popup))
              (should (string-match-p "SPC : Command Palette" popup))
              (should-not (string-search "++" popup)))
            (drgnx-modal-session-act sess "C-g")
            (should (drgnx-modal-session-until sess '(not (get-buffer-window " *which-key*"))))
            ;; SPC SPC the palette, SPC f p Quick Open, SPC s p project search
            (pcase-dolist (`(,keys . ,prompt) '(("SPC SPC" . "Command") ("SPC f p" . "Find file in")
                                                ("SPC s p" . "Search in project")))
              (drgnx-modal-session-act sess keys)
              (should (drgnx-modal-ui-test--prompt-p sess prompt))
              (drgnx-modal-session-act sess "C-g")
              (should-not (drgnx-modal-session-prompt sess)))
            ;; and from a panel: the Explorer
            (drgnx-modal-session-act sess "SPC E")
            (should (equal (car (drgnx-modal-ui-test--where sess)) " *drgnx explorer*"))
            (drgnx-modal-session-act sess "SPC SPC")
            (should (drgnx-modal-ui-test--prompt-p sess "Command"))
            (drgnx-modal-session-act sess "C-g"))
        (delete-directory dir t)))))

;;;; Panels

(ert-deftest drgnx-ui-modal/panels ()
  (drgnx-modal-session-with (sess)
    (let ((dir (drgnx-modal-ui-test--project '(("a/one.txt" . "one\n") ("b/three.txt" . "three\n") ("b/two.txt" . "two\n")
                                               ("top.txt" . "top\n"))))
          (outside (drgnx-modal-ui-test--project '(("outside.txt" . "outside\n")))))
      (unwind-protect
          (progn
            ;; the editor shows a file outside the Explorer's folder: the Explorer starts on its first row
            (drgnx-modal-session-eval sess `(progn (find-file ,(expand-file-name "outside.txt" outside))
                                                   (drgnx-explorer-set-roots (list ,dir)) t))
            ;; the Explorer: emacs state, no cursor; Escape goes back to the editor; j k l h RET
            (drgnx-modal-session-act sess "SPC E")
            (should (equal (drgnx-modal-session-eval sess '(list (buffer-name) evil-state cursor-type (line-number-at-pos)))
                           '(" *drgnx explorer*" emacs nil 1)))
            (drgnx-modal-session-shot sess "modal-explorer.png")
            (drgnx-modal-session-act sess "<escape>")
            (should (equal (drgnx-modal-ui-test--where sess) '("outside.txt" normal 1 0)))
            (drgnx-modal-session-act sess "SPC E")
            (should (equal (drgnx-modal-session-eval sess '(list (buffer-name) (line-number-at-pos))) '(" *drgnx explorer*" 1)))
            (drgnx-modal-session-act sess "j")
            (should (equal (drgnx-modal-ui-test--row sess) '(2 "▸ a")))
            (drgnx-modal-session-act sess "j")
            (should (equal (drgnx-modal-ui-test--row sess) '(3 "▸ b")))
            (drgnx-modal-session-act sess "l")                              ; expand b
            (should (equal (drgnx-modal-ui-test--row sess) '(3 "▾ b")))
            (drgnx-modal-session-act sess "k")
            (should (equal (drgnx-modal-ui-test--row sess) '(2 "▸ a")))
            (drgnx-modal-session-act sess "h")                              ; a is closed: up to its folder
            (should (equal (car (drgnx-modal-ui-test--row sess)) 1))
            (drgnx-modal-session-act sess "j" "j" "l")                      ; b is open: into it
            (let ((row (drgnx-modal-ui-test--row sess)))
              (should (= (car row) 4))
              (should (string-suffix-p " three.txt" (cadr row))))
            ;; the leader from the Explorer, its popup on screen
            (drgnx-modal-session-act sess "SPC")
            (should (drgnx-modal-session-until sess '(and (get-buffer-window " *which-key*") t)))
            (drgnx-modal-session-shot sess "modal-explorer-leader.png")
            (drgnx-modal-session-act sess "C-g")
            (should (drgnx-modal-session-until sess '(not (get-buffer-window " *which-key*"))))
            (drgnx-modal-session-act sess "RET")
            (should (equal (drgnx-modal-session-eval sess '(list buffer-file-name evil-state))
                           (list (expand-file-name "b/three.txt" dir) 'normal)))
            ;; Buffers: Escape goes back; j RET opens the second row's file
            (drgnx-modal-session-eval sess `(progn (find-file-noselect ,(expand-file-name "top.txt" dir)) t))
            (drgnx-modal-session-act sess "SPC ,")
            (should (equal (drgnx-modal-session-eval sess '(list (buffer-name) evil-state cursor-type))
                           '(" *drgnx buffers*" emacs nil)))
            (drgnx-modal-session-act sess "<escape>")
            (should (equal (drgnx-modal-ui-test--where sess) '("three.txt" normal 1 0)))
            (drgnx-modal-session-act sess "SPC ," "j")
            (let ((row (drgnx-modal-ui-test--row sess)))
              (should (= (car row) 2))
              (drgnx-modal-session-act sess "RET")
              (let ((shown (drgnx-modal-ui-test--where sess)))
                (should (string-search (car shown) (cadr row)))
                (should (eq (cadr shown) 'normal))))
            ;; Work and the Agents list (two rows each) in the right dock: there and back with C-w l and C-w h (Escape is
            ;; Dock Back in the sidebar's docks only, in every key profile)
            (drgnx-modal-session-eval
             sess '(progn (advice-add 'drgnx-work-ui--roots :override
                                      (lambda () (list (list :id "r1" :kind 'ruling :title "First ruling")
                                                       (list :id "r2" :kind 'ruling :title "Second ruling"))))
                          (advice-add 'drgnx-work-ui-refresh :override #'ignore)
                          (setq drgnx-agents--sessions
                                (list (drgnx-agents--make :id "a1" :name "alpha" :status 'idle :conn 'fake :cwd default-directory)
                                      (drgnx-agents--make :id "b1" :name "beta" :status 'idle :conn 'fake :cwd default-directory)))
                          t))
            (pcase-dolist (`(,show . ,buffer) '(("SPC a w" . "*drgnx Work*") ("SPC a v" . "*drgnx Agents*")))
              (let ((editor (drgnx-modal-ui-test--where sess)))
                (drgnx-modal-session-act sess show "C-w l")
                (should (equal (drgnx-modal-session-eval sess '(list (buffer-name) evil-state)) (list buffer 'emacs)))
                (let ((start (car (drgnx-modal-ui-test--row sess))))
                  (drgnx-modal-session-act sess "j")
                  (should (= (car (drgnx-modal-ui-test--row sess)) (1+ start)))
                  (drgnx-modal-session-act sess "k")
                  (should (= (car (drgnx-modal-ui-test--row sess)) start)))
                (drgnx-modal-session-act sess "C-w h")
                (should (equal (drgnx-modal-ui-test--where sess) editor)))))
        (delete-directory dir t)
        (delete-directory outside t)))))

;;;; The indicator and the cursor

(defconst drgnx-modal-ui-test--mode-line
  '(let ((s (format-mode-line mode-line-format nil (selected-window))))
     (list (substring-no-properties s 0 (min 9 (length s))) (get-text-property 1 'face s) cursor-type))
  "The front of the selected window's mode line, the face of its second character, and the cursor type.")

(ert-deftest drgnx-ui-modal/indicator-and-cursor ()
  (drgnx-modal-session-with (sess)
    (let ((dir (drgnx-modal-ui-test--project '(("a.txt" . "hello world\nsecond line\n")))))
      (unwind-protect
          (progn
            (drgnx-modal-session-eval sess `(progn (find-file ,(expand-file-name "a.txt" dir)) t))
            (should (equal (drgnx-modal-session-eval sess drgnx-modal-ui-test--mode-line)
                           '(" NORMAL  " drgnx-modal-normal box)))
            (drgnx-modal-session-shot sess "modal-normal.png")
            (drgnx-modal-session-act sess "i")
            (should (equal (drgnx-modal-session-eval sess drgnx-modal-ui-test--mode-line)
                           '(" INSERT  " drgnx-modal-insert bar)))
            (drgnx-modal-session-act sess "<escape>" "v")
            (should (equal (drgnx-modal-session-eval sess drgnx-modal-ui-test--mode-line)
                           '(" VISUAL  " drgnx-modal-visual hollow)))
            (drgnx-modal-session-act sess "<escape>" "V" "j")
            (should (equal (drgnx-modal-session-eval sess drgnx-modal-ui-test--mode-line)
                           '(" V-LINE  " drgnx-modal-visual hollow)))
            (drgnx-modal-session-shot sess "modal-visual-line.png")
            (drgnx-modal-session-act sess "<escape>")
            ;; the indicator's faces are the theme's mode-line-emphasis, success and warning, under two themes
            (let ((colours
                   (mapcar (lambda (theme)
                             (drgnx-modal-session-eval
                              sess `(progn (mapc #'disable-theme custom-enabled-themes) (load-theme ',theme t)
                                           (mapcar (lambda (p) (list (face-attribute (car p) :foreground nil t)
                                                                     (face-attribute (cdr p) :foreground nil t)))
                                                   '((drgnx-modal-normal . mode-line-emphasis) (drgnx-modal-insert . success)
                                                     (drgnx-modal-visual . warning))))))
                           '(modus-operandi modus-vivendi))))
              (dolist (theme colours)
                (dolist (pair theme)
                  (should (stringp (car pair)))
                  (should (equal (car pair) (cadr pair)))))
              (should-not (equal (car colours) (cadr colours)))))
        (delete-directory dir t)))))

;;;; Inputs take text

(ert-deftest drgnx-ui-modal/inputs-type-text ()
  (drgnx-modal-session-with (sess)
    (let ((dir (drgnx-modal-ui-test--project '(("a.txt" . "text\n")))))
      (unwind-protect
          (progn
            (drgnx-modal-session-eval
             sess `(progn (find-file ,(expand-file-name "a.txt" dir))
                          ;; an agent session to send to; what it is sent is recorded, nothing runs
                          (defvar drgnx-modal-ui-test--sent nil)
                          (advice-add 'drgnx-agents-send :override (lambda (_s text) (setq drgnx-modal-ui-test--sent text)))
                          (setq drgnx-agents--sessions
                                (list (drgnx-agents--make :id "a1" :name "alpha" :status 'idle :conn 'fake :cwd default-directory)))
                          t))
            ;; the palette
            (drgnx-modal-session-act sess "SPC SPC" '(:type "jjk"))
            (should (equal (drgnx-modal-session-eval sess '(minibuffer-contents-no-properties)) "jjk"))
            (drgnx-modal-session-act sess "C-g")
            ;; the agent prompt (Send to Agent…; M-x, since SPC completes a word in the palette's minibuffer)
            (drgnx-modal-session-act sess "M-x" '(:type "drgnx-agents-ui-send") "RET")
            (should (drgnx-modal-ui-test--prompt-p sess "To alpha"))
            (drgnx-modal-session-act sess '(:type "jjk"))
            (should (equal (drgnx-modal-session-eval sess '(minibuffer-contents-no-properties)) "jjk"))
            (drgnx-modal-session-act sess "RET")
            (should (equal (drgnx-modal-session-eval sess 'drgnx-modal-ui-test--sent) "jjk"))
            ;; a terminal
            (drgnx-modal-session-act sess "SPC t n")
            (should (equal (drgnx-modal-session-eval sess '(list major-mode evil-state)) '(eshell-mode insert)))
            (drgnx-modal-session-act sess '(:type "jjk"))
            (should (string-suffix-p " jjk" (drgnx-modal-ui-test--text sess))))
        (delete-directory dir t)))))

;;;; Vim editing with VS Code's app keys

(ert-deftest drgnx-ui-modal/mixed-stack ()
  (drgnx-modal-session-with (sess :layers '((vscode app window) (vim editing)))
    (let ((dir (drgnx-modal-ui-test--project '(("a.txt" . "first\nsecond\n")))))
      (unwind-protect
          (progn
            (drgnx-modal-session-eval sess `(progn (find-file ,(expand-file-name "a.txt" dir)) (goto-char (point-min)) t))
            ;; C-o in normal state: jump back
            (drgnx-modal-session-act sess "G")
            (should (equal (drgnx-modal-ui-test--where sess) '("a.txt" normal 3 0)))
            (drgnx-modal-session-act sess "C-o")
            (should (equal (drgnx-modal-ui-test--where sess) '("a.txt" normal 1 0)))
            (should-not (drgnx-modal-session-prompt sess))
            ;; C-o in insert state: VS Code's Open File
            (drgnx-modal-session-act sess "i" "C-o")
            (should (drgnx-modal-ui-test--prompt-p sess "Find file"))
            (drgnx-modal-session-act sess "C-g" "<escape>")
            ;; the key sheet names the per-state conflict
            (drgnx-modal-session-act sess "SPC ?")
            (should (string-search "C-o Jump Back (vim; normal, visual, motion state) over Open File… (vscode)"
                                   (drgnx-modal-session-eval
                                    sess '(with-current-buffer "*drgnx keys*" (buffer-substring-no-properties (point-min) (point-max)))))))
        (delete-directory dir t)))))

;;; drgnx-modal-ui-test.el ends here
