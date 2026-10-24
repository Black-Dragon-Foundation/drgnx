;; Descriptions of Emacs's own variables that are not `defcustom's, or that drgnx marks (docs/guide/settings.md).
(drgnx-described
 (gc-cons-threshold :type integer :doc "Bytes of allocation between garbage collections." :group alloc :scope global)
 (gc-cons-percentage :type number :doc "Portion of the heap allocated between garbage collections." :group alloc :scope global)
 (read-process-output-max :type integer :doc "Largest chunk read from a process at once." :group processes :scope global)
 (auto-mode-alist :merge alist)
 (display-buffer-alist :merge alist)
 (interpreter-mode-alist :merge alist)
 (magic-mode-alist :merge alist)
 (process-environment :workspace never)
 (exec-path :workspace code)
 ;; Programs drgnx and Emacs run, by names Emacs does not mark risky: the shell of M-x compile, grep, shell-command
 ;; and project-find-regexp, its switch, and the Emacs that Flymake's byte-compile backend and package.el start.
 (shell-file-name :workspace code)
 (explicit-shell-file-name :workspace code)
 (shell-command-switch :workspace code)
 (invocation-name :workspace code)
 (invocation-directory :workspace code))
