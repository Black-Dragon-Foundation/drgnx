;;; work-mode-test.el --- the Work map's List and Graph modes: what the editor sends -*- lexical-binding: t -*-
;; test-class: det
;; test-pattern: pure
;; No hub: the map client's calls are caught at `drgnx-work-client--call'.
(require 'ert)
(require 'cl-lib)
(require 'drgnx)
(require 'drgnx-work-client)
(require 'drgnx-hub-client)
(require 'drgnx-ai)
(load (expand-file-name "test/fixtures/modules-fixture" drgnx-dir) nil t)
(drgnx-test-modules-preload '(tools/work-space))

(defvar drgnx-work-space--view)
(defvar drgnx-work-map--mode-by-project)
(declare-function drgnx-work-lens-show-map "drgnx-work-board")
(declare-function drgnx-work-map--mode "drgnx-work-map")

(ert-deftest drgnx-work-mode/m-in-the-map-toggles-list-and-graph ()
  (let (calls (drgnx-work-map--mode-by-project nil))
    (cl-letf (((symbol-function 'drgnx-work-client--call)
               (lambda (method params &rest _) (push (cons method params) calls) t)))
      (with-temp-buffer
        (drgnx-work-map-mode)
        (setq drgnx-work-space--view "workspace:mode-toggle")
        (drgnx-work-client-open "workspace:mode-toggle" (list :id "workspace:mode-toggle" :roots nil))
        (setq calls nil)
        (should (eq 'list (drgnx-work-map--mode)))
        (drgnx-work-lens-show-map)
        (should (equal "graph" (plist-get (cdr (car calls)) :mode)))
        (drgnx-work-lens-show-map)
        (should (equal "list" (plist-get (cdr (car calls)) :mode)))))))

(ert-deftest drgnx-work-mode/m-elsewhere-shows-the-map ()
  (let (calls switched)
    (cl-letf (((symbol-function 'drgnx-work-client--call)
               (lambda (method params &rest _) (push (cons method params) calls) t))
              ((symbol-function 'drgnx-work-lens-switch) (lambda (lens) (push lens switched))))
      (with-temp-buffer
        (fundamental-mode)
        (drgnx-work-lens-show-map)
        (should (equal '(map) switched))
        (should-not calls)))))
