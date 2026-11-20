;;; minimap-tty-test.el --- tty tier: the scroll bar as a margin column on a terminal -*- lexical-binding: t -*-
;; test-class: cond
;; test-pattern: handshake
;; Run under `drgnx-run-ert-batch' (temp HOME and XDG dirs); every test has its own tmux server.  On a terminal the
;; scroll bar (design §7.8, stage T) is one column: drgnx gives each window with the strip a one-column right margin,
;; and Nidhogg's C fills that margin's last column in the desired matrix from the ruler's vector, `┃' over the rows the
;; window shows, `│' elsewhere, `▐' where a mark falls; a scroll moves the thumb with no Lisp of the scroll bar's.
(require 'ert)
(require 'drgnx-tty-session)

(defconst drgnx-tty-minimap-test--setup
  '(progn
     (defvar drgnx-tty-minimap--calls 0)
     (defun drgnx-tty-minimap--count (&rest _) (setq drgnx-tty-minimap--calls (1+ drgnx-tty-minimap--calls)))
     (let ((b (get-buffer-create "long.txt")))
       (with-current-buffer b
         (erase-buffer)
         (dotimes (i 2000) (insert (format "line %d\n" (1+ i))))
         (goto-char (point-min))
         (text-mode)
         ;; one error mark at line 1500 (three quarters down)
         (drgnx-ruler-source 'tty-test (lambda () (list (list (save-excursion (goto-char (point-min)) (forward-line 1499) (point))
                                                              'right 'drgnx-marks-error 10)))))
       (delete-other-windows)
       (switch-to-buffer b)
       (drgnx-scrollbar-mode 1)
       (drgnx-ruler--place (selected-window))
       (list (window-margins) (and (window-parameter nil 'glitnir-ruler) t))))
  "A form, in the inner Emacs: a 2,000-line buffer with an error mark at line 1500 alone in the frame, the scroll bar
on; its window's margins and whether it has the strip.")

(defun drgnx-tty-minimap-test--column (screen)
  "The last character of each of SCREEN's rows of the buffer's text (\"line N\"), top to bottom, as a string."
  (mapconcat (lambda (l) (substring (string-trim-right l) -1))
             (seq-filter (lambda (l) (string-match-p "\\bline [0-9]+ " l)) (split-string screen "\n")) ""))

(ert-deftest drgnx-tty-minimap/the-scroll-bar-is-a-margin-column-with-its-marks ()
  "In `emacs -nw' the strip is the right margin's column: the thumb `┃' over the rows shown at the top, `│' below,
and the error mark `▐' three quarters down."
  (drgnx-tty-session-with (s :size "100x30")
    (drgnx-tty-session-wait-tab s nil 20)
    (skip-unless (drgnx-tty-session-eval s '(featurep 'glitnir-ruler)))
    (pcase-let ((`(,margins ,strip) (drgnx-tty-session-eval s drgnx-tty-minimap-test--setup)))
      (should strip)
      (should (equal 1 (cdr margins))))
    (drgnx-tty-session-wait-screen s "line 1 *┃" 10)
    (let ((col (drgnx-tty-minimap-test--column (drgnx-tty-session-screen s))))
      (should (string-match-p "\\`[^│▐]*┃" col))           ; the thumb at the top
      (should (string-match-p "┃│+▐│*" col))))) ; then the rail, the mark three quarters down

(ert-deftest drgnx-tty-minimap/a-scroll-moves-the-thumb-with-no-lisp ()
  "Paging down moves the thumb down the column, and no function of the scroll bar's runs for it (a counter on the
placing, the spec and Glitnir's resolve)."
  (drgnx-tty-session-with (s :size "100x30")
    (drgnx-tty-session-wait-tab s nil 20)
    (skip-unless (drgnx-tty-session-eval s '(featurep 'glitnir-ruler)))
    (drgnx-tty-session-eval s drgnx-tty-minimap-test--setup)
    (drgnx-tty-session-wait-screen s "line 1 *┃" 10)
    (drgnx-tty-session-eval s '(progn (setq drgnx-tty-minimap--calls 0)
                                      (dolist (f '(drgnx-ruler--place drgnx-ruler--show drgnx-ruler--spec glitnir--ruler-vector))
                                        (advice-add f :before #'drgnx-tty-minimap--count))
                                      t))
    (dotimes (_ 20) (drgnx-tty-session-tmux s "send-keys" "-t" (plist-get s :target) "PageDown"))
    (drgnx-tty-session-wait s '(> (line-number-at-pos (window-start)) 300) 10)
    (drgnx-tty-session-wait-screen s "line [3-9][0-9][0-9] " 10)
    (let ((col (drgnx-tty-minimap-test--column (drgnx-tty-session-screen s))))
      (should (string-match-p "\\`│+┃" col)))               ; the thumb has left the top
    (should (= 0 (drgnx-tty-session-eval s '(prog1 drgnx-tty-minimap--calls
                                              (dolist (f '(drgnx-ruler--place drgnx-ruler--show drgnx-ruler--spec glitnir--ruler-vector))
                                                (advice-remove f #'drgnx-tty-minimap--count))))))))

(provide 'tty-minimap-test)
;;; minimap-tty-test.el ends here
