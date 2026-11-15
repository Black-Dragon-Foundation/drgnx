;;; leaky-face.el --- fixture: a test file that leaves a drgnx face's colour set on the frame -*- lexical-binding: t -*-
;; Copied into a temp suite as a *-test.el by test/unit/run-ert-test.el.
(defface drgnx-file-leak-fixture-face '((t :background "#101010")) "A face the fixture sets a colour on.")
(ert-deftest file-leak-fixture/leaves-a-face-colour ()
  (set-face-background 'drgnx-file-leak-fixture-face "#c8c8d0" (selected-frame))
  (should t))
