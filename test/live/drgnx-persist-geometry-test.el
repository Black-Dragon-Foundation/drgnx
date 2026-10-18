;;; drgnx-persist-geometry-test.el --- live: a window that rebuilds itself keeps its size across restarts -*- lexical-binding: t -*-
;; A real graphical frame, nothing stubbed: the size saved is the size `set-frame-size' sets, so saving, restoring
;; and saving again does not make the window bigger (it did, by the frame's borders, at every restart).
(require 'ert)
(require 'drgnx-ui)

(ert-deftest drgnx-persist/a-job-windows-size-round-trips ()
  (let* ((root (make-temp-file "drgnx-geometry" t))
         (process-environment (cons (concat "DRGNX_UI_STATE=" root) process-environment))
         (s (drgnx-ui-start "drgnx" "1400x800" 30 t))
         (name (plist-get s :name))
         (sess (drgnx-ui-own-session name)))
    (unwind-protect
        (progn
          (should (eql 0 (plist-get (drgnx-ui-new-frame sess) :exit)))
          (let ((sizes (car (read-from-string
                             (plist-get (drgnx-ui-call sess "(drgnx-uitest--json
  (list :v (prin1-to-string
            (with-selected-frame (seq-find (lambda (f) (and (display-graphic-p f) (not (frame-parent f)))) (frame-list))
              (let ((f (make-frame '((drgnx-persist-restore . (ignore)) (width . 60) (height . 20)))) out)
                (unwind-protect
                    (progn
                      (set-frame-size f 600 400 t) (sleep-for 0.5)
                      (dotimes (_ 3)
                        (let ((g (plist-get (drgnx-persist-state f) :geometry)))
                          (push (list (nth 2 g) (nth 3 g)) out)
                          (drgnx-persist--place-frame f g) (sleep-for 0.5)))
                      (push (list (frame-text-width f) (frame-text-height f)) out)
                      (nreverse out))
                  (delete-frame f)))))))")
                                        :v)))))
            ;; every save gives the size the frame was given, however often it is restored
            (should (= 4 (length sizes)))
            (should (equal (delete-dups (copy-sequence sizes)) (list (car sizes))))
            (should (equal (car sizes) '(600 400)))))
      (drgnx-ui-stop name)
      (delete-directory root t))))
