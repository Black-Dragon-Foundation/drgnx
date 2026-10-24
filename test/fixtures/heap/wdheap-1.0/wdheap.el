;;; wdheap.el --- fixture package for the heap audit's tests (test/unit/heap-test.el) -*- lexical-binding: t -*-
;; A package in its own package directory (wdheap-1.0) that keeps about 5 MB in a variable, one structure that two
;; variables share and a buffer with a large undo list.  Every string it keeps starts with `wdheap-private-text', which
;; the audit's snapshot must never contain.

;;; Code:

(defconst wdheap-private-text "WDHEAP-PRIVATE-TEXT"
  "What the kept strings and the buffer's text start with.")

(defvar wdheap-data nil "About 5 MB of strings.")
(defvar wdheap-shared nil "A list of about 1 MB.")
(defvar wdheap-shared-too nil "The same list as `wdheap-shared'.")

(defconst wdheap-buffer-name "wdheap-undo" "The buffer with a large undo list.")

(define-derived-mode wdheap-mode fundamental-mode "WdHeap"
  "The fixture buffer's mode.")

(defun wdheap-fill ()
  "Keep the data: 5 strings of 1 MiB, a shared 64 Ki-cons list, a buffer of 20,000 undo steps."
  (setq wdheap-data (let (l)
                      (dotimes (_ 5) (push (concat wdheap-private-text (make-string (* 1024 1024) ?x)) l))
                      l))
  (setq wdheap-shared (make-list 65536 nil)
        wdheap-shared-too wdheap-shared)
  (with-current-buffer (get-buffer-create wdheap-buffer-name)
    (wdheap-mode)
    (buffer-enable-undo)
    (dotimes (_ 20000)
      (insert wdheap-private-text "\n")
      (undo-boundary))))

(defun wdheap-empty ()
  "Drop what `wdheap-fill' kept."
  (setq wdheap-data nil wdheap-shared nil wdheap-shared-too nil)
  (when-let* ((b (get-buffer wdheap-buffer-name))) (let ((kill-buffer-query-functions nil)) (kill-buffer b))))

(provide 'wdheap)
;;; wdheap.el ends here
