;;; drgnx-large-files-chunks.el --- Module editor/large-files-chunks: large files in chunks (vlf) -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; A large file (above large-files.eld's `:ask-above') that opens in chunks gets a vlf buffer: one chunk of
;; `:chunk-size' bytes (1 MiB) of the file at a time.  The open never shows the buffer: the door returns it, as
;; `find-file-noselect' does.  Undo stays on (a chunk is small); auto-save is off.  vlf loads on the first chunk
;; open.  `vlf-setup' is never loaded: its advice asks a question of its own.  Without this module (vlf not
;; installed), chunks become raw.  The module's file is separate from editor/large-files so that that one needs
;; no package.  See docs/guide/modules.md and docs/develop/core.md ("Large files").

;;; Code:
(require 'drgnx-modules)
(require 'drgnx-registry)
(require 'drgnx-large-file)

(defvar drgnx-large-files-chunk-open-function)   ; editor/large-files (required): the door calls it
(defvar vlf-mode)
(defvar vlf-batch-size)
(defvar vlf-tune-enabled)
(defvar vlf-end-pos)
(defvar vlf-file-size)
(declare-function vlf-mode "vlf")
(declare-function drgnx-large-files--never-query "drgnx-large-files")

(defun drgnx-large-files-chunks-p ()
  "Non-nil in a buffer holding a large file in chunks."
  (eq drgnx-large-file 'chunks))

(defun drgnx-large-files-chunks-open (file _size thresholds)
  "A new buffer holding FILE in chunks of THRESHOLDS' `:chunk-size' bytes, not displayed; SIZE is unused.
Copied from vlf 1.7.2's `vlf', which builds the buffer and then selects it with `switch-to-buffer': this does the
same four steps (`generate-new-buffer', `set-visited-file-name', `set-buffer-modified-p' nil, `vlf-mode') and
selects nothing.  Four additions:
- the flag is set first, so the major mode that `set-visited-file-name' runs, and its hooks, see a large file;
- vlf's batch-size tuning is off, so a chunk always holds `:chunk-size' bytes;
- auto-save goes off at the end, and `auto-save-visited-mode' skips the buffer.  Undo stays on;
- local variables are only the safe ones: the open may be automatic."
  (require 'vlf)
  (let ((buf (generate-new-buffer "*vlf*")) (done nil))
    (unwind-protect
        (with-current-buffer buf
          (setq drgnx-large-file 'chunks)
          ;; the buffer is still empty, so only .dir-locals.el applies, and it never asks: an open may be automatic.
          ;; NO-QUERY: the door builds chunks only for a file no buffer visits, so the question cannot come up anyway
          (let ((enable-local-variables (drgnx-large-files--never-query enable-local-variables)))
            (set-visited-file-name file t))
          (set-buffer-modified-p nil)
          (setq-local vlf-batch-size (max 1 (plist-get thresholds :chunk-size)))
          (setq-local vlf-tune-enabled nil)
          (vlf-mode 1)
          (auto-save-mode -1)
          ;; the user's `auto-save-visited-mode' skips it: its timer would save the chunk, and vlf asks when the size
          ;; changed
          (setq-local auto-save-visited-mode nil)
          (setq done t))
      (unless done (kill-buffer buf)))
    buf))

(defun drgnx-large-files-chunks-position ()
  "The chunk shown, as (N . TOTAL); nil outside a chunk buffer.  It counts as vlf's own mode line does: by the
chunk's end, so the last chunk is TOTAL even when vlf moves its start back to fill it."
  (when (and (drgnx-large-files-chunks-p) (bound-and-true-p vlf-mode))
    (cons (max 1 (ceiling vlf-end-pos vlf-batch-size)) (max 1 (ceiling vlf-file-size vlf-batch-size)))))

(drgnx-module-define 'editor/large-files-chunks
                     :doc "Large files in chunks (vlf): a file that opens in chunks shows one chunk at a time; without vlf it opens raw."
                     :stage 'startup :packages '(vlf) :requires '(editor/large-files)
                     ;; chunk buffers are vlf's: they stay as they are
                     :teardown #'ignore
                     :setup (lambda ()
                              (drgnx-module-set 'drgnx-large-files-chunk-open-function #'drgnx-large-files-chunks-open)
                              ;; vlf-mode's own keymap is `vlf-prefix-map' (its `vlf-mode-map' is under C-c C-v)
                              (pcase-dolist (`(,id ,title ,fn ,doc)
                                             '((large-file-next-chunk "Large File: Next Chunk" vlf-next-batch
                                                                      "Show the next chunk of the file")
                                               (large-file-previous-chunk "Large File: Previous Chunk" vlf-prev-batch
                                                                          "Show the previous chunk of the file")
                                               (large-file-go-to-line "Large File: Go to Line" vlf-goto-line
                                                                      "Go to a line of the whole file")
                                               (large-file-search "Large File: Search" vlf-re-search-forward
                                                                  "Search the whole file for a regexp, chunk by chunk")))
                                (drgnx-command-define id :category "File" :title title :command fn
                                                      :map '(vlf . vlf-prefix-map) :when #'drgnx-large-files-chunks-p
                                                      :doc doc))))

(provide 'drgnx-large-files-chunks)
;;; drgnx-large-files-chunks.el ends here
