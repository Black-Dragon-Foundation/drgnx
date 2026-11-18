;;; switcher-test.el --- batch tests: the tile switcher (Switch Tile) -*- lexical-binding: t -*-
;; test-class: det
;; The model (letters, the neighbour by direction, which tiles get cards) on items made by hand, so items on two
;; windows need no second frame; the keys on the one batch frame, whose tiles get overlay letters (a terminal frame's).
;; Module ui/tiles is set up and torn down; time is the virtual clock (`drgnx-test-advance').
(require 'ert)
(require 'cl-lib)
(require 'seq)
(require 'drgnx)
(load (expand-file-name "test/fixtures/clock-fixture" drgnx-dir) nil t)
(load (expand-file-name "test/fixtures/modules-fixture" drgnx-dir) nil t)
(load (expand-file-name "test/fixtures/grid-fixture" drgnx-dir) nil t)
(require 'drgnx-groups)
(require 'drgnx-switcher)

(defmacro drgnx-switcher-test--with (&rest body)
  "BODY with module ui/tiles, the grid fixture's frame split into three editor tiles and the virtual clock; the
switcher closed after."
  (declare (indent 0))
  `(drgnx-test-with-modules '(core/workbench ui/tiles)
     (drgnx-grid-test--with
       (drgnx-test-with-clock (:allow-pending t)
         (unwind-protect
             (progn
               (drgnx-groups-split-right)
               (drgnx-groups-split-down)
               (select-window (frame-first-window))
               (dolist (w (drgnx-grid-tiles nil 'editor))
                 (set-window-buffer w (get-buffer-create (format "*g-%s*" (drgnx-grid-tile-id w)))))
               ,@body)
           (drgnx-switcher-close))))))

(defun drgnx-switcher-test--item (frame rank l top r b &optional terminal)
  (list :window (intern (format "w-%s-%s-%s" frame l top)) :frame frame :rank rank
        :edges (list l top r b) :terminal terminal :title "t"))

(defun drgnx-switcher-test--letters ()
  "Window → letter of the open switcher's items."
  (mapcar (lambda (it) (cons (plist-get it :window) (plist-get it :letter))) (plist-get drgnx-switcher--state :items)))

(ert-deftest drgnx-switcher/letters-are-stable-for-one-layout ()
  (drgnx-switcher-test--with
    (drgnx-switcher-open)
    (let ((one (drgnx-switcher-test--letters)))
      (should (= 3 (length one)))
      (should (equal (mapcar #'cdr one) '(?a ?s ?d)))
      ;; reading order: the top-left tile first
      (should (eq (car (car one)) (frame-first-window)))
      (drgnx-switcher-close)
      ;; the focus elsewhere does not change them within one window
      (select-window (car (last (drgnx-grid-tiles nil 'editor))))
      (drgnx-switcher-open)
      (should (equal (drgnx-switcher-test--letters) one)))))

(ert-deftest drgnx-switcher/letters-span-frames ()
  ;; the selected window first (rank 0), then the others; reading order inside each
  (let* ((items (list (drgnx-switcher-test--item 'f2 1 0 0 100 100)
                      (drgnx-switcher-test--item 'f1 0 100 0 200 100)
                      (drgnx-switcher-test--item 'f1 0 0 0 100 100)
                      (drgnx-switcher-test--item 'f2 1 0 100 100 200)
                      (drgnx-switcher-test--item 'f1 0 0 100 200 200)))
         (lettered (drgnx-switcher-assign items)))
    (should (equal (mapcar (lambda (it) (list (plist-get it :frame) (plist-get it :letter))) lettered)
                   '((f1 ?a) (f1 ?s) (f1 ?d) (f2 ?f) (f2 ?j))))
    (should (equal (mapcar (lambda (it) (plist-get it :edges)) (seq-take lettered 3))
                   '((0 0 100 100) (100 0 200 100) (0 100 200 200))))))

(ert-deftest drgnx-switcher/early-letter-closes-and-replays ()
  (drgnx-switcher-test--with
    (let ((origin (selected-window)) (unread-command-events nil))
      (drgnx-switcher-open)
      ;; before the pop-in ends: the letter is not a pick
      (should (eq (drgnx-switcher-handle ?s) 'replayed))
      (should-not (drgnx-switcher-open-p))
      (should (eq (selected-window) origin))
      (should (equal unread-command-events '(?s))))))

(ert-deftest drgnx-switcher/other-key-closes-and-replays ()
  (drgnx-switcher-test--with
    (let ((origin (selected-window)) (unread-command-events nil))
      (drgnx-switcher-open)
      (drgnx-test-advance 0.2)
      (should (plist-get drgnx-switcher--state :ready))
      (should (eq (drgnx-switcher-handle ?x) 'replayed))
      (should-not (drgnx-switcher-open-p))
      (should (eq (selected-window) origin))
      (should (equal unread-command-events '(?x)))
      ;; Esc only closes; a letter after the pop-in picks
      (setq unread-command-events nil)
      (drgnx-switcher-open)
      (should (eq (drgnx-switcher-handle 'escape) 'closed))
      (should-not unread-command-events)
      (drgnx-switcher-open)
      (drgnx-test-advance 0.2)
      (let ((target (car (rassq ?d (drgnx-switcher-test--letters)))))
        (should (eq (drgnx-switcher-handle ?d) 'picked))
        (should (eq (selected-window) target))))))

(ert-deftest drgnx-switcher/shift-letter-swaps ()
  (drgnx-switcher-test--with
    (drgnx-switcher-open)
    (drgnx-test-advance 0.2)
    (let* ((letters (drgnx-switcher-test--letters))
           (a (car (rassq ?a letters))) (d (car (rassq ?d letters)))
           (ba (window-buffer a)) (bd (window-buffer d)))
      (should (eq (drgnx-switcher-handle ?D) 'swapped))
      (should-not (drgnx-switcher-open-p))
      (should (eq (window-buffer (drgnx-grid-tile-main (selected-window))) ba))
      (should (memq bd (mapcar #'window-buffer (window-list))))
      (should-not (eq (window-buffer (frame-first-window)) ba)))))

(ert-deftest drgnx-switcher/arrows-cross-to-the-other-frame ()
  ;; two windows side by side on the layout: right from the first's right tile is the second's left tile
  (let* ((a (drgnx-switcher-test--item 'f1 0 0 0 500 400))
         (b (drgnx-switcher-test--item 'f1 0 500 0 1000 400))
         (c (drgnx-switcher-test--item 'f2 1 1000 0 1500 400))
         (d (drgnx-switcher-test--item 'f2 1 1000 400 1500 800))
         (items (list a b c d)))
    (should (eq (drgnx-switcher-neighbour items a 'right) b))
    (should (eq (drgnx-switcher-neighbour items b 'right) c))
    (should (eq (drgnx-switcher-neighbour items c 'down) d))
    (should (eq (drgnx-switcher-neighbour items c 'left) b))
    (should-not (drgnx-switcher-neighbour items c 'right))
    (should-not (drgnx-switcher-neighbour items a 'up))))

(ert-deftest drgnx-switcher/more-than-12-tiles-get-overlays ()
  (let* ((items (cl-loop for i below 14 collect (drgnx-switcher-test--item 'f1 0 (* i 10) 0 (+ (* i 10) (1+ i)) 100)))
         (term (drgnx-switcher-test--item 't1 1 0 0 5000 5000 t))
         (cards (drgnx-switcher-cards (cons term items))))
    (should (= 12 (length cards)))
    ;; the largest twelve; the two smallest and the terminal window's tile get letters at their start
    (should-not (memq (nth 0 items) cards))
    (should-not (memq (nth 1 items) cards))
    (should (memq (nth 13 items) cards))
    (should-not (memq term cards))))

(defun drgnx-switcher-test--key-hints (s)
  "The keys of the kit key hints in string S, in order (their `help-echo' is \"key KEYS\")."
  (let ((i 0) out)
    (while (< i (length s))
      (let ((h (get-text-property i 'help-echo s)) (next (next-single-property-change i 'help-echo s (length s))))
        (when (and (stringp h) (string-prefix-p "key " h)) (push (substring h 4) out))
        (setq i next)))
    (nreverse out)))

(ert-deftest drgnx-switcher/hint-line-is-the-kit ()
  "The echo area's hint line names each letter and the keys (Shift, the arrows, Return, Esc) as kit key hints."
  (drgnx-switcher-test--with
    (let* ((items (drgnx-switcher-open)) (keys (drgnx-switcher-test--key-hints (drgnx-switcher-hint items))))
      (should (string-prefix-p "Switch tile: " (drgnx-switcher-hint items)))
      (dolist (it items) (should (member (string (plist-get it :letter)) keys)))
      (dolist (k '("⇧" "←" "→" "↑" "↓" "↵" "Esc")) (should (member k keys))))))

(ert-deftest drgnx-switcher/captions-name-what-the-tile-holds ()
  "tiling.html's captions: an editor's shown tab and `editor', `(current)' on the tile you are in, `a stack of N' for
an editor of several tabs; a tool tile's kind as its tab shows it, with `a stack of N' when it holds several."
  (drgnx-switcher-test--with
    (let* ((eds (drgnx-grid-tiles nil 'editor)) (two (cadr eds)))
      (set-window-parameter two 'drgnx-tabs (list (window-buffer two) (get-buffer-create "*g-extra*")))
      (drgnx-pane-show 'g-chat)
      (let ((titles (mapcar (lambda (it) (cons (plist-get it :window) (plist-get it :title))) (drgnx-switcher-items))))
        (should (equal (alist-get (car eds) titles) (format "%s · editor (current)" (drgnx-chrome-tab-title (window-buffer (car eds))))))
        (should (equal (alist-get two titles) "a stack of 2 · editor"))
        (should (equal (alist-get (nth 2 eds) titles) (format "%s · editor" (drgnx-chrome-tab-title (window-buffer (nth 2 eds))))))
        (should (equal (alist-get (drgnx-pane-window 'g-chat) titles) "Chat"))))))

(ert-deftest drgnx-switcher/a-tile-of-several-windows-is-measured-whole ()
  "A tile whose windows are one atom (the side bar's sections, the agent panel's windows) is placed by the whole tile's
edges, so its card centres on the tile, not on its first window."
  (drgnx-switcher-test--with
    (drgnx-pane-show 'g-chat)
    (let* ((chat (drgnx-pane-window 'g-chat)))
      (drgnx-grid-add-part chat 'below)
      (let ((it (seq-find (lambda (it) (eq (plist-get it :window) (drgnx-grid-tile-main chat))) (drgnx-switcher-items))))
        (should it)
        (should (equal (plist-get it :local) (window-pixel-edges (window-atom-root chat))))))))

(ert-deftest drgnx-switcher/teardown-deletes-the-pool ()
  ;; batch makes no card (its frame is a terminal's): a pool entry stands in for one; teardown closes the switcher,
  ;; deletes the pool and leaves no timer of the module
  (let ((buf (get-buffer-create " *drgnx-switcher-test*")))
    (drgnx-switcher-test--with
      (drgnx-switcher-open)
      (setq drgnx-switcher--pool (list (cons nil buf)))
      (should (drgnx-timer-active-p '(switcher . ready)))
      (drgnx-tiles--teardown)
      (should-not (drgnx-switcher-open-p))
      (should-not drgnx-switcher--pool)
      (should-not (buffer-live-p buf))
      (should-not (drgnx-timer-active-p '(switcher . ready))))))

(provide 'switcher-test)
;;; switcher-test.el ends here
