;;; grid-test.el --- tty tier: the tiled grid in terminal frames -*- lexical-binding: t -*-
;; test-class: cond
;; test-pattern: handshake
;; Run under `drgnx-run-ert-batch' (temp HOME and XDG dirs); every test has its own tmux server.  Positions come from
;; the screen (`drgnx-tty-session-find'), never computed from Emacs's idea of the layout.
(require 'ert)
(require 'drgnx-tty-session)

(defconst drgnx-tty-grid-test--six
  '(progn (drgnx-wb-show-sidebar)
          (drgnx-wb-area-show 'panel)
          (drgnx-wb-area-show 'right)
          (select-window (drgnx-wb-editor-window))
          (drgnx-groups-split-right)
          (drgnx-groups-split-down)
          (length (drgnx-grid-tiles)))
  "A form, in the inner Emacs: six tiles (the side bar, the panel, the right dock and three editors); their count.")

(defconst drgnx-tty-grid-test--state
  '(list (length (drgnx-grid-tiles))
         (seq-every-p #'window-live-p (drgnx-grid-tiles nil 'editor))
         (apply #'min (mapcar #'window-total-width (drgnx-grid-tiles nil 'editor)))
         (apply #'min (mapcar #'window-total-height (drgnx-grid-tiles nil 'editor)))
         drgnx-hooks-problems)
  "A form, in the inner Emacs: (TILES EDITORS-LIVE NARROWEST-EDITOR LOWEST-EDITOR PROBLEMS).")

(defun drgnx-tty-grid-test--ready (sess)
  "Wait until SESS's frame shows the workbench and the terminal layout has seen its size."
  (drgnx-tty-session-wait-tab sess nil 20)
  (drgnx-tty-session-wait sess '(frame-parameter nil 'drgnx-tty-layout-size) 10))

(defun drgnx-tty-grid-test--resize (sess size)
  "Resize SESS's terminal to SIZE (\"COLSxLINES\") and wait until the frame has it and the layout has seen it."
  (drgnx-tty-session-resize sess size)
  (let ((cols (string-to-number (car (split-string size "x")))))
    (drgnx-tty-session-wait sess `(and (= (frame-width) ,cols)
                                       (equal (car (frame-parameter nil 'drgnx-tty-layout-size)) ,cols)))
    (drgnx-tty-session-quiet sess)))

(ert-deftest drgnx-tty-grid/80x24-keeps-the-editor ()
  ;; Review Focus 4: six tiles at 120 × 40, then 80 × 24, 30 × 8 and back.  No error on the way; at 80 × 24 every
  ;; editor keeps the grid's least size (`drgnx-grid-min-columns' and -lines); at 30 × 8 the tiles are squeezed, not
  ;; deleted; back at 120 × 40 the six are there
  (drgnx-tty-session-with (s :size "120x40")
    (drgnx-tty-grid-test--ready s)
    (should (= 6 (drgnx-tty-session-eval s drgnx-tty-grid-test--six)))
    (drgnx-tty-grid-test--resize s "80x24")
    (pcase-let ((`(,n ,live ,narrow ,low ,problems) (drgnx-tty-session-eval s drgnx-tty-grid-test--state)))
      (should (= n 6))
      (should live)
      (should (>= narrow (drgnx-tty-session-eval s 'drgnx-grid-min-columns)))
      (should (>= low (drgnx-tty-session-eval s 'drgnx-grid-min-lines)))
      (should-not problems))
    (drgnx-tty-grid-test--resize s "30x8")
    (pcase-let ((`(,n ,live ,_ ,_ ,problems) (drgnx-tty-session-eval s drgnx-tty-grid-test--state)))
      (should (= n 6))
      (should live)
      (should-not problems))
    (drgnx-tty-grid-test--resize s "120x40")
    (pcase-let ((`(,n ,live ,narrow ,low ,problems) (drgnx-tty-session-eval s drgnx-tty-grid-test--state)))
      (should (= n 6))
      (should live)
      (should (>= narrow (drgnx-tty-session-eval s 'drgnx-grid-min-columns)))
      (should (>= low (drgnx-tty-session-eval s 'drgnx-grid-min-lines)))
      (should-not problems))
    (should-not (drgnx-tty-session-eval s '(with-current-buffer "*Messages*"
                                             (save-excursion (goto-char (point-min))
                                                             (re-search-forward "^\\(Error\\|.*error:\\)" nil t)))))))

(ert-deftest drgnx-tty-grid/drag-a-tile-in-a-terminal ()
  ;; the panel's tile, dragged by its grip (SGR mouse reports through tmux) onto the editor's right edge, becomes a
  ;; tile right of the editor, out of its dock
  (drgnx-tty-session-with (s :size "120x40")
    (drgnx-tty-grid-test--ready s)
    (should (drgnx-tty-session-eval s '(progn (drgnx-wb-area-show 'panel)
                                              (setq drgnx-tty-grid-test--editor (drgnx-wb-editor-window))
                                              (and drgnx-grid-mode drgnx-grid-drag (drgnx-wb-area-window 'panel) t))))
    (drgnx-tty-session-quiet s)
    (let* ((panel-top (drgnx-tty-session-eval s '(nth 1 (window-edges (drgnx-wb-area-window 'panel)))))
           ;; the panel's grip: the first ⠿ on its header row or below (the screen's rows count from 1)
           (grip (let ((lines (nthcdr panel-top (split-string (drgnx-tty-session-screen s) "\n"))))
                   (drgnx-tty-session--find-in (mapconcat #'identity lines "\n") (string #x283f))))
           (grip (progn (should grip) (cons (car grip) (+ panel-top (cdr grip)))))
           (edges (drgnx-tty-session-eval s '(window-edges drgnx-tty-grid-test--editor)))
           ;; the editor's right edge, half way down: screen cells count from 1
           (to (cons (nth 2 edges) (1+ (/ (+ (nth 1 edges) (nth 3 edges)) 2)))))
      (drgnx-tty-session-send s (format "\e[<0;%d;%dM" (car grip) (cdr grip)))
      ;; the drag loop reads the next motion only once it tracks the mouse
      (drgnx-tty-session-wait s '(eq track-mouse 'dragging))
      (drgnx-tty-session-send s (format "\e[<32;%d;%dM" (car to) (cdr to)))
      (unless (ignore-errors (drgnx-tty-session-wait s 'drgnx-grid--drag-shown 5))
        (ert-fail (list :motion-not-shown
                        (drgnx-tty-session-eval s '(list track-mouse drgnx-grid--drag-shown unread-command-events
                                                         (recent-keys) xterm-mouse-mode
                                                         (window-edges drgnx-tty-grid-test--editor))))))
      (drgnx-tty-session-wait-screen s "drop:")
      (drgnx-tty-session-send s (format "\e[<0;%d;%dm" (car to) (cdr to))))
    ;; the panel's tab is a tile of its own now (out of the docked area): Problems, right of the editor
    (should (drgnx-tty-session-wait
             s '(let ((p (seq-find (lambda (w) (memq 'problems (window-parameter w 'drgnx-pane-stack)))
                                   (drgnx-grid-tiles nil 'tool))))
                  (and p (not (window-parameter p 'drgnx-tile-dock))
                       (= (nth 0 (window-edges (drgnx-grid--tile-root p)))
                          (nth 2 (window-edges drgnx-tty-grid-test--editor)))))))
    (should-not (drgnx-tty-session-find s "drop:"))))

(ert-deftest drgnx-tty-grid/full-size-and-back ()
  ;; a tile full size, then back: the six tiles again, each where it was (its edges)
  (drgnx-tty-session-with (s :size "120x40")
    (drgnx-tty-grid-test--ready s)
    (should (= 6 (drgnx-tty-session-eval s drgnx-tty-grid-test--six)))
    (let ((before (drgnx-tty-session-eval s '(mapcar (lambda (w) (cons (window-parameter w 'drgnx-tile-id) (window-edges w)))
                                                     (drgnx-grid-tiles)))))
      (drgnx-tty-session-eval s '(progn (drgnx-grid-full-size-toggle (drgnx-wb-editor-window)) t))
      (should (drgnx-tty-session-wait s '(and (drgnx-grid-full-size-p) (= 1 (length (drgnx-grid-tiles))))))
      (drgnx-tty-session-wait-screen s "Full size · 1 of 6")
      (drgnx-tty-session-eval s '(progn (drgnx-grid-full-size-toggle) t))
      (should (drgnx-tty-session-wait s '(not (drgnx-grid-full-size-p))))
      (should (equal (drgnx-tty-session-eval s '(mapcar (lambda (w) (cons (window-parameter w 'drgnx-tile-id) (window-edges w)))
                                                        (drgnx-grid-tiles)))
                     before)))))

(ert-deftest drgnx-tty-grid/the-status-row-in-a-terminal ()
  ;; six tiles: the status bar is the mode line of the editor used last (a terminal has no row of its own for it; the
  ;; other editors' mode lines have the bar's few segments); no tool tile has a mode line
  (drgnx-tty-session-with (s :size "120x40")
    (drgnx-tty-grid-test--ready s)
    (should (= 6 (drgnx-tty-session-eval s drgnx-tty-grid-test--six)))
    (should-not (drgnx-tty-session-eval s '(seq-some (lambda (w) (> (window-mode-line-height w) 0)) (drgnx-grid-tiles nil 'tool))))
    ;; the bar fits its window: a narrow editor's keeps the position and drops the rest
    (let ((full "Ln [0-9]+, Col [0-9]+"))
      (drgnx-tty-session-wait-screen s full)
      (let* ((lines (split-string (drgnx-tty-session-quiet s) "\n"))
             (row (drgnx-tty-session-eval s '(1- (nth 3 (window-edges (drgnx-wb-editor-window)))))))
        (should (string-match-p full (nth row lines)))))))

(ert-deftest drgnx-tty-grid/c-locale-tab-rows-are-ascii ()
  ;; LANG=C: the tiles' tab rows (the grip, the close marks) are ASCII: `::' for the grip, no `?' and no \uXXXX
  (drgnx-tty-session-with (s :size "120x40" :env '("LANG=C" "LC_ALL=C"))
    (drgnx-tty-grid-test--ready s)
    (should (= 6 (drgnx-tty-session-eval s drgnx-tty-grid-test--six)))
    (drgnx-tty-session-wait-screen s " :: ")
    (let ((screen (drgnx-tty-session-quiet s)))
      (should-not (string-match-p "\\\\u[0-9A-F]\\{4\\}" screen))
      (should-not (string-match-p "[?]" screen))
      (should-not (string-match-p "[^[:ascii:]]" screen)))))

(provide 'drgnx-tty-grid-test)
;;; grid-test.el ends here
