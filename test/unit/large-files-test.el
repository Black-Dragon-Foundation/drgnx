;;; large-files-test.el --- batch tests: large files — the config, its project file, the decision, the answers -*- lexical-binding: t -*-
;; Every test that reads the config runs under `drgnx-test-with-config' and sets the module up and tears it down
;; (`drgnx-test-with-modules' :strict t).  No large file is ever written: thresholds are fractions of a MiB.
(require 'ert)
(require 'cl-lib)
(require 'drgnx)
(require 'drgnx-guard)
(require 'files)
;; loaded before a strict module run: a remote name's `file-remote-p' would load them there
(require 'tramp)
(require 'tramp-cache)
(load (expand-file-name "test/fixtures/config-fixture" drgnx-dir) nil t)
(load (expand-file-name "test/fixtures/modules-fixture" drgnx-dir) nil t)
(load (expand-file-name "modules/editor/drgnx-large-files" drgnx-dir) nil t)

(defvar drgnx-large-file-open)

(defmacro drgnx-large-files-test--with (&rest body)
  "BODY with the module editor/large-files set up, in a fresh config folder; torn down after, strictly."
  (declare (indent 0) (debug t))
  `(drgnx-test-with-config
     (drgnx-test-with-modules '(editor/large-files) :strict t
                              ,@body)))

(defun drgnx-large-files-test--project (text)
  "A fresh project folder (under the test's config root) whose .drgnx/large-files.eld holds TEXT; its name."
  (let ((root (file-name-as-directory (make-temp-file (expand-file-name "proj" drgnx-test-config-root) t))))
    (make-directory (expand-file-name "sub" root) t)
    (drgnx-test-config-put 'large-files-project text root)
    root))

;;;; The decision

(ert-deftest drgnx-large-files/decide-table ()
  ;; :ask-above 16 KiB, :chunks-above 64 KiB; sizes below, between and above them
  (let ((th '(:ask-above 16384 :chunks-above 65536 :chunk-size 32768))
        (sizes '(1000 32768 131072))
        ;; (HOW REMEMBERED CHUNKS-OK BELOW BETWEEN ABOVE)
        (rows '((command nil    t   pass (ask . lean) (ask . chunks))
                (command nil    nil pass (ask . lean) (ask . raw))
                (command lean   t   pass lean lean)
                (command lean   nil pass lean lean)
                (command raw    t   pass raw raw)
                (command raw    nil pass raw raw)
                (command chunks t   pass chunks chunks)
                (command chunks nil pass raw raw)
                (auto    nil    t   pass chunks chunks)
                (auto    nil    nil pass raw raw)
                (auto    lean   t   pass lean lean)
                (auto    lean   nil pass lean lean)
                (auto    raw    t   pass raw raw)
                (auto    raw    nil pass raw raw)
                (auto    chunks t   pass chunks chunks)
                (auto    chunks nil pass raw raw)
                (whole   nil    t   pass lean lean)
                (whole   nil    nil pass lean lean)
                (whole   lean   t   pass lean lean)
                (whole   lean   nil pass lean lean)
                (whole   raw    t   pass lean lean)
                (whole   raw    nil pass lean lean)
                (whole   chunks t   pass lean lean)
                (whole   chunks nil pass lean lean))))
    (should (= (length rows) 24))
    (dolist (row rows)
      (pcase-let ((`(,how ,remembered ,ok . ,want) row))
        (cl-mapc (lambda (size expected)
                   (should (equal (list how remembered ok size
                                        (drgnx-large-files--decide size how remembered th ok))
                                  (list how remembered ok size expected))))
                 sizes want)))
    ;; exactly at a threshold is still below it
    (should (eq (drgnx-large-files--decide 16384 'command nil th t) 'pass))
    (should (equal (drgnx-large-files--decide 65536 'command nil th t) '(ask . lean)))
    ;; :ask-above nil: never ask, never lean
    (dolist (how '(command auto whole))
      (should (eq (drgnx-large-files--decide (* 1024 1048576) how 'chunks '(:ask-above nil :chunks-above 1 :chunk-size 1) t)
                  'pass)))))

(ert-deftest drgnx-large-files/how-in-context ()
  (with-temp-buffer
    (let ((this-command nil)) (should (eq (drgnx-large-files--how) 'auto)))
    (let ((this-command 'find-file)) (should (eq (drgnx-large-files--how) 'command)))
    (let ((this-command 'find-file))
      (drgnx-automatic (should (eq (drgnx-large-files--how) 'auto)))
      (let ((drgnx-guard--timer-fn 'some-timer-fn)) (should (eq (drgnx-large-files--how) 'auto)))
      (let ((inhibit-interaction t)) (should (eq (drgnx-large-files--how) 'auto)))
      ;; a caller's binding wins, whatever the context
      (let ((drgnx-large-file-open 'whole)) (should (eq (drgnx-large-files--how) 'whole)))
      (let ((drgnx-large-file-open 'auto)) (should (eq (drgnx-large-files--how) 'auto)))
      (setq-local drgnx-large-file-open 'whole)
      (should (eq (drgnx-large-files--how) 'whole))
      (with-temp-buffer (should (eq (drgnx-large-files--how) 'command))))
    (let ((this-command nil) (drgnx-large-file-open 'whole))
      (should (eq (drgnx-large-files--how) 'whole)))))

(ert-deftest drgnx-large-files/sizes-are-mib-above-zero ()
  (should (drgnx-large-files--mib-p 50))
  (should (drgnx-large-files--mib-p 0.015625))
  (should-not (drgnx-large-files--mib-p 0))
  (should-not (drgnx-large-files--mib-p -1))
  (should-not (drgnx-large-files--mib-p 1.0e+INF))
  (should-not (drgnx-large-files--mib-p 0.0e+NaN))
  (should-not (drgnx-large-files--mib-p "50"))
  (should (equal (drgnx-large-files--size-text 432013312) "412 MB")))

;;;; The config and the project file

(ert-deftest drgnx-large-files/the-defaults ()
  (drgnx-large-files-test--with
    (should (equal (drgnx-large-files-thresholds (expand-file-name "a.log" drgnx-test-config-root))
                   (list :ask-above (* 50 1048576) :chunks-above (* 500 1048576) :chunk-size 1048576)))))

(ert-deftest drgnx-large-files/a-project-only-lowers ()
  (drgnx-large-files-test--with
    (drgnx-test-config-put 'large-files "(:version 1 :ask-above 0.25 :chunks-above 1 :chunk-size 0.03125)")
    ;; lower: applied
    (let ((root (drgnx-large-files-test--project "(:version 1 :ask-above 0.015625 :chunks-above 0.0625)")))
      (should (equal (drgnx-large-files-thresholds (expand-file-name "sub/big.log" root))
                     '(:ask-above 16384 :chunks-above 65536 :chunk-size 32768))))
    ;; higher: ignored, one key at a time
    (let ((root (drgnx-large-files-test--project "(:version 1 :ask-above 5000 :chunks-above 0.5)")))
      (should (equal (drgnx-large-files-thresholds (expand-file-name "sub/big.log" root))
                     '(:ask-above 262144 :chunks-above 524288 :chunk-size 32768))))
    ;; outside a project: the user's
    (should (equal (drgnx-large-files-thresholds (expand-file-name "elsewhere.log" temporary-file-directory))
                   '(:ask-above 262144 :chunks-above 1048576 :chunk-size 32768)))))

(ert-deftest drgnx-large-files/a-project-nil-is-ignored ()
  (drgnx-large-files-test--with
    (let ((root (drgnx-large-files-test--project "(:version 1 :ask-above nil :chunks-above 0.0625)")))
      (should (equal (drgnx-large-files-thresholds (expand-file-name "sub/big.log" root))
                     (list :ask-above (* 50 1048576) :chunks-above 65536 :chunk-size 1048576)))
      (should-not (drgnx-config-problem 'large-files-project root)))))

(ert-deftest drgnx-large-files/a-user-nil-ignores-the-project ()
  (drgnx-large-files-test--with
    (drgnx-test-config-put 'large-files "(:version 1 :ask-above nil)")
    (let ((root (drgnx-large-files-test--project "(:version 1 :ask-above 0.015625)")))
      (cl-letf (((symbol-function 'locate-dominating-file)
                 (lambda (&rest _) (error "The project file was looked for"))))
        (should (equal (drgnx-large-files-thresholds (expand-file-name "sub/big.log" root))
                       (list :ask-above nil :chunks-above (* 500 1048576) :chunk-size 1048576)))))))

(ert-deftest drgnx-large-files/a-project-chunk-size-is-ignored ()
  (drgnx-large-files-test--with
    (let ((root (drgnx-large-files-test--project "(:version 1 :chunk-size 0.001)")))
      (should (= (plist-get (drgnx-large-files-thresholds (expand-file-name "sub/big.log" root)) :chunk-size)
                 1048576)))))

(ert-deftest drgnx-large-files/a-malformed-project-file-is-ignored-with-one-problem ()
  (drgnx-large-files-test--with
    (let ((root (drgnx-large-files-test--project "(:version 1 :ask-above \"tiny\" :chunks-above 0.0625)"))
          (said 0))
      (cl-letf* ((orig (symbol-function 'message))
                 ((symbol-function 'message)
                  (lambda (fmt &rest args)
                    (when (and (stringp fmt) (string-search "large-files.eld" (apply #'format fmt args)))
                      (cl-incf said))
                    (apply orig fmt args))))
        (dotimes (_ 2)
          (should (equal (drgnx-large-files-thresholds (expand-file-name "sub/big.log" root))
                         (list :ask-above (* 50 1048576) :chunks-above (* 500 1048576) :chunk-size 1048576)))))
      (should (= (length (seq-filter (lambda (p) (eq (plist-get p :name) 'large-files-project))
                                     (drgnx-config-problems)))
                 1))
      (should (<= said 1)))))

(ert-deftest drgnx-large-files/the-threshold-follows-the-file ()
  (let ((before large-file-warning-threshold))
    (drgnx-large-files-test--with
      (should (= large-file-warning-threshold (* 50 1048576)))
      (drgnx-test-config-put 'large-files "(:version 1 :ask-above 1)")
      (drgnx-config-get 'large-files)
      (should (= large-file-warning-threshold 1048576))
      (drgnx-test-config-put 'large-files "(:version 1 :ask-above nil)")
      (drgnx-config-get 'large-files)
      (should (null large-file-warning-threshold)))
    (should (equal large-file-warning-threshold before))))

;;;; The remembered answers

(ert-deftest drgnx-large-files/a-remote-name-is-its-own-key ()
  (drgnx-large-files-test--with
    (cl-letf (((symbol-function 'file-truename) (lambda (&rest _) (error "file-truename on a remote name")))
              ((symbol-function 'locate-dominating-file) (lambda (&rest _) (error "Looked for a remote project"))))
      (should (equal (drgnx-large-files--key "/ssh:host.invalid:/var/log/big.log") "/ssh:host.invalid:/var/log/big.log"))
      (drgnx-large-files-remember "/ssh:host.invalid:/var/log/big.log" 'raw)
      (should (eq (drgnx-large-files-remembered "/ssh:host.invalid:/var/log/big.log") 'raw))
      (should (= (plist-get (drgnx-large-files-thresholds "/ssh:host.invalid:/var/log/big.log") :ask-above)
                 (* 50 1048576))))
    ;; a local name is its truename: a link and its target share an answer
    (let* ((dir (file-name-as-directory (make-temp-file "drgnx-lf-key" t)))
           (target (expand-file-name "real.log" dir))
           (link (expand-file-name "link.log" dir)))
      (unwind-protect
          (progn
            (write-region "x" nil target nil 'silent)
            (make-symbolic-link target link)
            (drgnx-large-files-remember link 'lean)
            (should (eq (drgnx-large-files-remembered target) 'lean)))
        (delete-directory dir t)))))

(ert-deftest drgnx-large-files/answers-are-capped-at-256 ()
  (drgnx-large-files-test--with
    (dotimes (i 300)
      (drgnx-large-files-remember (format "/ssh:h.invalid:/f%d" i) 'chunks))
    (should (= (drgnx-cache-size 'drgnx-large-files--answers) 256))
    (should (eq (drgnx-large-files-remembered "/ssh:h.invalid:/f299") 'chunks))
    (should-not (drgnx-large-files-remembered "/ssh:h.invalid:/f0"))))

;;;; The module

(ert-deftest drgnx-large-files/off-on-off-leaves-nothing ()
  (let ((before large-file-warning-threshold))
    (dotimes (_ 2)
      (drgnx-large-files-test--with
        (should (drgnx-config-defined-p 'large-files))
        (should (drgnx-config-defined-p 'large-files-project))
        (drgnx-large-files-remember "/ssh:h.invalid:/big" 'raw)
        (should (eq (drgnx-large-files-remembered "/ssh:h.invalid:/big") 'raw)))
      (should-not (drgnx-config-defined-p 'large-files))
      (should-not (drgnx-config-defined-p 'large-files-project))
      (should (= (drgnx-cache-size 'drgnx-large-files--answers) 0))
      (should (equal large-file-warning-threshold before)))))

;;; large-files-test.el ends here
