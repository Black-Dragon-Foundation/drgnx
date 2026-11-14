;;; agents-editor-place-fixture.el --- the positions the hub puts on a buffer frame -*- lexical-binding: t -*-
;; The hub's `editor::marks::place' gives a frame's agents and gutter ranges the positions of their lines in the
;; buffer text (`:pos', `:line_pos', `:end_pos' on an agent, `:start_pos', `:end_pos' on a range) and each agent its
;; `:symbol'.  A test that feeds frames the hub did not build puts the same positions on them with this, over the
;; buffer it feeds; the arithmetic itself is pinned by the hub's Rust tests.
(require 'cl-lib)

(defun drgnx-test-editor-line-start (buf line)
  "The position LINE (1-based, the last line for one past it) of BUF starts at."
  (with-current-buffer buf
    (save-excursion (goto-char (point-min)) (forward-line (1- (max 1 line))) (line-beginning-position))))

(defun drgnx-test-editor-place (buf agents gutter &optional symbol)
  "(AGENTS . GUTTER) with the hub's positions over BUF; SYMBOL (a function of the line) names each agent's symbol."
  (with-current-buffer buf
    (save-excursion
      (let ((place-agent
             (lambda (a)
               (let ((line (plist-get a :line)))
                 (if (null line) a
                   (let* ((end (or (plist-get a :line_end) line))
                          (pos (progn (goto-char (point-min)) (forward-line (1- end))
                                      (min (+ (line-beginning-position) (or (plist-get a :col) 0)) (line-end-position)))))
                     (append a (list :pos pos :line_pos (drgnx-test-editor-line-start buf line)
                                     :end_pos (drgnx-test-editor-line-start buf end))
                             (and symbol (not (plist-get a :projected)) (list :symbol (funcall symbol line)))))))))
            (place-range
             (lambda (g)
               (append g (list :start_pos (drgnx-test-editor-line-start buf (plist-get g :start))
                               :end_pos (drgnx-test-editor-line-start buf (or (plist-get g :end) (plist-get g :start))))))))
        (cons (mapcar place-agent agents) (mapcar place-range gutter))))))

(provide 'agents-editor-place-fixture)
;;; agents-editor-place-fixture.el ends here
