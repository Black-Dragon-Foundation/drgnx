;;; drgnx-persist-geometry-test.el --- live: a window that rebuilds itself keeps its size across restarts -*- lexical-binding: t -*-
;; test-class: cond
;; test-pattern: handshake
;; A real graphical frame, nothing stubbed: the size saved is the size `set-frame-size' sets, so saving, restoring
;; and saving again does not make the window bigger (it did, by the frame's borders, at every restart).
(require 'ert)
(require 'drgnx-ui)
(require 'drgnx-wait-fixture (expand-file-name "../fixtures/wait-fixture" (file-name-directory (macroexp-file-name))))

(ert-deftest drgnx-persist/a-job-windows-size-round-trips ()
  (let* ((root (make-temp-file "drgnx-geometry" t))
         (process-environment (cons (concat "DRGNX_UI_STATE=" root) process-environment))
         ;; the tier's monitor size: mutter has no scale 2 for a 1400x800 one, so the session never started at x2
         (s (drgnx-ui-start "drgnx" nil 30 t))
         (name (plist-get s :name))
         (sess (drgnx-ui-own-session name)))
    (unwind-protect
        (progn
          (should (eql 0 (plist-get (drgnx-ui-new-frame sess) :exit)))
          (let* ((from-the-first-window
                  (lambda (form)       ; as the one form it was: the frame selected is the session's first window, not the new one
                    (format "(with-selected-frame (seq-find (lambda (f) (and (display-graphic-p f) (not (frame-parent f))
                                                                              (not (eq f drgnx-geometry-frame))))
                                                            (frame-list))
                               %s)" form)))
                 (q (lambda (form)
                      (car (read-from-string
                            (plist-get (drgnx-ui-call sess (format "(drgnx-uitest--json (list :v (prin1-to-string %s)))" form)) :v)))))
                 ;; the compositor answers a size change later: wait until the frame has the size asked for
                 (sized (lambda (w h)
                          (drgnx-test-wait (lambda ()
                                             (funcall q (format "(and (eql (frame-text-width drgnx-geometry-frame) %d)
                                                                      (eql (frame-text-height drgnx-geometry-frame) %d))" w h)))
                                           :secs 30 :what "the frame to have the size asked for")))
                 ;; the size under test, whole character cells (75 x 22, 600 x 396 at scale 1): a window takes
                 ;; `default's font while it is made and keeps its lines and columns, so a size between cells is cut
                 ;; to them (ui/look's code font names one)
                 (asked (funcall q "(with-selected-frame (seq-find (lambda (f) (and (display-graphic-p f) (not (frame-parent f)))) (frame-list))
                                      (list (* 75 (frame-char-width)) (* 22 (frame-char-height))))"))
                 (sizes
                  (progn
                    ;; born at the size under test: a resize asked of a window that has just been made is undone by
                    ;; its first redisplay (the size it was made with comes back), so no resize is in flight here
                    (funcall q (format "(with-selected-frame (seq-find (lambda (f) (and (display-graphic-p f) (not (frame-parent f)))) (frame-list))
                                          (setq drgnx-geometry-frame
                                                (make-frame '((drgnx-persist-restore . (ignore))
                                                              (width . (text-pixels . %d)) (height . (text-pixels . %d)))))
                                          t)" (car asked) (cadr asked)))
                    (unwind-protect
                        (let (out)
                          (funcall sized (car asked) (cadr asked))
                          (dotimes (_ 3)
                            (let ((g (funcall q (funcall from-the-first-window "(plist-get (drgnx-persist-state drgnx-geometry-frame) :geometry)"))))
                              (push (list (nth 2 g) (nth 3 g)) out)
                              (funcall q (funcall from-the-first-window
                                                  (format "(progn (drgnx-persist--place-frame drgnx-geometry-frame '%S) t)" g)))
                              (funcall sized (nth 2 g) (nth 3 g))))
                          (push (funcall q "(list (frame-text-width drgnx-geometry-frame) (frame-text-height drgnx-geometry-frame))") out)
                          (nreverse out))
                      (funcall q "(progn (delete-frame drgnx-geometry-frame) t)")))))
            ;; every save gives the size the frame was given, however often it is restored
            (should (= 4 (length sizes)))
            (should (equal (delete-dups (copy-sequence sizes)) (list (car sizes))))
            (should (equal (car sizes) asked))))
      (drgnx-ui-stop name)
      (delete-directory root t))))
