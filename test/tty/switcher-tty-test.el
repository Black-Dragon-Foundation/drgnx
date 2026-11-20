;;; switcher-tty-test.el --- tty tier: the tile switcher in a terminal window -*- lexical-binding: t -*-
;; test-class: cond
;; test-pattern: handshake
;; Run under `drgnx-run-ert-batch' (temp HOME and XDG dirs); every test has its own tmux server.  A terminal window
;; gets no cards: every tile's letter is in inverse video at its window's start, and a key that is not a letter closes.
(require 'ert)
(require 'drgnx-wait-fixture (expand-file-name "../fixtures/wait-fixture" (file-name-directory (macroexp-file-name))))
(require 'drgnx-tty-session)

(ert-deftest drgnx-tty-switcher/overlay-letters ()
  (drgnx-tty-session-with (s :size "120x40")
    (drgnx-tty-session-wait-tab s "×" 20)
    (drgnx-tty-session-eval s '(progn (require 'drgnx-switcher) (drgnx-groups-split-right) t))
    (drgnx-tty-session-eval s '(progn (drgnx-switcher-open) t))
    (drgnx-tty-session-wait s '(and drgnx-switcher--state
                                    (= (length (plist-get drgnx-switcher--state :overlays))
                                       (length (plist-get drgnx-switcher--state :items)))
                                    (>= (length (plist-get drgnx-switcher--state :items)) 2))
                            10)
    (should-not (drgnx-tty-session-eval s '(plist-get drgnx-switcher--state :cards)))
    (should (equal (drgnx-tty-session-eval s '(mapcar (lambda (o) (substring-no-properties (overlay-get o 'before-string)))
                                                      (plist-get drgnx-switcher--state :overlays)))
                   (drgnx-tty-session-eval s '(reverse (mapcar (lambda (it) (string (plist-get it :letter)))
                                                               (plist-get drgnx-switcher--state :items))))))
    (drgnx-tty-session-wait-screen s (concat "^" drgnx-tty-session-rail "a") 10)
    (drgnx-tty-session-eval s '(progn (drgnx-switcher-close) t))
    (should-not (drgnx-tty-session-eval s 'drgnx-switcher--state))))

(provide 'switcher-tty-test)
;;; switcher-tty-test.el ends here
