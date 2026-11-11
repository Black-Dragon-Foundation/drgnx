;;; debug-launch-test.el --- batch tests: debugging's configurations, picker, inputs and trust -*- lexical-binding: t -*-
;; test-class: det
;; The hub's answers are scripted (`drgnx-hub-call-sync' and `drgnx-hub-call' replaced for the test): what is tested
;; is what the editor asks, sends and shows.  The hub side has its own tests (Rust and conformance `debug/*').
(require 'ert)
(require 'cl-lib)
(require 'drgnx)
(load (expand-file-name "modules/extra/drgnx-debug-launch" drgnx-dir) nil t)

(defmacro debug-launch-test--with-hub (answers &rest body)
  "BODY with the hub answering each `debug/*' call from ANSWERS (METHOD → list of results, taken in turn); `calls'
holds (METHOD . PARAMS) of every call, in order."
  (declare (indent 1))
  `(let ((calls nil) (answers (copy-tree ,answers)))
     (cl-letf (((symbol-function 'drgnx-hub-call-sync)
                (lambda (method params &optional _timeout)
                  (setq calls (append calls (list (cons method params))))
                  (let ((queue (assoc method answers)))
                    (if (cdr queue) (pop (cdr queue)) t))))
               ((symbol-function 'drgnx-hub-call)
                (lambda (method params _cb &rest _)
                  (setq calls (append calls (list (cons method params))))))
               ((symbol-function 'drgnx-hub-running-p) (lambda () t)))
       ,@body)))

(ert-deftest drgnx-debug-launch/language-of-the-major-mode ()
  (should (equal (drgnx-debug-launch-language 'python-ts-mode) "python"))
  (should (equal (drgnx-debug-launch-language 'python-mode) "python"))
  (should (equal (drgnx-debug-launch-language 'c++-ts-mode) "c++"))
  (should (equal (drgnx-debug-launch-language 'typescript-ts-mode) "typescript"))
  (should-not (drgnx-debug-launch-language 'fundamental-mode)))

(ert-deftest drgnx-debug-launch/user-adapters-in-the-tables-fields ()
  (should (equal (drgnx-debug-launch--adapter
                  '(:id "mock" :name "Mock" :types ("mock") :not-built-in t :find (:python-module "m")
                        :start (:stdio ("{python}" "-m" "m"))))
                 '(:id "mock" :name "Mock" :types ["mock"] :not_built_in t :find (:python_module "m")
                       :start (:stdio ["{python}" "-m" "m"])))))

(ert-deftest drgnx-debug-launch/start-asks-trust-then-inputs ()
  "A root the hub was never told trusted: the trust card, Trust This Folder, then the input, then the session."
  (let ((drgnx-debug-configurations '((:type "python" :request "launch" :name "Mine")))
        (drgnx-debug-adapters nil) (trusted nil) (asked nil))
    (debug-launch-test--with-hub
        '(("debug/start" (:needs "trust")
           (:needs [(:input (:id "who" :kind "pickString" :description "Who" :options ["a" "b"] :password :false))])
           (:session "d1")))
      (cl-letf (((symbol-function 'drgnx-debug-launch-trusted-p) (lambda (_) trusted))
                ((symbol-function 'yes-or-no-p) (lambda (p) (push p asked) t))
                ((symbol-function 'drgnx-trust-folder) (lambda (_) (setq trusted t)))
                ((symbol-function 'completing-read)
                 (lambda (prompt coll &rest _) (push prompt asked) (should (equal coll '("a" "b"))) "b")))
        (with-temp-buffer
          (should (equal (drgnx-debug-launch-start "/p" "launch:0") "d1"))))
      (should (= (length asked) 2))
      (should (string-match-p "/p is not trusted" (cadr asked)))
      (should (equal (car asked) "Who: "))
      (should (equal (mapcar #'car calls) '("debug/start" "debug/trust" "debug/start" "debug/start")))
      (let ((last (cdar (last calls))))
        (should (equal (plist-get last :inputs) [(:id "who" :value "b")]))
        (should (equal (plist-get last :config) "launch:0"))
        (should (equal (plist-get last :user) [(:type "python" :request "launch" :name "Mine")]))))))

(ert-deftest drgnx-debug-launch/declined-trust-starts-nothing ()
  (debug-launch-test--with-hub '(("debug/start" (:needs "trust")))
    (cl-letf (((symbol-function 'drgnx-debug-launch-trusted-p) #'ignore)
              ((symbol-function 'yes-or-no-p) #'ignore)
              ((symbol-function 'drgnx-trust-folder) (lambda (_) (error "Not asked"))))
      (with-temp-buffer
        (should-error (drgnx-debug-launch-start "/p" "launch:0") :type 'user-error)))
    (should (equal (mapcar #'car calls) '("debug/start")))))

(ert-deftest drgnx-debug-launch/pick-process-sends-the-pid ()
  (debug-launch-test--with-hub '(("debug/start" (:needs ["pickProcess"]) (:session "d2")))
    (cl-letf (((symbol-function 'drgnx-debug-launch-trusted-p) #'always)
              ((symbol-function 'drgnx-debug-launch--processes) (lambda () '(("42  py  py app.py" . 42))))
              ((symbol-function 'completing-read) (lambda (&rest _) "42  py  py app.py")))
      (with-temp-buffer (should (equal (drgnx-debug-launch-start "/p" "launch:1") "d2"))))
    (should (equal (plist-get (cdar (last calls)) :inputs) [(:id "pickProcess" :value "42")]))))

(ert-deftest drgnx-debug-launch/a-broken-launch-json-opens-where-it-fails ()
  (let* ((dir (make-temp-file "dbg" t)) (file (expand-file-name ".vscode/launch.json" dir)))
    (unwind-protect
        (progn
          (make-directory (file-name-directory file) t)
          (with-temp-file file (insert "{\n  \"configurations\": [\n    {,}\n  ]\n}\n"))
          (debug-launch-test--with-hub
              `(("debug/configs" (:configs [] :error (:path ,file :line 3 :col 6 :message "unexpected ,"))))
            (cl-letf (((symbol-function 'drgnx-debug-launch-trusted-p) #'ignore))
              (with-temp-buffer
                (should-error (drgnx-debug-launch-read-config dir) :type 'user-error))
              (let ((b (find-buffer-visiting file)))
                (should b)
                (with-current-buffer b
                  (should (= (line-number-at-pos) 3))
                  (should (= (current-column) 5)))
                (kill-buffer b)))))
      (delete-directory dir t))))

(ert-deftest drgnx-debug-launch/the-picker-offers-the-last-choice-first ()
  (debug-launch-test--with-hub
      '(("debug/configs" (:configs [(:id "launch:0" :name "A" :source "launch" :type "python" :needs_trust :false)
                                    (:id "default:0" :name "B" :source "default" :type "go" :needs_trust t)]
                                   :last "default:0")))
    (cl-letf (((symbol-function 'drgnx-debug-launch-trusted-p) #'always)
              ((symbol-function 'completing-read)
               (lambda (_p coll _pred _req _init _hist def)
                 (should (equal def "B"))
                 (should (equal (mapcar #'car coll) '("A" "B")))
                 (should (string-match-p "not trusted"
                                         (funcall (plist-get completion-extra-properties :annotation-function) "B")))
                 "A")))
      (with-temp-buffer (should (equal (drgnx-debug-launch-read-config "/p") "launch:0"))))
    ;; trusted: the hub is told before it lists
    (should (equal (mapcar #'car calls) '("debug/trust" "debug/configs")))))

(ert-deftest drgnx-debug-launch/taking-trust-back-tells-the-hub ()
  (debug-launch-test--with-hub nil
    (drgnx-debug-launch-trust-changed "/p/" nil)
    (should (equal calls '(("debug/trust" :root "/p" :trusted nil))))))

(ert-deftest drgnx-debug-launch/trust-changes-run-the-hook ()
  (require 'drgnx-trust)
  (let* ((seen nil)
         (drgnx-trust-changed-functions (list (lambda (f trusted) (push (cons f trusted) seen))))
         (home (make-temp-file "home" t))
         (dir (file-name-as-directory (expand-file-name "proj" home))))
    (unwind-protect
        (cl-letf (((symbol-function 'drgnx-trust-folders-file) (lambda () (expand-file-name "tf.eld" home)))
                  ((symbol-function 'drgnx-trust--refresh) #'ignore)
                  (trusted-content nil) (drgnx-trust--added nil))
          (make-directory dir t)
          (let ((e (drgnx-trust-folder dir)))
            (drgnx-trust-untrust-folder dir)
            (should (equal seen (list (cons e nil) (cons e t))))))
      (delete-directory home t))))

(ert-deftest drgnx-debug-launch/dape-configs-convert-once ()
  (let ((r (drgnx-debug-launch-convert-dape
            `((debugpy-here modes (python-mode) command "python3" command-args ("-m" "debugpy.adapter")
                            :type "python" :request "launch" :program ,(lambda () "/p/app.py") :cwd "/p")
              (no-type command "x" :request "launch")
              (attach-go :type "go" :request "attach" :processId 7)))))
    (should (equal (car r)
                   '((:name "debugpy-here" :type "python" :request "launch" :program "/p/app.py" :cwd "/p")
                     (:name "attach-go" :type "go" :request "attach" :processId 7))))
    (should (equal (cdr r) '(("no-type" . "no :type"))))))

;;; debug-launch-test.el ends here
