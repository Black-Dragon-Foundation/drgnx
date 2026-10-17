;;; drgnx-ai-probe.el --- Which AI providers run here, what they can do, whether the GPU has room -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; `drgnx-ai-probe' asks every local provider's well-known address at once — curl processes, one second each —
;; and returns immediately; the results land in `drgnx-ai-detected' (and a cache in the state dir, for the
;; doctor).  Something answering on TEI's port is only taken for TEI when /info says so (LocalAI answers there
;; too).  `drgnx-ai-probe-fim' asks whether a model fills in the middle.  `drgnx-ai-vram' reads nvidia-smi (macOS: two
;; thirds of the RAM, which Apple silicon shares with the GPU).

;;; Code:
(require 'cl-lib)
(require 'seq)
(require 'subr-x)
(require 'url-parse)
(require 'drgnx-ai)
(require 'drgnx-ai-client)

(defvar drgnx-ai-detected nil "Alist provider → (:up BOOL :models (NAME…) :note TEXT) from the last probe.")

(defvar drgnx-ai-probe-done-hook nil "Run when a probe has its answers (what uses providers looks again).")

(defun drgnx-ai-detected-file () (expand-file-name "ai-detected.eld" (drgnx-state-dir)))

(defun drgnx-ai--local-p (p)
  (member (url-host (url-generic-parse-url (plist-get p :url))) '("localhost" "127.0.0.1" "::1")))

(defun drgnx-ai--probe-url (p)
  (pcase (plist-get p :kind)
    ('ollama (concat (plist-get p :url) "/api/tags"))
    ('llamacpp (concat (plist-get p :url) "/v1/models"))
    ('tei (concat (plist-get p :url) "/info"))
    (_ (concat (plist-get p :url) "/models"))))

(defun drgnx-ai--probe-result (p status text)
  (let ((json (and (<= 200 status 299) (ignore-errors (json-parse-string text :object-type 'plist :null-object nil)))))
    (pcase (plist-get p :kind)
      ((guard (null json)) (list :up nil :note (if (eql status 0) "not running" (format "HTTP %d" status))))
      ('tei (if (plist-get json :model_id)
                (list :up t :models (list (plist-get json :model_id)))
              (list :up nil :note "not TEI: another server answers there (LocalAI?)")))
      ('ollama (list :up t :models (mapcar (lambda (m) (plist-get m :name)) (plist-get json :models))))
      (_ (list :up t :models (mapcar (lambda (m) (plist-get m :id)) (plist-get json :data)))))))

(defun drgnx-ai-probe (callback &optional ids)
  "Ask the local providers (or IDS) whether they run, in the background; CALLBACK when all have answered.
Returns at once."
  (let* ((ps (seq-filter (lambda (e) (if ids (memq (car e) ids) (drgnx-ai--local-p (cdr e)))) (drgnx-ai-providers)))
         (left (length ps)) (found nil)
         (finish (lambda ()
                   ;; only the providers asked: the others (or one added while this probe ran) stay as known
                   (dolist (e found) (setf (alist-get (car e) drgnx-ai-detected) (cdr e)))
                   (ignore-errors
                     (make-directory (file-name-directory (drgnx-ai-detected-file)) t)
                     (with-temp-file (drgnx-ai-detected-file) (prin1 drgnx-ai-detected (current-buffer))))
                   (run-hooks 'drgnx-ai-probe-done-hook)
                   (when callback (funcall callback)))))
    (if (null ps) (funcall finish)
      (pcase-dolist (`(,id . ,p) ps)
        (drgnx-ai--curl (drgnx-ai--probe-url p)
                        (lambda (status text)
                          (push (cons id (drgnx-ai--probe-result p status text)) found)
                          (when (zerop (setq left (1- left))) (funcall finish)))
                        :timeout 1)))
    nil))

(defun drgnx-ai-usable-p (id &optional cap interactive)
  "Provider ID can be asked (for CAP, e.g. `fim'): with its key when it has one; a local one when the probe
found it running; a remote one without a key as configured.  INTERACTIVE: for a command the user ran (its key
may come from a source that asks)."
  (let ((p (drgnx-ai-provider id)))
    (and p (or (null cap) (memq cap (plist-get p :caps)))
         (cond ((plist-get p :key-env) (and (drgnx-ai-key id interactive) t))
               ((drgnx-ai--local-p p) (plist-get (alist-get id drgnx-ai-detected) :up))
               (t t)))))

(defun drgnx-ai-detected-cached ()
  "The last probe's results as saved (the doctor runs in another Emacs)."
  (ignore-errors (with-temp-buffer (insert-file-contents (drgnx-ai-detected-file)) (read (current-buffer)))))

(defun drgnx-ai-probe-fim (id model callback)
  "Does MODEL of provider ID fill in the middle?  CALLBACK gets t or nil (asynchronously)."
  (let ((p (drgnx-ai-provider id)))
    (pcase (plist-get p :kind)
      ('ollama (drgnx-ai--curl (concat (plist-get p :url) "/api/show")
                               (lambda (status text)
                                 (let ((json (and (eql status 200) (ignore-errors (json-parse-string text :object-type 'plist)))))
                                   (funcall callback (and (seq-contains-p (plist-get json :capabilities) "insert") t))))
                               :body (list :model model) :timeout 3))
      ('llamacpp (funcall callback t))                 ; /infill is llama-server's own
      ('tei (funcall callback nil))
      (_ (drgnx-ai--curl (concat (plist-get p :url) "/completions")
                         (lambda (status _) (funcall callback (and (<= 200 status 299) t)))
                         :body (list :model model :prompt "a" :suffix "b" :max_tokens 1)
                         :key (and (plist-get p :key-env) (drgnx-ai-key id)) :timeout 5)))))

;;;; The GPU

(defun drgnx-ai--parse-vram (text)
  "(:total MiB :used MiB) from nvidia-smi's \"TOTAL, USED\" line."
  (when (string-match "\\`\\s-*\\([0-9]+\\),\\s-*\\([0-9]+\\)" text)
    (list :total (string-to-number (match-string 1 text)) :used (string-to-number (match-string 2 text)))))

(defun drgnx-ai-vram ()
  "The memory models get (MiB): on macOS (:total M :used 0 :unified t), M two thirds of the RAM (`sysctl -n
hw.memsize'; Apple silicon shares it with the GPU); else the first GPU's when nvidia-smi is there; else nil."
  (if (eq (drgnx-platform) 'macos)
      (with-temp-buffer
        (when (eql 0 (ignore-errors (call-process "sysctl" nil t nil "-n" "hw.memsize")))
          (let ((bytes (string-to-number (string-trim (buffer-string)))))
            (when (> bytes 0) (list :total (/ (* 2 (/ bytes 1048576)) 3) :used 0 :unified t)))))
    (when (executable-find "nvidia-smi")
      (with-temp-buffer
        (when (eql 0 (call-process "nvidia-smi" nil t nil "--query-gpu=memory.total,memory.used" "--format=csv,noheader,nounits"))
          (drgnx-ai--parse-vram (buffer-string)))))))

(defun drgnx-ai-model-vram (model)
  "About how much GPU memory (MiB) MODEL needs at 4-bit, from the size in its name (\"…:1.5b\"), or 0."
  (if (and model (string-match "\\([0-9]+\\(?:\\.[0-9]+\\)?\\)[bB]\\b" model))
      (round (+ 500 (* 700 (string-to-number (match-string 1 model)))))
    0))

(provide 'drgnx-ai-probe)
;;; drgnx-ai-probe.el ends here
