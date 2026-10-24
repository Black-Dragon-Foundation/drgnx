;;; settings-history-test.el --- batch tests: every settings change is recorded with who made it; undo; the journal -*- lexical-binding: t -*-
;; A fake hub: `drgnx-hub-call' collects (METHOD PARAMS) in `drgnx-sht--sent' (or fails with `drgnx-sht--down'),
;; `drgnx-hub-call-sync' answers from `drgnx-sht--model' (option id -> versions, oldest first).  Everything runs under
;; a temp config and state folder (`drgnx-test-with-config').
(require 'ert)
(require 'cl-lib)
(require 'drgnx-paths)
(load (expand-file-name "test/fixtures/config-fixture" drgnx-dir) nil t)
(require 'drgnx-settings-history)
(require 'drgnx-notice)                 ; loaded now, so the fake `drgnx-notify' below is not replaced by a late load

(defvar drgnx-sht--sent nil "(METHOD PARAMS) the fake hub took, newest first.")
(defvar drgnx-sht--down nil "Non-nil: the hub is away (`drgnx-hub-call' signals).")
(defvar drgnx-sht--model nil "Option id -> versions, oldest first: plists (:ver :tx :tool :actor :data).")
(defvar drgnx-sht--said nil "The notices said: (TEXT . PLIST).")

(defmacro drgnx-sht--with (&rest body)
  (declare (indent 0))
  `(let ((drgnx-sht--sent nil) (drgnx-sht--down nil) (drgnx-sht--model nil) (drgnx-sht--said nil)
         (drgnx-settings-history--ours (make-hash-table :test 'equal))
         (drgnx-settings-history--lisp-done nil) (drgnx-settings-history--warned nil)
         (drgnx-settings-history--reverts nil) (drgnx-settings-history--pending nil)
         (drgnx-settings-history-journal-max (* 1024 1024)))
     (drgnx-test-with-config
       (cl-letf (((symbol-function 'drgnx-hub-call)
                  (lambda (method params callback &rest _)
                    (when drgnx-sht--down (error "no hub"))
                    (push (list method params) drgnx-sht--sent)
                    (funcall callback '(:tx 1) nil)
                    1))
                 ((symbol-function 'drgnx-hub-call-sync)
                  (lambda (method params &optional _timeout) (drgnx-sht--answer method params)))
                 ((symbol-function 'drgnx-notify)
                  (lambda (_source _severity text &rest args) (push (cons text args) drgnx-sht--said))))
         ,@body))))

(defun drgnx-sht--answer (method params)
  (pcase method
    ("graph/history" (list :versions (mapcar (lambda (v) (cl-remove-if (lambda (x) (eq x :data)) v) )
                                             (drgnx-sht--versions (plist-get params :id)))))
    ("graph/entity"
     (let ((v (car (last (cl-remove-if (lambda (v) (> (plist-get v :tx) (plist-get params :as_of)))
                                       (drgnx-sht--versions (plist-get params :id)))))))
       (list :entity (list :id (plist-get params :id) :data (plist-get v :data)))))
    (_ (error "unexpected %s" method))))

(defun drgnx-sht--versions (id) (cdr (assoc id drgnx-sht--model)))

(defun drgnx-sht--records () (reverse (cl-remove-if-not (lambda (s) (equal (car s) "settings/record")) drgnx-sht--sent)))

(defun drgnx-sht--file () (drgnx-config-file 'settings))

(defun drgnx-sht--put (var value)
  (drgnx-settings-file-put (drgnx-sht--file) 'drgnx-settings nil var value))

(ert-deftest drgnx-settings-history/a-ui-change-records-once ()
  (drgnx-sht--with
    (drgnx-sht--put 'fill-column 80)
    (let* ((recs (drgnx-sht--records)) (p (cadr (car recs))) (c (car (plist-get p :changes))))
      (should (= 1 (length recs)))
      (should (equal (plist-get p :tool) "ui:settings"))
      (should (equal (plist-get c :id) "option:global:fill-column"))
      (should (equal (plist-get c :value) "80"))
      (should (equal (plist-get c :file) (expand-file-name (drgnx-sht--file))))
      (should (stringp (plist-get p :req)))
      (should-not (plist-member p :reverts)))
    ;; the same value again writes nothing, and the sync that follows our own write is no outside change
    (drgnx-sht--put 'fill-column 80)
    (drgnx-settings-history--changed (drgnx-sht--file) '((nil fill-column :unset 80)))
    (should (= 1 (length (drgnx-sht--records))))
    ;; a removal has no value
    (drgnx-settings-file-remove (drgnx-sht--file) 'drgnx-settings nil 'fill-column)
    (let ((c (car (plist-get (cadr (cadr (drgnx-sht--records))) :changes))))
      (should (equal (plist-get c :id) "option:global:fill-column"))
      (should-not (plist-get c :value)))))

(ert-deftest drgnx-settings-history/a-hand-edit-records-as-outside ()
  (drgnx-sht--with
    (drgnx-sht--put 'fill-column 80)
    (setq drgnx-sht--sent nil)
    (drgnx-test-config-put 'settings "(drgnx-settings\n :version 1\n (fill-column 100))\n")
    (drgnx-settings-history--changed (drgnx-sht--file) '((nil fill-column 80 100)))
    (let* ((p (cadr (car (drgnx-sht--records)))) (c (car (plist-get p :changes))))
      (should (equal (plist-get p :tool) "file:settings.el"))
      (should (equal (plist-get c :value) "100"))
      (should (= 3 (plist-get c :line))))
    ;; the same stamp is reported once
    (drgnx-settings-history--changed (drgnx-sht--file) '((nil fill-column 80 100)))
    (should (= 1 (length (drgnx-sht--records))))))

(ert-deftest drgnx-settings-history/a-repository-change-goes-through-put-parsed ()
  (drgnx-sht--with
    (let* ((root (file-name-as-directory (make-temp-file "sht-repo" t)))
           (file (expand-file-name ".drgnx/settings.el" root)))
      (unwind-protect
          (progn
            (make-directory (file-name-directory file) t)
            (write-region "(drgnx-workspace-settings\n :version 1\n (fill-column 72))\n" nil file nil 'silent)
            (drgnx-settings-history--changed file '((nil fill-column :unset 72)))
            (should-not (drgnx-sht--records))
            (let* ((sent (car drgnx-sht--sent)) (p (cadr sent))
                   (s (car (plist-get p :sources))))
              (should (equal (car sent) "graph/put-parsed"))
              (should (equal (plist-get p :root) (directory-file-name root)))
              (should (equal (plist-get (plist-get s :source) :kind) "file"))
              (should (= 1 (length (plist-get s :entities)))))     ; no project known: only the file
            (setq drgnx-sht--sent nil)
            (write-region "(drgnx-workspace-settings\n :version 1\n (fill-column 80))\n" nil file nil 'silent)
            (set-file-times file (time-add (current-time) 5))
            (cl-letf (((symbol-function 'drgnx-settings-workspace-project)
                       (lambda (_dir) (cons "project:alpha" root))))
              (drgnx-settings-history--changed file '((nil fill-column 72 80))))
            (let* ((s (car (plist-get (cadr (car drgnx-sht--sent)) :sources)))
                   (o (cadr (plist-get s :entities))))
              (should (equal (plist-get o :id) "option:shared/alpha:fill-column"))
              (should (equal (plist-get (plist-get o :data) :value) "80"))))
        (delete-directory root t)))))

(ert-deftest drgnx-settings-history/the-journal-is-bounded-and-flushes ()
  (drgnx-sht--with
    (setq drgnx-sht--down t)
    (let ((drgnx-settings-history-journal-max 900))
      (dotimes (i 8) (drgnx-sht--put 'fill-column (+ 70 i)))
      (should (file-exists-p (drgnx-settings-history--journal-file)))
      (should (<= (file-attribute-size (file-attributes (drgnx-settings-history--journal-file))) 900))
      (let ((n (length (drgnx-settings-history--journal-read))))
        (should (and (> n 0) (< n 8)))
        (should (cl-some (lambda (s) (string-match-p "journal is full" (car s))) drgnx-sht--said))
        (should (= 1 (cl-count-if (lambda (s) (string-match-p "journal is full" (car s))) drgnx-sht--said)))
        (setq drgnx-sht--down nil)
        (drgnx-settings-history-flush)
        (should (= n (length (drgnx-sht--records))))
        (should-not (file-exists-p (drgnx-settings-history--journal-file)))))))

(ert-deftest drgnx-settings-history/lisp-effect-once-per-start ()
  (drgnx-sht--with
    (let ((value 80))
      (cl-letf (((symbol-function 'drgnx-settings-prov--managed) (lambda () '(fill-column)))
                ((symbol-function 'drgnx-settings-explain)
                 (lambda (_var &optional _b) (list :kind 'lisp :value value :file "/x/config.el" :line 4))))
        (should (= 1 (drgnx-settings-history-record-lisp)))
        (let ((p (cadr (car (drgnx-sht--records)))))
          (should (equal (plist-get p :tool) "lisp:config.el"))
          (should (equal (plist-get (car (plist-get p :changes)) :value) "80")))
        ;; once per start
        (should-not (drgnx-settings-history-record-lisp))
        ;; a new start, the same value: nothing; a different value: one more
        (setq drgnx-settings-history--lisp-done nil)
        (should (= 0 (drgnx-settings-history-record-lisp)))
        (setq drgnx-settings-history--lisp-done nil value 90)
        (should (= 1 (drgnx-settings-history-record-lisp)))
        (should (= 2 (length (drgnx-sht--records))))))))

(ert-deftest drgnx-settings-history/a-security-setting-changed-outside-notifies ()
  (drgnx-sht--with
    (drgnx-sht--put 'fill-column 80)
    (drgnx-test-config-put 'settings "(drgnx-settings\n :version 1\n (fill-column 100))\n")
    (cl-letf (((symbol-function 'drgnx-setting-meta) (lambda (_var) '(:agents never))))
      (drgnx-settings-history--changed (drgnx-sht--file) '((nil fill-column 80 100))))
    (let ((n (cl-find-if (lambda (s) (string-match-p "changed outside drgnx \\[Undo\\]" (car s))) drgnx-sht--said)))
      (should n)
      (should (string-prefix-p "fill-column" (car n)))
      (should (equal (plist-get (cdr n) :command) '(drgnx-settings-undo "option:global:fill-column"))))))

(ert-deftest drgnx-settings-history/undo-writes-and-records-reverts ()
  (drgnx-sht--with
    (let ((id "option:global:fill-column") (file nil))
      (drgnx-sht--put 'fill-column 100)
      (setq file (expand-file-name (drgnx-sht--file)))
      (setq drgnx-sht--sent nil
            drgnx-sht--model
            (list (cons id (list (list :ver 1 :tx 1 :tool "ui:settings" :actor "user" :data (list :value "80" :file file :line 3))
                                 (list :ver 2 :tx 2 :tool "ui:settings" :actor "user" :data (list :value "100" :file file :line 3))))))
      (should (drgnx-settings-undo id))
      (should (equal (drgnx-settings-doc-entries-values) '((fill-column . 80))))
      (let ((recs (drgnx-sht--records)))
        (should (= 1 (length recs)))
        (should (= 2 (plist-get (cadr (car recs)) :reverts)))
        (should (equal (plist-get (cadr (car recs)) :tool) "ui:settings"))
        (should (equal (plist-get (car (plist-get (cadr (car recs)) :changes)) :value) "80")))
      ;; the first version: undoing it takes the setting out
      (setq drgnx-sht--sent nil
            drgnx-sht--model (list (cons id (list (list :ver 1 :tx 7 :tool "ui:settings" :actor "user"
                                                        :data (list :value "80" :file file :line 3))))))
      (drgnx-settings-undo id)
      (should (equal (drgnx-settings-doc-entries-values) nil))
      (should (= 7 (plist-get (cadr (car (drgnx-sht--records))) :reverts))))))

(defun drgnx-settings-doc-entries-values ()
  "settings.el's (VAR . VALUE) entries now."
  (mapcar (lambda (e) (cons (drgnx-settings-entry-var e) (drgnx-settings-entry-value e)))
          (drgnx-settings-doc-entries (drgnx-settings-file-read (drgnx-sht--file) 'drgnx-settings))))

(ert-deftest drgnx-settings-history/lisp-changes-cannot-be-undone ()
  (drgnx-sht--with
    (let ((id "option:global:fill-column") file)
      (drgnx-sht--put 'fill-column 100)
      (setq file (expand-file-name (drgnx-sht--file)))
      (setq drgnx-sht--sent nil
            drgnx-sht--model
            (list (cons id (list (list :ver 1 :tx 1 :tool "ui:settings" :actor "user" :data (list :value "80" :file file))
                                 (list :ver 2 :tx 2 :tool "lisp:config.el" :actor "user"
                                       :data (list :value "100" :file "/x/config.el" :line 5))))))
      (should-error (drgnx-settings-undo id) :type 'user-error)
      (should (equal (drgnx-settings-doc-entries-values) '((fill-column . 100))))
      (should-not drgnx-sht--sent)
      (let ((n (cl-find-if (lambda (s) (string-match-p "\\[Open\\]" (car s))) drgnx-sht--said)))
        (should n)
        (should (equal (plist-get (cdr n) :command) '(drgnx-settings-history-open "/x/config.el" 5)))))))

(provide 'settings-history-test)
;;; settings-history-test.el ends here
