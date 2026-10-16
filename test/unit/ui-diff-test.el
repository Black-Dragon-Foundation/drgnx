;;; ui-diff-test.el --- batch tests: ui_diff and ui_record -*- lexical-binding: t -*-
(require 'ert)
(require 'drgnx-uitest)
(require 'drgnx-ui-mcp)

(defconst ui-diff-test--a
  '(:frame (:width 1400 :height 800) :minibuffer_h 20 :children []
    :windows [(:id "w1" :buffer "a.txt" :edges [0 0 700 780] :start 1 :point 5 :selected t)
              (:id "w2" :buffer "*Help*" :edges [700 0 1400 780] :start 1 :point 1 :selected :false)]))

(defconst ui-diff-test--b
  '(:frame (:width 1400 :height 800) :minibuffer_h 22 :children []
    :windows [(:id "w1" :buffer "a.txt" :edges [0 0 700 780] :start 1 :point 9 :selected t)
              (:id "w3" :buffer "b.txt" :edges [700 0 1400 780] :start 1 :point 1 :selected :false)]))

(ert-deftest ui-diff/changed-added-and-removed ()
  (let ((d (drgnx-ui-state-diff ui-diff-test--a ui-diff-test--b)))
    (should (member '(:window "w1" :field "point" :old 5 :new 9) d))
    (should (member '(:window "w2" :field "removed" :old "*Help*" :new nil) d))
    (should (member '(:window "w3" :field "added" :old nil :new "b.txt") d))
    (should (member '(:window nil :field "minibuffer_h" :old 20 :new 22) d))
    (should (= 4 (length d)))))

(ert-deftest ui-diff/identical-states-have-no-changes ()
  (should-not (drgnx-ui-state-diff ui-diff-test--a ui-diff-test--a)))

(ert-deftest ui-diff/the-tools-are-listed ()
  (let ((names (mapcar (lambda (tool) (plist-get tool :name)) drgnx-ui-mcp-tools)))
    (should (member "ui_diff" names))
    (should (member "ui_record" names)))
  (let ((r (drgnx-ui-mcp-call "ui_diff" (list :a ui-diff-test--a :b ui-diff-test--b))))
    (should-not (plist-get r :isError))
    (should (string-match-p "w3" (plist-get (aref (plist-get r :content) 0) :text)))))
