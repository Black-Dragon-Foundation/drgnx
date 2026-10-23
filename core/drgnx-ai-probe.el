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
(require 'drgnx-file)
(require 'drgnx-timer)

(defvar drgnx-ai-detected nil "Alist provider → (:up BOOL :models (NAME…) :note TEXT) from the last probe.")

(defvar drgnx-ai-probe-done-hook nil "Run when a probe has its answers (what uses providers looks again).")

(defun drgnx-ai-detected-file () (expand-file-name "ai-detected.eld" (drgnx-state-dir)))

(defun drgnx-ai--save-detected (found)
  "Put FOUND ((PROVIDER . RESULT)…) into the saved alist, under its lock: what another Emacs found stays.
Runs in a process callback: never prompts, one lock attempt (a busy lock skips; the next probe writes), an
unreadable file is copied aside, and an error is one message."
  (condition-case err
      (let ((inhibit-interaction t))
        (make-directory (file-name-directory (drgnx-ai-detected-file)) t)
        (drgnx-file-update (drgnx-ai-detected-file)
                           (lambda (saved)
                             (let ((alist (and (proper-list-p saved) (seq-filter #'consp saved))))
                               (dolist (e found) (setf (alist-get (car e) alist) (cdr e)))
                               alist))
                           :on-unreadable 'backup :timeout 0))
    (drgnx-file-busy nil)
    (error (require 'drgnx-notice)
           (drgnx-notify 'agents 'warn (format "the AI probe's results were not saved: %s" (error-message-string err))))))

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
                   (drgnx-ai--save-detected found)
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
         (cond ((plist-get p :key-env) (drgnx-ai-key-held-p id interactive))   ; the hub's keys (`gateway/keys-held')
               ((drgnx-ai--local-p p) (plist-get (alist-get id drgnx-ai-detected) :up))
               (t t)))))

(defun drgnx-ai-detected-cached ()
  "The last probe's results as saved (the doctor runs in another Emacs)."
  (let ((data (plist-get (drgnx-file-read (drgnx-ai-detected-file)) :data)))
    (and (proper-list-p data) data)))

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
      (_ (let ((route (condition-case nil (drgnx-ai-route id) (drgnx-ai-gateway-unavailable nil))))   ; through the gateway
           (if (and (plist-get p :key-env) (null route)) (funcall callback nil)
             (drgnx-ai--curl (concat (plist-get route :url) "/completions")
                             (lambda (status _) (funcall callback (and (<= 200 status 299) t)))
                             :body (list :model model :prompt "a" :suffix "b" :max_tokens 1)
                             :key (plist-get route :key) :timeout 5)))))))

;;;; The GPU

(defun drgnx-ai--parse-vram (text)
  "(:total MiB :used MiB) from nvidia-smi's \"TOTAL, USED\" line."
  (when (string-match "\\`\\s-*\\([0-9]+\\),\\s-*\\([0-9]+\\)" text)
    (list :total (string-to-number (match-string 1 text)) :used (string-to-number (match-string 2 text)))))

(defun drgnx-ai-vram ()
  "The memory models get (MiB): on an Apple silicon Mac (`sysctl -n hw.optional.arm64' is 1) (:total M :used 0
:unified t), M two thirds of the RAM (`sysctl -n hw.memsize'; the GPU shares it); on an Intel Mac nil (its RAM is
not GPU memory); else the first GPU's when nvidia-smi is there; else nil."
  (if (eq (drgnx-platform) 'macos)
      (when (with-temp-buffer
              (and (eql 0 (ignore-errors (call-process "sysctl" nil t nil "-n" "hw.optional.arm64")))
                   (equal (string-trim (buffer-string)) "1")))
        (with-temp-buffer
          (when (eql 0 (ignore-errors (call-process "sysctl" nil t nil "-n" "hw.memsize")))
            (let ((bytes (string-to-number (string-trim (buffer-string)))))
              (when (> bytes 0) (list :total (/ (* 2 (/ bytes 1048576)) 3) :used 0 :unified t))))))
    (when (executable-find "nvidia-smi")
      (with-temp-buffer
        (when (eql 0 (call-process "nvidia-smi" nil t nil "--query-gpu=memory.total,memory.used" "--format=csv,noheader,nounits"))
          (drgnx-ai--parse-vram (buffer-string)))))))

(defun drgnx-ai-model-vram (model)
  "About how much GPU memory (MiB) MODEL needs at 4-bit, from the size in its name (\"…:1.5b\"), or 0."
  (if (and model (string-match "\\([0-9]+\\(?:\\.[0-9]+\\)?\\)[bB]\\b" model))
      (round (+ 500 (* 700 (string-to-number (match-string 1 model)))))
    0))

;;;; The local runner onboarding set up: started again when it is down (after a restart, a crash)

(declare-function drgnx-notify "drgnx-notice" (source severity text &rest args))
(declare-function drgnx-jobs-start "drgnx-jobs")
(declare-function drgnx-jobs-list "drgnx-jobs")

(defvar drgnx-ai-ensure-interval 60 "Seconds between two looks of `drgnx-ai-ensure-local'.")
(defvar drgnx-ai--ensure-time nil "When `drgnx-ai-ensure-local' last looked (`float-time').")

(defun drgnx-ai-local-file () (expand-file-name "ai-local.eld" (drgnx-state-dir)))

(defun drgnx-ai-managed ()
  "The local runner onboarding set up and drgnx keeps running: (PROVIDER :start COMMAND :name NAME), or nil."
  (let ((data (plist-get (drgnx-file-read (drgnx-ai-local-file)) :data)))
    (and (plistp data) (plist-get data :managed))))

(defun drgnx-ai-set-managed (provider command name)
  "Remember PROVIDER (NAME, for messages) as the local runner drgnx starts again with COMMAND (a list) when it is down.
The file is changed under its lock, keeping its other keys; one with a mistake is copied aside first."
  (make-directory (file-name-directory (drgnx-ai-local-file)) t)
  (drgnx-file-update (drgnx-ai-local-file)
                     (lambda (data)
                       (plist-put (and (plistp data) data) :managed (list provider :start command :name name)))
                     :on-unreadable 'backup))

(defvar drgnx-ai--ensure-looking nil
  "When (`float-time') a look of `drgnx-ai-ensure-local' began and has no answer yet: another one waits for it.")

(defun drgnx-ai--ensure-due-p ()
  (and (not noninteractive)
       (or (null drgnx-ai--ensure-time) (>= (- (float-time) drgnx-ai--ensure-time) drgnx-ai-ensure-interval))
       (not (and drgnx-ai--ensure-looking (< (- (float-time) drgnx-ai--ensure-looking) 10)))))

(defun drgnx-ai-ensure-local ()
  "Start the local runner onboarding set up (`drgnx-ai-managed') again when its address does not answer and no
drgnx job runs it already: the address is asked in the background and this returns at once.  Never prompts; a
look that finds it down starts it at most once a minute (one that finds it up counts for nothing); never in batch.
One message says what happens.  LM Studio without its lms command: the message says to open LM Studio."
  (when-let* (((drgnx-ai--ensure-due-p)) (m (drgnx-ai-managed)))
    (setq drgnx-ai--ensure-looking (float-time))
    (let ((id (car m)) (command (plist-get (cdr m) :start)) (name (or (plist-get (cdr m) :name) (symbol-name (car m)))))
      (drgnx-ai-probe
       (lambda ()
         (setq drgnx-ai--ensure-looking nil)
         ;; the probe's callback runs in a curl sentinel: the start is a timer's (the launcher's call-process
         ;; never runs under the sentinel's inhibit-quit), and does not wait for the job's pid
         (unless (plist-get (alist-get id drgnx-ai-detected) :up)
           (setq drgnx-ai--ensure-time (float-time))
           (run-at-time 0 nil #'drgnx-ai--start-local id command name)))
       (list id)))))

(defun drgnx-ai--start-local (id command name)
  "Start COMMAND, provider ID's runner (NAME), as a drgnx job unless one runs it already; one message.  From a
timer: never waits for the job (`:no-wait'), never asks."
  (require 'drgnx-jobs)
  (cond ((seq-find (lambda (j) (and (eq (plist-get j :status) 'running) (equal (plist-get j :command) command)))
                   (drgnx-jobs-list)))
        ((not (and (stringp (car command)) (file-executable-p (car command))))
         (require 'drgnx-notice)
         (drgnx-notify 'agents 'warn
                       (format "%s is not running — %s" name
                               (if (eq id 'lmstudio) "open LM Studio (its server starts with it)"
                                 (format "start it: %s" (string-join command " "))))
                       :id (cons 'ai-local id) :echo t))
        (t (message "Starting %s…" name)
           (with-demoted-errors "drgnx: the local AI server did not start: %S"
             (make-directory (drgnx-state-dir) t)
             (drgnx-jobs-start (format "%s server" name) command :cwd (drgnx-state-dir) :no-wait t)))))

(defun drgnx-ai--refused (id)
  "`drgnx-ai-refused-functions': nothing listened at ID — the runner drgnx keeps running is started again."
  (when (and (drgnx-ai--ensure-due-p) (eq id (car (drgnx-ai-managed)))) (drgnx-ai-ensure-local)))

(defun drgnx-ai--on-first-window ()
  "`drgnx-first-gui-frame-hook': the local runner looked at a moment after the first window shows, from an idle
timer — never inside the hook, never at daemon start (a daemon has no window until one is opened)."
  (drgnx-timer-start 'ai-first-window 1 #'drgnx-ai-ensure-local :idle t :owner :core))

(provide 'drgnx-ai-probe)
;;; drgnx-ai-probe.el ends here
