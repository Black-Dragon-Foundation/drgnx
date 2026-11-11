;;; search-kinds-test.el --- batch tests: Symbol mode's kind chips in the Search view -*- lexical-binding: t -*-
;; test-class: det
;; test-pattern: pure
;; No hub: the view's state is set by hand in a buffer and the search is a stub that records the hub's spec.  Each
;; test names its pattern.
(require 'ert)
(require 'cl-lib)
(require 'drgnx-paths)
(load (expand-file-name "test/fixtures/state-fixture" drgnx-dir) nil t)
(load (expand-file-name "modules/tools/drgnx-replace" drgnx-dir) nil t)

(defmacro drgnx-search-kinds-test--with (mode &rest body)
  "BODY in a buffer standing for the Search view in MODE; `drgnx-replace--search-now' counts its calls in SEARCHED."
  (declare (indent 1))
  `(with-temp-buffer
     (setq-local drgnx-replace--opts (list :mode ,mode :case t :scope 'project))
     (let ((searched 0) (buf (current-buffer)))
       (cl-letf (((symbol-function 'drgnx-replace--live-view) (lambda () buf))
                 ((symbol-function 'drgnx-replace--search-now) (lambda () (cl-incf searched)))
                 ((symbol-function 'drgnx-replace--scope-param) (lambda (_) '(:kind "project"))))
         ,@body))))

(ert-deftest drgnx-search-kinds/the-chips-show-the-counts-and-toggle ()
  "Pattern D: in Symbol mode with the hub's counts, the chips line lists fn, macro, var and type in order with their
counts (a kind with none has no count, in the subtle face); a click toggles its kind on and searches again; the
spec sent to the hub carries the kinds on; another mode has no chips."
  (drgnx-search-kinds-test--with 'symbol
    (should (equal (drgnx-replace--kinds-line) ""))          ; no search yet: no counts
    (should (equal (drgnx-replace--kind-plist [(:kind "fn" :count 2) (:kind "macro" :count 1) (:kind "var" :count 1)])
                   '(:fn 2 :macro 1 :var 1)))
    (setq drgnx-replace--kind-counts '(:fn 2 :macro 1 :var 1))
    (let ((line (drgnx-replace--kinds-line)))
      (should (string-match-p "^Kinds .*fn 2 .*macro 1 .*var 1 .*type \n$" (substring-no-properties line)))
      (should (eq 'drgnx-text-subtle (get-text-property (string-search "type" line) 'face line)))
      (should (eq 'drgnx-replace-dim (get-text-property (string-search "fn" line) 'face line))))
    (should-not (plist-get (plist-get (drgnx-replace--spec "parse" nil) :query) :kinds))
    (drgnx-replace-kind-toggle 'fn)
    (drgnx-replace-kind-toggle 'var)
    (should (= searched 2))
    (should (equal (plist-get (plist-get (drgnx-replace--spec "parse" nil) :query) :kinds) ["fn" "var"]))
    (let ((line (drgnx-replace--kinds-line)))
      (should (eq 'drgnx-replace-on (get-text-property (string-search "fn" line) 'face line))))
    (drgnx-replace-kind-toggle 'fn)
    (should (equal (plist-get (plist-get (drgnx-replace--spec "parse" nil) :query) :kinds) ["var"])))
  (drgnx-search-kinds-test--with 'text
    (setq drgnx-replace--kind-counts '(:fn 2))
    (should (equal (drgnx-replace--kinds-line) ""))))

(ert-deftest drgnx-search-kinds/a-mode-change-clears-the-chips ()
  "Pattern D: changing the mode drops the kinds on and the counts (the chips are one Symbol search's)."
  (drgnx-search-kinds-test--with 'symbol
    (setq drgnx-replace--kind-counts '(:fn 2) drgnx-replace--kinds-on '(fn))
    (cl-letf (((symbol-function 'drgnx-replace--apply-mode) #'ignore))
      (drgnx-replace--set-mode 'text))
    (should-not drgnx-replace--kinds-on)
    (should-not drgnx-replace--kind-counts)))
