;;; quick-open-vertico-test.el --- Quick Open's shell under real vertico -*- lexical-binding: t -*-
;; test-class: det
;; Pattern D (pure): the listing is stubbed to its contract (batches in order, none after a stop), so no process and no timer;
;; the minibuffer is driven by simulated keys (`ert-simulate-keys'), with a few keys bound to lambdas that deliver a batch or
;; record what vertico shows.  Needs vertico (and compat) in DRGNX_USER_ELPA, as the extras tests do; skipped without.
(require 'ert)
(require 'ert-x)
(require 'cl-lib)
(require 'seq)
(require 'drgnx-quick-open)
(defvar vertico--candidates)
(defvar vertico-count)
(declare-function vertico-mode "vertico")
(declare-function vertico--candidate "vertico")

(defun drgnx-quick-open-vertico-test--packages ()
  "The package directories of DRGNX_USER_ELPA (read-only), or nil."
  (when-let* ((elpa (getenv "DRGNX_USER_ELPA")) ((file-directory-p elpa)))
    (seq-filter #'file-directory-p (directory-files (expand-file-name elpa) t "\\`[^.]"))))

(defun drgnx-quick-open-vertico-test--available-p (&rest libs)
  (let ((load-path (append load-path (drgnx-quick-open-vertico-test--packages))))
    (seq-every-p (lambda (l) (locate-library (symbol-name l))) (cons 'vertico libs))))

(defun drgnx-quick-open-vertico-test--run (styles)
  "Drive `drgnx-quick-open' under vertico with `completion-styles' STYLES: (LOG OPENED DIR).
LOG: (CANDIDATES HIGHLIGHTED) as vertico shows them at each <f5>, oldest first."
  (let* ((load-path (append load-path (drgnx-quick-open-vertico-test--packages)))
         (completion-styles styles) (completion-category-overrides nil) (completion-category-defaults nil)
         (vertico-count 20) log opened on-batch on-done
         (dir (file-name-as-directory (make-temp-file "drgnx-qo" t)))
         (default-directory dir))
    (require 'vertico)
    (unwind-protect
        (progn
          (vertico-mode 1)
          (let ((map (make-sparse-keymap)))
            (cl-flet ((feed (names) (funcall on-batch names)))
              (keymap-set map "<f1>" (lambda () (interactive) (feed '("src/main.el" "README.md" "docs/a.org"))))
              (keymap-set map "<f2>" (lambda () (interactive) (feed '("a.c" "lib/long/path/x.el"))))
              (keymap-set map "<f3>" (lambda () (interactive) (feed '("lib/main-extra.el" "main.c"))))
              (keymap-set map "<f4>" (lambda () (interactive) (funcall on-done t)))
              (keymap-set map "<f5>" (lambda () (interactive)
                                       (push (list (copy-sequence vertico--candidates) (vertico--candidate)) log))))
            (cl-letf (((symbol-function 'drgnx-file-stream-start)
                       (lambda (_root b d) (setq on-batch b on-done d) (drgnx-file-stream--make)))
                      ((symbol-function 'drgnx-file-stream-stop) #'ignore)
                      ((symbol-function 'find-file) (lambda (f &rest _) (setq opened f)))
                      ((symbol-function 'drgnx-quick-open--root) (lambda () dir))
                      ;; the simulated keys are all "pending input", and vertico does not update while input is pending
                      ((symbol-function 'input-pending-p) (lambda (&rest _) nil)))
              (minibuffer-with-setup-hook
                  (lambda () (use-local-map (make-composed-keymap map (current-local-map))))
                (ert-simulate-keys (vconcat (kbd "<f1> <f5> C-n <f5> <f2> <f5> m a i n <f5> <f3> <f5> <f4> RET"))
                                   (drgnx-quick-open))))))
      (vertico-mode -1)
      (delete-directory dir t))
    (list (nreverse log) opened dir)))

(defun drgnx-quick-open-vertico-test--check (styles)
  (pcase-let* ((`(,log ,opened ,dir) (drgnx-quick-open-vertico-test--run styles)))
    (should (= (length log) 5))
    (pcase-let ((`((,c1 ,h1) (,_ ,h2) (,c3 ,h3) (,c4 ,h4) (,c5 ,h5)) log))
      ;; the first batch is on screen at once, ranked, the best highlighted
      (should (equal (seq-take c1 3) '("README.md" "docs/a.org" "src/main.el")))
      (should (equal h1 "README.md"))
      ;; the user moves down: docs/a.org.  A second batch puts "a.c" on top of the list; the highlight stays on docs/a.org
      (should (equal h2 "docs/a.org"))
      (should (equal (car c3) "a.c"))
      (should (member "lib/long/path/x.el" c3))
      (should (equal h3 "docs/a.org"))
      ;; typing "main" filters to the names holding it and highlights the best of them
      (should (equal c4 '("src/main.el")))
      (should (equal h4 "src/main.el"))
      ;; a batch with a better match (main.c) sorts above it, and the highlight stays on src/main.el
      (should (equal (car c5) "main.c"))
      (should (member "lib/main-extra.el" c5))
      (should (equal h5 "src/main.el")))
    (should (equal opened (expand-file-name "src/main.el" dir)))))

(ert-deftest drgnx-quick-open/under-vertico-batches-arrive-the-highlight-stays-typing-filters ()
  "Pattern D: under real vertico (basic completion), batches add candidates while the highlight stays on its file, typing
filters and moves the highlight to the best match, and RET opens the highlighted file."
  (skip-unless (drgnx-quick-open-vertico-test--available-p))
  (drgnx-quick-open-vertico-test--check '(basic)))

(ert-deftest drgnx-quick-open/under-vertico-with-orderless ()
  "Pattern D: the same with the styles drgnx sets (orderless, then basic)."
  (skip-unless (drgnx-quick-open-vertico-test--available-p 'orderless))
  (let ((load-path (append load-path (drgnx-quick-open-vertico-test--packages))))
    (require 'orderless)
    (drgnx-quick-open-vertico-test--check '(orderless basic))))
