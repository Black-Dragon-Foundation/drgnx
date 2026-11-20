;;; drgnx-minimap-density.el --- The minimap's density strip for huge files -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Part of the editor/minimap module (docs/guide/minimap.md; design M7, state C, §7.6).  Past the density limit a
;; buffer gets no line model: its minimap is a density strip, a 1 px row per part of the file, its brightness the
;; text there and a mark at its edge where that part has errors (or warnings).  The hub scans the file on disk
;; (`minimap/watch''s `density') and sends the table to Sjá in parts; Nidhogg draws it (`:density' in the spec).  A
;; buffer holding one chunk of the file (editor/large-files-chunks) says where the chunk is (`:chunk'), so its band
;; sits at the chunk's place in the whole file.  Resting on the strip peeks at that part's first lines
;; (`minimap/bucket', read from disk; no buffer is touched).

;;; Code:
(require 'subr-x)
(require 'drgnx-setting)

;; drgnx-minimap.el loads this file after drgnx-minimap-peek.el (modules are not on the load path)
(declare-function drgnx-minimap--show-card "drgnx-minimap-peek" (kind window pos lines header buffer start &optional map))
(declare-function drgnx-minimap-card-hide "drgnx-minimap-peek" ())
(declare-function drgnx-minimap--jump "drgnx-minimap-peek" (window pos))
(defvar drgnx-minimap-peek)
(defvar drgnx-minimap-peek-lines)
(defvar drgnx-minimap--card)

(declare-function drgnx-hub--call-on "drgnx-hub-client" (conn method params callback &rest keys))
(declare-function drgnx-minimap--hub-p "drgnx-minimap" ())
(declare-function drgnx-large-files-chunks-p "drgnx-large-files-chunks" ())
(defvar drgnx-hub--events)
(defvar drgnx-large-file)
(defvar vlf-start-pos)
(defvar vlf-file-size)
(defvar vlf-after-batch-functions)
(declare-function drgnx-minimap--place "drgnx-minimap" (window on))

(declare-function drgnx-minimap-peek--respec "drgnx-minimap-peek" (&rest _))

(drgnx-defsetting drgnx-minimap-density-above 250000
  "Past how many lines a buffer's minimap is a density strip (no line model; design M7).  A large file (above the
large-files size) is always one."
  :type 'natnum :group 'drgnx-minimap :scope 'global :apply #'drgnx-minimap-peek--respec)

(drgnx-defsetting drgnx-minimap-density-regexps '(:error "ERROR|FATAL" :warning "WARN")
  "What the density strip marks: the lines matching `:error' and those matching `:warning', in Rust regex syntax
\(the hub scans the file)."
  :type '(plist :key-type (choice (const :error) (const :warning)) :value-type string)
  :group 'drgnx-minimap :scope 'global :apply #'drgnx-minimap-peek--respec)

(defvar-local drgnx-minimap--density-memo nil
  "Whether the buffer is past the density limit, for (TICK SIZE LIMIT): (KEY . ANSWER).")

(defvar drgnx-minimap-bucket-map)          ; defined below, after its commands

(defun drgnx-minimap-density-p (&optional buffer)
  "Whether BUFFER's minimap is a density strip: a large file, or more lines than `drgnx-minimap-density-above'.
The lines are counted only when the buffer holds more characters than the limit, once per change."
  (with-current-buffer (or buffer (current-buffer))
    (or (and (boundp 'drgnx-large-file) drgnx-large-file t)
        (let ((size (buffer-size)) (limit drgnx-minimap-density-above))
          (and (> size limit)
               (let ((key (list (buffer-chars-modified-tick) size limit)))
                 (if (equal key (car drgnx-minimap--density-memo))
                     (cdr drgnx-minimap--density-memo)
                   (cdr (setq drgnx-minimap--density-memo
                              (cons key (save-restriction (widen) (> (count-lines (point-min) (point-max)) limit))))))))))))

(defun drgnx-minimap--chunk (buffer)
  "BUFFER's place in its file when it holds one chunk of it: (START . FILE-BYTES); else nil."
  (with-current-buffer buffer
    (and (fboundp 'drgnx-large-files-chunks-p) (drgnx-large-files-chunks-p) (bound-and-true-p vlf-mode)
         (cons vlf-start-pos vlf-file-size))))

(defun drgnx-minimap-density-spec (window file)
  "WINDOW's density strip spec for FILE (the hub's name of it)."
  (append (list :density t :file file :width 80 :scale 2
                :fill (cons (face-background 'drgnx-surface-panel nil 'default) 1.0)
                :text (cons 'default 0.5) :band (cons 'default 0.09)
                :error 'error :warning 'warning)
          (let ((chunk (drgnx-minimap--chunk (window-buffer window)))) (and chunk (list :chunk chunk)))))

(defun drgnx-minimap-density-ask ()
  "The watch's density ask: the expressions the hub's scan counts."
  (list :density (list :error (or (plist-get drgnx-minimap-density-regexps :error) "ERROR|FATAL")
                       :warning (or (plist-get drgnx-minimap-density-regexps :warning) "WARN"))))

;;;; The bucket peek

(defvar drgnx-minimap--bucket-ask 0 "The latest bucket peek asked for: an older answer is dropped.")

(defvar drgnx-minimap--bucket-buffer " *drgnx-minimap-bucket*" "The bucket peek's buffer's name.")

(defun drgnx-minimap-bucket-peek (window bucket)
  "Peek at density BUCKET of WINDOW's file: the hub reads its first lines from disk; the card shows them."
  (when-let* ((file (plist-get (window-parameter window 'glitnir-minimap) :file))
              ((drgnx-minimap--hub-p)))
    (let ((ask (setq drgnx-minimap--bucket-ask (1+ drgnx-minimap--bucket-ask))))
      (drgnx-hub--call-on (bound-and-true-p drgnx-hub--events) "minimap/bucket"
                          (list :file file :bucket bucket :lines drgnx-minimap-peek-lines)
                          (lambda (result _err)
                            (when (and result (= ask drgnx-minimap--bucket-ask) (window-live-p window))
                              (drgnx-minimap-bucket-show window bucket result)))))))

(defun drgnx-minimap-bucket-show (window bucket result)
  "Show RESULT (`minimap/bucket''s answer) for BUCKET of WINDOW's file in the card: the lines in the code font, the
header the bucket and its byte offset; RET goes there when the buffer holds that part of the file."
  (let ((cb (get-buffer-create drgnx-minimap--bucket-buffer))
        (start (plist-get result :start)))
    (with-current-buffer cb
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert (propertize (or (plist-get result :text) "") 'drgnx-minimap-byte start)))
      (setq-local cursor-type nil truncate-lines t buffer-read-only t)
      (buffer-disable-undo))
    (drgnx-minimap--show-card 'bucket window start (max 1 drgnx-minimap-peek-lines)
                              (format "Part %d of %d · byte %d" (1+ bucket) (or (plist-get result :buckets) 1) start)
                              cb 1 drgnx-minimap-bucket-map)))

(defun drgnx-minimap-bucket-jump ()
  "Go to the bucket peek's first line, when the buffer holds that part of the file."
  (interactive)
  (when-let* ((card drgnx-minimap--card) ((eq (aref card 1) 'bucket)))
    (let* ((w (aref card 2)) (pos (drgnx-minimap-density-position (window-buffer w) (aref card 3))))
      (drgnx-minimap-card-hide)
      (if pos (drgnx-minimap--jump w pos) (message "That part of the file is in another chunk")))))

(defvar drgnx-minimap-bucket-map
  (let ((m (make-sparse-keymap)))
    (define-key m (kbd "RET") #'drgnx-minimap-bucket-jump)
    (define-key m [return] #'drgnx-minimap-bucket-jump)
    (define-key m [escape] #'drgnx-minimap-card-hide)
    (define-key m [down-mouse-1] #'ignore)
    (define-key m [mouse-1] #'drgnx-minimap-bucket-jump)
    m)
  "The bucket peek's keys: RET or a click goes there, Esc closes it.")

(defun drgnx-minimap-density-position (buffer byte)
  "The position of file BYTE (from 0) in BUFFER, or nil when the buffer does not hold it (another chunk)."
  (with-current-buffer buffer
    (let ((local (if-let* ((chunk (drgnx-minimap--chunk buffer))) (- byte (car chunk)) byte)))
      (and (>= local 0) (byte-to-position (1+ local))))))

;;;; Setup

(defun drgnx-minimap--chunk-moved (&rest _)
  "`vlf-after-batch-functions': the buffer shows another chunk; its windows' strips move their band there."
  (when (fboundp 'drgnx-minimap--place)
    (dolist (w (get-buffer-window-list nil nil t))
      (drgnx-minimap--place w (and (window-parameter w 'glitnir-ruler) t)))))

(defun drgnx-minimap-density-on ()
  "The module's setup of this file: chunk moves followed."
  (add-hook 'vlf-after-batch-functions #'drgnx-minimap--chunk-moved))

(defun drgnx-minimap-density-off ()
  "Undo `drgnx-minimap-density-on': the hook gone, a bucket peek's buffer killed."
  (remove-hook 'vlf-after-batch-functions #'drgnx-minimap--chunk-moved)
  (when (get-buffer drgnx-minimap--bucket-buffer) (kill-buffer drgnx-minimap--bucket-buffer)))

(provide 'drgnx-minimap-density)
;;; drgnx-minimap-density.el ends here
