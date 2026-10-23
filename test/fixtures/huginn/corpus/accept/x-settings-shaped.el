(drgnx-settings :version 1
  (fill-column 100)
  (tab-width 4 :merge keep)
  (:mode python-mode (python-indent-offset 4))
  (:dir "src/" (:mode go-mode (tab-width 8)))
  (foo '(a . b))
  (bar #'ignore))
