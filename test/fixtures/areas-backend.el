;;; areas-backend.el --- the areas' backend, for the tests of the docks' data layer -*- lexical-binding: t -*-
;; The product has one pane backend, the grid (wb/drgnx-grid.el).  The tests of `drgnx-wb-define-tab', `-define-section'
;; and the docks as side windows register the areas' functions as a backend of their own, and bind `drgnx-pane-backend'
;; to `areas'.
(require 'drgnx-panes)

(setf (alist-get 'areas drgnx-pane--backends)
      (list :define #'drgnx-pane--areas-define :show #'drgnx-pane--areas-show :hide #'drgnx-pane--areas-hide
            :window #'drgnx-pane--areas-window :focus #'drgnx-pane--areas-focus :resize #'drgnx-pane--areas-resize))

(provide 'areas-backend)
;;; areas-backend.el ends here
