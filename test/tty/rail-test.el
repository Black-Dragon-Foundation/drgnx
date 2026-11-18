;;; rail-test.el --- tty tier: the rail's glyphs on a terminal -*- lexical-binding: t -*-
;; test-class: cond
;; test-pattern: handshake
;; Run under `drgnx-run-ert-batch' (temp HOME and XDG dirs); every test has its own tmux server.  A terminal frame's
;; rail is a left side window three columns wide: each place is its icon's glyph between two columns (the glyph's ASCII
;; form on a terminal that is not UTF-8), the current place on the quiet selection's terminal form, a changed place's dot
;; the kit's `dot' glyph after its icon.
(require 'ert)
(require 'drgnx-tty-session)

(defconst drgnx-tty-rail-test--form
  '(let* ((frame (car (seq-filter (lambda (f) (and (frame-live-p f) (frame-parameter f 'client))) (frame-list))))
          (drgnx-pane-backend 'grid) (out nil))
     (with-selected-frame frame
       (drgnx-rail-mode 1)
       (unwind-protect
           (progn
             (drgnx-rail-mark-changed 'changes)
             (drgnx-rail--ensure frame)
             (let ((rail (drgnx-rail-window frame)))
               (list (and rail (window-total-width rail))
                     (and rail (with-current-buffer (window-buffer rail) (buffer-substring-no-properties (point-min) (point-max))))
                     (mapcar (lambda (p) (drgnx-face-glyph (nth 2 p) frame)) drgnx-rail-places)
                     (drgnx-face-glyph 'dot frame))))
         (drgnx-rail-clear-changed 'changes)
         (drgnx-rail-mode -1))))
  "A form, in the inner daemon: the client frame's rail's width and text, the glyphs of the places' icons and the dot.")

(ert-deftest drgnx-tty/rail-glyphs ()
  (drgnx-tty-session-with (s :daemon t)
    (pcase-dolist (`(,env ,ascii) '((("TERM=xterm-256color" "LANG=C.UTF-8") nil) (("TERM=xterm-256color" "LANG=C" "LC_ALL=C") t)))
      (drgnx-tty-session-client s :env env)
      (pcase-let ((`(,width ,text ,icons ,dot) (drgnx-tty-session-eval s drgnx-tty-rail-test--form)))
        (should (= 3 width))
        (should (= 7 (length icons)))
        ;; each place's glyph is in the rail, the changed place's dot too
        (dolist (g icons) (should (string-search g text)))
        (should (string-search dot text))
        (when ascii
          (should (string-match-p "\\`[[:ascii:]\n]*\\'" text)))))))

(provide 'tty-rail-test)
;;; rail-test.el ends here
