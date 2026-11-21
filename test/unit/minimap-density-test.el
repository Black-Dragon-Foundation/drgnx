;;; minimap-density-test.el --- batch tests: the minimap's density strip for huge files -*- lexical-binding: t -*-
;; test-class: det
;; test-pattern: pure
;; modules/editor/drgnx-minimap-density.el (design M7, state C): which buffers get the strip, its spec (with a
;; chunk's place), the watch's density ask, the bucket peek from the hub's answer and its jump (through a chunk's
;; offset).  The hub's scan is tested in Rust (view::minimap::density).
(require 'ert)
(require 'cl-lib)
(require 'drgnx-paths)
(require 'drgnx)
(load (expand-file-name "test/fixtures/modules-fixture" drgnx-dir) nil t)
(load (expand-file-name "modules/editor/drgnx-minimap" drgnx-dir) nil t)

(defvar drgnx-minimap--card)
(defvar drgnx-large-file)
(defvar vlf-mode)
(defvar vlf-start-pos)
(defvar vlf-file-size)

(defmacro minimap-density-test--with (lines &rest body)
  "BODY in a buffer of LINES short lines shown in the selected window."
  (declare (indent 1))
  `(let ((b (generate-new-buffer "minimap-density")))
     (unwind-protect
         (save-window-excursion
           (switch-to-buffer b)
           (dotimes (i ,lines) (insert (format "%d\n" i)))
           (goto-char (point-min))
           ,@body)
       (kill-buffer b))))

(ert-deftest drgnx-minimap/the-density-strip-is-for-huge-buffers ()
  "A buffer gets the density strip past `drgnx-minimap-density-above' lines or as a large file; not below the limit,
and not a buffer of few long lines."
  (let ((drgnx-minimap-density-above 1000))
    (minimap-density-test--with 999
      (should-not (drgnx-minimap-density-p))
      (goto-char (point-max))
      (insert "1\n2\n")
      (should (drgnx-minimap-density-p)))
    (minimap-density-test--with 10
      (insert (make-string 5000 ?x))
      (should-not (drgnx-minimap-density-p))
      (setq-local drgnx-large-file 'lean)
      (should (drgnx-minimap-density-p)))))

(ert-deftest drgnx-minimap/a-chunk-buffer-says-where-its-chunk-is ()
  "The strip's spec is a density spec of the file, with the chunk's start and the file's size when the buffer holds
one chunk; the watch asks the hub for the scan with the setting's expressions."
  (minimap-density-test--with 10
    (cl-letf (((symbol-function 'drgnx-large-files-chunks-p) (lambda () t)))
      (setq-local vlf-mode t vlf-start-pos 4096 vlf-file-size 1048576)
      (let ((spec (drgnx-minimap-density-spec (selected-window) "/f.log")))
        (should (eq t (plist-get spec :density)))
        (should (equal "/f.log" (plist-get spec :file)))
        (should (equal '(4096 . 1048576) (plist-get spec :chunk)))
        (should (eq 'error (plist-get spec :error)))))
    (let ((drgnx-minimap-density-regexps '(:error "E\\d+" :warning "W")))
      (should (equal '(:density (:error "E\\d+" :warning "W")) (drgnx-minimap-density-ask))))))

(ert-deftest drgnx-minimap/a-bucket-peek-shows-the-hubs-lines-and-goes-there ()
  "A dwell on a bucket asks the hub for its first lines; the card shows them with the part and byte in its header,
and its jump goes to that byte, counted from the chunk's start in a chunk buffer; a part in another chunk is not
jumped to."
  (minimap-density-test--with 50
    (let (asked shown jumped)
      (cl-letf (((symbol-function 'drgnx-minimap--hub-p) (lambda () t))
                ((symbol-function 'drgnx-hub--call-on)
                 (lambda (_c method params cb &rest _)
                   (setq asked (cons method params))
                   (funcall cb (list :text "10\n11" :start 20 :buckets 64) nil)))
                ((symbol-function 'drgnx-minimap--show-card)
                 (lambda (kind w pos _lines header buf &rest _)
                   (setq shown (list kind pos header (with-current-buffer buf (buffer-string))))
                   (setq drgnx-minimap--card (vector nil kind w pos))))
                ((symbol-function 'drgnx-minimap-card-hide) (lambda () (setq drgnx-minimap--card nil)))
                ((symbol-function 'drgnx-minimap--jump) (lambda (_w pos) (setq jumped pos))))
        (set-window-parameter nil 'glitnir-minimap (list :density t :file "/f.log"))
        (unwind-protect
            (progn
              (drgnx-minimap--event 'dwell-bucket (selected-window) 3)
              (should (equal "minimap/bucket" (car asked)))
              (should (equal 3 (plist-get (cdr asked) :bucket)))
              (should (equal '(bucket 20 "Part 4 of 64 · byte 20" "10\n11") shown))
              (drgnx-minimap-bucket-jump)
              (should (= jumped (1+ 20)))
              ;; a chunk from byte 10: byte 20 is the chunk's 11th
              (cl-letf (((symbol-function 'drgnx-large-files-chunks-p) (lambda () t)))
                (setq-local vlf-mode t vlf-start-pos 10 vlf-file-size 1000)
                (should (= 11 (drgnx-minimap-density-position (current-buffer) 20)))
                (should-not (drgnx-minimap-density-position (current-buffer) 5))))
          (set-window-parameter nil 'glitnir-minimap nil))))))

(ert-deftest drgnx-minimap/a-click-on-a-card-keeps-its-keys-for-the-up-event ()
  "A click's down event (`ignore') keeps the card's keys, so its up event reaches the card's map."
  (let ((drgnx-minimap--card (vector nil 'peek nil 1)) (this-command 'ignore))
    (should (drgnx-minimap--card-keep-p))))

(provide 'minimap-density-test)
;;; minimap-density-test.el ends here
