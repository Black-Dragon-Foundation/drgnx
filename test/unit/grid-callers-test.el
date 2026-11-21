;;; grid-callers-test.el --- batch tests: every caller is on pane kinds, the old backend is gone -*- lexical-binding: t -*-
;; test-class: det
;; Tiling plan, Task 20: modules, the harness and the live tests define their panes with `drgnx-pane-define-kind'
;; (the grid's API), never with the areas' and the dock's own `drgnx-wb-define-tab', `-define-section' and
;; `-define-area'.  Those stay as the data layer the grid's docks read (wb/drgnx-area.el and wb/drgnx-wb.el hold them,
;; wb/drgnx-panes.el forwards a kind's definition to them), and the unit and GUI tests of that layer still call them.
(require 'ert)
(require 'seq)
(require 'drgnx-paths)

(defconst drgnx-grid-callers-test--obsolete
  '("drgnx-wb-define-tab" "drgnx-wb-define-section" "drgnx-wb-define-area")
  "The names no caller outside the data layer uses.")

(defconst drgnx-grid-callers-test--dirs '("core" "wb" "modules" "harness" "bin" "test/live" "test/bench" "test/scenario"
                                          "test/perf")
  "Where the callers live (the unit and GUI tests of the data layer itself are not callers).")

(defconst drgnx-grid-callers-test--layer '("wb/drgnx-area.el" "wb/drgnx-wb.el" "wb/drgnx-panes.el")
  "The data layer and the forwarding point: they define and use the names.")

(ert-deftest drgnx-grid/no-in-tree-caller-of-the-old-api ()
  (let (found)
    (dolist (dir drgnx-grid-callers-test--dirs)
      (let ((root (expand-file-name dir drgnx-dir)))
        (when (file-directory-p root)
          (dolist (f (directory-files-recursively root "\\.\\(el\\|eld\\|sh\\)\\'"))
            (let ((rel (file-relative-name f drgnx-dir)))
              (unless (or (member rel drgnx-grid-callers-test--layer) (string-match-p "/\\.\\|-test\\.el\\'" rel)
                          (string-prefix-p "test/live/" rel)) ; the live tests are checked below, with their own names
                (with-temp-buffer
                  (insert-file-contents f)
                  (dolist (name drgnx-grid-callers-test--obsolete)
                    (goto-char (point-min))
                    (while (search-forward name nil t)
                      (push (format "%s:%d %s" rel (line-number-at-pos) name) found))))))))))
    ;; the live tests: their drivers call the area API from strings sent to the session
    (let ((live (expand-file-name "test/live" drgnx-dir)))
      (when (file-directory-p live)
        (dolist (f (directory-files-recursively live "\\.el\\'"))
          (with-temp-buffer
            (insert-file-contents f)
            (dolist (name drgnx-grid-callers-test--obsolete)
              (goto-char (point-min))
              (while (search-forward name nil t)
                (push (format "%s:%d %s" (file-relative-name f drgnx-dir) (line-number-at-pos) name) found)))))))
    (should-not (sort found #'string<))))

(ert-deftest drgnx-pane/there-is-no-areas-backend ()
  "The grid is the only pane backend: no fallback to the areas' side windows."
  (require 'drgnx-panes)
  (require 'drgnx-grid)
  (should-not (assq 'areas drgnx-pane--backends))
  (should (assq 'grid drgnx-pane--backends)))

(provide 'grid-callers-test)
;;; grid-callers-test.el ends here
