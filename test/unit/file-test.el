;;; file-test.el --- batch tests: the bounded reader, the atomic writer and the locked update -*- lexical-binding: t -*-
;; Every file lives in a fresh temp folder.  The lock's clock and sleep go through the seams `drgnx-file--now' and
;; `drgnx-file--sleep'; nothing here sleeps.  The concurrency test starts two batch Emacsen with this Emacs's
;; environment and waits for them under a 30 s bound.
(require 'ert)
(require 'cl-lib)
(require 'drgnx-file)

(defmacro drgnx-file-test--with-dir (var &rest body)
  "BODY with VAR bound to a fresh temp folder (with a trailing slash), deleted afterwards."
  (declare (indent 1))
  `(let ((,var (file-name-as-directory (make-temp-file "drgnx-file-test" t))))
     (unwind-protect (progn ,@body) (delete-directory ,var t))))

(defun drgnx-file-test--put (file text)
  "Write TEXT to FILE as UTF-8, quietly."
  (let ((coding-system-for-write 'utf-8-unix)) (write-region text nil file nil 'silent)))

(defun drgnx-file-test--bytes (file)
  "FILE's bytes."
  (with-temp-buffer (set-buffer-multibyte nil) (insert-file-contents-literally file) (buffer-string)))

(defun drgnx-file-test--leftovers (dir)
  "Temp files, locks and stolen locks left in DIR."
  (directory-files dir nil "\\.tmp-\\|\\.lock"))

(defun drgnx-file-test--hold (file owner)
  "Make FILE's lock directory, as another drgnx would, with the OWNER plist in it."
  (let ((lock (expand-file-name (concat "." (file-name-nondirectory file) ".lock") (file-name-directory file))))
    (make-directory lock)
    (drgnx-file-test--put (expand-file-name "owner" lock) (prin1-to-string owner))
    lock))

(defun drgnx-file-test--live-owner ()
  "The owner plist of a lock this very Emacs holds."
  (list :pid (emacs-pid) :host (system-name) :started (drgnx-file--pid-start (emacs-pid)) :time (drgnx-file--now)))

(defun drgnx-file-test--add (item)
  "An update function adding ITEM to :items."
  (lambda (d) (list :items (cons item (plist-get d :items)))))

;;;; Reads

(ert-deftest drgnx-file/a-fifo-is-refused-without-blocking ()
  (skip-unless (executable-find "mkfifo"))
  (drgnx-file-test--with-dir dir
    (let ((fifo (expand-file-name "pipe.eld" dir)))
      (should (eq 0 (call-process "mkfifo" nil nil nil fifo)))
      (with-timeout (1 (ert-fail "the read blocked on the FIFO"))
        (let ((err (should-error (drgnx-file-read-bounded fifo) :type 'drgnx-file-refused)))
          (should (equal (nth 2 err) "not a regular file")))
        (should (eq (plist-get (drgnx-file-read fifo) :status) 'unreadable))))))

(ert-deftest drgnx-file/an-oversize-file-is-refused-never-truncated ()
  (drgnx-file-test--with-dir dir
    (let ((f (expand-file-name "big.eld" dir)))
      (drgnx-file-test--put f "(:a \"0123456789\")")
      (let ((err (should-error (drgnx-file-read-bounded f :max-bytes 10) :type 'drgnx-file-refused)))
        (should (equal (nth 2 err) "over 10 bytes")))
      (let ((r (drgnx-file-read f :max-bytes 10)))
        (should (eq (plist-get r :status) 'unreadable))
        (should (null (plist-get r :data))))
      (should (equal (drgnx-file-read-bounded f :max-bytes 17) "(:a \"0123456789\")")))))

(ert-deftest drgnx-file/a-dangling-symlink-is-refused ()
  (drgnx-file-test--with-dir dir
    (let ((link (expand-file-name "link.eld" dir)))
      (make-symbolic-link (expand-file-name "nowhere.eld" dir) link)
      (let ((err (should-error (drgnx-file-read-bounded link) :type 'drgnx-file-refused)))
        (should (equal (nth 2 err) "a symbolic link to nothing")))
      (should (null (drgnx-file-read-bounded (expand-file-name "missing.eld" dir))))
      (should (eq (plist-get (drgnx-file-read (expand-file-name "missing.eld" dir)) :status) 'absent)))))

(defun drgnx-file-test--tramp-trap (&rest _)
  "A file name handler that fails the test: Tramp was reached."
  (ert-fail "a file name handler was called"))

(ert-deftest drgnx-file/a-remote-name-is-refused-without-tramp ()
  (drgnx-file-test--with-dir dir
    (drgnx-file-test--put (expand-file-name "x.eld" dir) "(:a 1)")
    (cl-letf (((symbol-function 'tramp-file-name-handler) #'drgnx-file-test--tramp-trap)
              ((symbol-function 'tramp-autoload-file-name-handler) #'drgnx-file-test--tramp-trap))
      (let ((file-name-handler-alist '(("\\`/[^/|:]+:" . drgnx-file-test--tramp-trap)))
            (default-directory "/ssh:example.invalid:/tmp/"))
        (let ((err (should-error (drgnx-file-read-bounded "/ssh:example.invalid:/etc/x.eld") :type 'drgnx-file-refused)))
          (should (equal (nth 2 err) "a remote file")))
        (should (eq (plist-get (drgnx-file-read "/ssh:example.invalid:/x.eld") :status) 'unreadable))
        (should (null (drgnx-file-stamp "/ssh:example.invalid:/x.eld")))
        (should-error (drgnx-file-write "/ssh:example.invalid:/x.eld" '(:a 1)) :type 'drgnx-file-refused)
        (should-error (drgnx-file-update "/ssh:example.invalid:/x.eld" #'identity) :type 'drgnx-file-refused)
        ;; a remote default-directory: a local file is still read locally
        (should (equal (plist-get (drgnx-file-read (expand-file-name "x.eld" dir)) :data) '(:a 1)))))))

(defun drgnx-file-test--problem (text)
  "The problem `drgnx-file-read' finds in a file holding TEXT (it must be unreadable)."
  (drgnx-file-test--with-dir dir
    (let ((f (expand-file-name "p.eld" dir)))
      (drgnx-file-test--put f text)
      (let ((r (drgnx-file-read f)))
        (should (eq (plist-get r :status) 'unreadable))
        (should (null (plist-get r :data)))
        (should (equal (plist-get r :text) text))
        (let ((p (plist-get r :problem)))
          (should (stringp (plist-get p :text)))
          (should (natnump (plist-get p :line)))
          (should (natnump (plist-get p :column)))
          p)))))

(defun drgnx-file-test--ok (text)
  "The data `drgnx-file-read' gives for a file holding TEXT (it must be ok)."
  (drgnx-file-test--with-dir dir
    (let ((f (expand-file-name "ok.eld" dir)))
      (drgnx-file-test--put f text)
      (let ((r (drgnx-file-read f)))
        (should (eq (plist-get r :status) 'ok))
        (should (null (plist-get r :problem)))
        (plist-get r :data)))))

(ert-deftest drgnx-file/circular-syntax-is-a-problem ()
  (drgnx-file-test--problem "#1=(a . #1#)")
  (drgnx-file-test--problem "(a #1=(b) #1#)"))

(ert-deftest drgnx-file/depth-65-is-a-problem ()
  (let ((nest (lambda (n) (concat (make-string n ?\() "x" (make-string n ?\))))))
    (should (drgnx-file-test--ok (funcall nest 64)))
    (let ((p (drgnx-file-test--problem (concat "\n" (funcall nest 65)))))
      (should (= (plist-get p :line) 2))
      (should (= (plist-get p :column) 65)))
    ;; vectors nest too
    (drgnx-file-test--problem (concat (make-string 65 ?\[) "x" (make-string 65 ?\])))))

(ert-deftest drgnx-file/a-hash-table-literal-is-a-problem ()
  (let ((p (drgnx-file-test--problem "(:a 1\n :b #s(hash-table data (k v)))")))
    (should (= (plist-get p :line) 2))
    (should (= (plist-get p :column) 5))))

(ert-deftest drgnx-file/a-record-literal-is-a-problem ()
  (drgnx-file-test--problem "(:a #s(foo 1 2))")
  (drgnx-file-test--problem "(:a #&3\"a\")")                        ; a bool-vector
  (drgnx-file-test--problem "(:a #[(x) \"\\300\\207\" [x] 1])"))   ; byte-code

(ert-deftest drgnx-file/a-propertized-string-is-a-problem ()
  (drgnx-file-test--problem "(:a #(\"abc\" 0 1 (face bold)))")
  (should (equal (drgnx-file-test--ok "(:a \"abc\" :b [1 \"c\" d] :c 1.5)") '(:a "abc" :b [1 "c" d] :c 1.5))))

(ert-deftest drgnx-file/trailing-text-is-a-problem ()
  (let ((p (drgnx-file-test--problem ";; head\n(:a 1)\n  x\n")))
    (should (= (plist-get p :line) 3))
    (should (= (plist-get p :column) 3)))
  (drgnx-file-test--problem "(:a 1) (:b 2)")
  ;; comments and blank lines after the form are fine
  (should (equal (drgnx-file-test--ok ";; head\n(:a 1)\n;; tail\n\n") '(:a 1))))

(ert-deftest drgnx-file/problems-carry-line-and-column ()
  (let ((p (drgnx-file-test--problem "(:a 1\n :b ]")))
    (should (= (plist-get p :line) 2))
    (should (= (plist-get p :column) 5)))
  (let ((p (drgnx-file-test--problem ";; c\n(:a 1\n :b 2")))         ; a truncated file
    (should (>= (plist-get p :line) 2))))

(ert-deftest drgnx-file/comments-only-is-absent ()
  (drgnx-file-test--with-dir dir
    (let ((f (expand-file-name "c.eld" dir)))
      (dolist (text '("" "  \n\n" ";; nothing yet\n  ;; more\n"))
        (drgnx-file-test--put f text)
        (let ((r (drgnx-file-read f)))
          (should (eq (plist-get r :status) 'absent))
          (should (equal (plist-get r :text) text))
          (should (plist-get r :stamp)))))))

(ert-deftest drgnx-file/the-stamp-sees-a-rename-within-one-mtime-tick ()
  (drgnx-file-test--with-dir dir
    (let ((a (expand-file-name "a.eld" dir)) (b (expand-file-name "b.eld" dir)) (time (encode-time '(0 0 12 1 1 2026 nil -1 t))))
      (drgnx-file-test--put a "(:a 1)")
      (drgnx-file-test--put b "(:b 2)")
      (set-file-times a time)
      (set-file-times b time)
      (let ((before (drgnx-file-stamp a)))
        (should (equal before (drgnx-file-stamp a)))
        (rename-file b a t)
        (should-not (equal before (drgnx-file-stamp a)))
        (should (equal (nth 2 before) (nth 2 (drgnx-file-stamp a))))
        (should (equal (plist-get (drgnx-file-read a) :stamp) (drgnx-file-stamp a)))))))

;;;; Writes

(ert-deftest drgnx-file/a-symlink-stays-a-symlink ()
  (drgnx-file-test--with-dir dir
    (let ((real (expand-file-name "real.eld" dir)) (link (expand-file-name "link.eld" dir)))
      (drgnx-file-test--put real "(:a 1)\n")
      (make-symbolic-link real link)
      (should (equal (drgnx-file-write link '(:a 2)) real))
      (should (file-symlink-p link))
      (should (equal (drgnx-file-test--bytes real) "(:a 2)\n"))
      (should-not (drgnx-file-test--leftovers dir)))))

(ert-deftest drgnx-file/the-mode-is-kept ()
  (drgnx-file-test--with-dir dir
    (let ((f (expand-file-name "m.eld" dir)))
      (drgnx-file-test--put f "(:a 1)\n")
      (set-file-modes f #o640)
      (drgnx-file-write f '(:a 2))
      (should (= (file-modes f) #o640))
      (drgnx-file-write (expand-file-name "new.eld" dir) '(:a 1))
      (should (= (file-modes (expand-file-name "new.eld" dir)) #o644))
      (drgnx-file-write (expand-file-name "given.eld" dir) '(:a 1) :mode #o600)
      (should (= (file-modes (expand-file-name "given.eld" dir)) #o600)))))

(ert-deftest drgnx-file/update-private-is-0600 ()
  (drgnx-file-test--with-dir dir
    (let ((new (expand-file-name "n.eld" dir)) (plain (expand-file-name "p.eld" dir)) (old (expand-file-name "o.eld" dir)))
      (drgnx-file-update new (drgnx-file-test--add 'x) :private t)
      (should (= #o600 (logand #o777 (file-modes new))))
      (drgnx-file-update plain (drgnx-file-test--add 'x))                 ; the default is unchanged
      (should (= #o644 (logand #o777 (file-modes plain))))
      (drgnx-file-test--put old "(:items (a))\n")
      (set-file-modes old #o664)
      (drgnx-file-update old (drgnx-file-test--add 'x) :private t)       ; an old file loses group and others
      (should (= #o600 (logand #o777 (file-modes old)))))))

(ert-deftest drgnx-file/private-is-0600 ()
  (drgnx-file-test--with-dir dir
    (let ((f (expand-file-name "sub/dir/p.eld" dir)) (old (expand-file-name "old.eld" dir)))
      (drgnx-file-write f '(:token "x") :private t)                  ; missing folders are made
      (should (= (file-modes f) #o600))
      (drgnx-file-test--put old "(:a 1)\n")
      (set-file-modes old #o644)
      (drgnx-file-write old '(:token "x") :private t)                ; group and others lose their bits
      (should (= (file-modes old) #o600)))))

(ert-deftest drgnx-file/a-user-print-length-of-2-still-writes-everything ()
  (drgnx-file-test--with-dir dir
    (let ((f (expand-file-name "pl.eld" dir)) (data '(:a (1 2 3 4) :b ((((deep)))) :c ?x :d 0.1)))
      (let ((print-length 2) (print-level 1) (print-circle t) (print-integers-as-characters t) (float-output-format "%.0f"))
        (drgnx-file-write f data :header ";; a header\n")
        (drgnx-file-write (expand-file-name "pp.eld" dir) data :pretty t))
      (should (string-prefix-p ";; a header\n" (drgnx-file-test--bytes f)))
      (should (equal (plist-get (drgnx-file-read f) :data) data))
      (should (equal (plist-get (drgnx-file-read (expand-file-name "pp.eld" dir)) :data) data)))))

(ert-deftest drgnx-file/a-buffer-object-is-refused-and-the-file-kept ()
  (drgnx-file-test--with-dir dir
    (let ((f (expand-file-name "b.eld" dir)))
      (drgnx-file-test--put f "(:a 1)\n")
      (let ((err (should-error (drgnx-file-write f (list :a (current-buffer))) :type 'drgnx-file-refused)))
        (should (equal (nth 2 err) "not printable as data")))
      (should-error (drgnx-file-write f (list :a (make-hash-table))) :type 'drgnx-file-refused)
      (should (equal (drgnx-file-test--bytes f) "(:a 1)\n"))
      (should-not (drgnx-file-test--leftovers dir)))))

(ert-deftest drgnx-file/an-error-before-the-rename-leaves-the-old-file-and-no-temp ()
  (drgnx-file-test--with-dir dir
    (let ((f (expand-file-name "e.eld" dir)))
      (drgnx-file-test--put f "(:a 1)\n")
      (cl-letf (((symbol-function 'rename-file) (lambda (&rest _) (signal 'file-error '("Renaming" "disk full")))))
        (should-error (drgnx-file-write f '(:a 2)) :type 'file-error)
        (should-error (drgnx-file-write-text f "text\n") :type 'file-error))
      (should (equal (drgnx-file-test--bytes f) "(:a 1)\n"))
      (should (equal (directory-files dir nil "\\`[^.]\\|\\`\\.[^.]") '("e.eld"))))))

(ert-deftest drgnx-file/no-buffer-visits-the-target ()
  (drgnx-file-test--with-dir dir
    (let* ((f (expand-file-name "v.eld" dir)) (buf (progn (drgnx-file-test--put f "(:a 1)\n") (find-file-noselect f))))
      (unwind-protect
          (let ((inhibit-interaction t) (before (buffer-list)))
            (drgnx-file-write f '(:a 2))
            (drgnx-file-update f (lambda (d) (plist-put (copy-sequence d) :a 3)))
            (should (equal (buffer-list) before))
            (with-current-buffer buf
              (should-not (buffer-modified-p))
              (should (equal (buffer-string) "(:a 1)\n")))
            (should (equal (drgnx-file-test--bytes f) "(:a 3)\n")))
        (with-current-buffer buf (set-buffer-modified-p nil))
        (kill-buffer buf)))))

(ert-deftest drgnx-file/text-must-read-back-equal ()
  (drgnx-file-test--with-dir dir
    (let ((f (expand-file-name "t.eld" dir)))
      (should-error (drgnx-file-write f '(:a 2) :text "(:a 1)\n") :type 'drgnx-file-refused)
      (should-error (drgnx-file-write f '(:a 1) :text "(:a 1) junk\n") :type 'drgnx-file-refused)
      (should-not (file-exists-p f))
      (drgnx-file-write f '(:a 1) :text ";; kept\n(:a   1)\n")
      (should (equal (drgnx-file-test--bytes f) ";; kept\n(:a   1)\n"))
      (should-not (drgnx-file-test--leftovers dir)))))

(ert-deftest drgnx-file/write-text-keeps-symlink-and-mode ()
  (drgnx-file-test--with-dir dir
    (let ((real (expand-file-name "unit.service" dir)) (link (expand-file-name "link.service" dir)))
      (drgnx-file-test--put real "old\n")
      (set-file-modes real #o640)
      (make-symbolic-link real link)
      (should (equal (drgnx-file-write-text link "[Unit]\nDescription=é\n") real))
      (should (file-symlink-p link))
      (should (= (file-modes real) #o640))
      (should (equal (decode-coding-string (drgnx-file-test--bytes real) 'utf-8) "[Unit]\nDescription=é\n"))
      (drgnx-file-write-text (expand-file-name "s.txt" dir) "x" :private t)
      (should (= (file-modes (expand-file-name "s.txt" dir)) #o600)))))

;;;; Update and the lock

(ert-deftest drgnx-file/two-emacsen-each-add-100-and-all-200-survive ()
  (drgnx-file-test--with-dir dir
    (let* ((f (expand-file-name "shared.eld" dir))
           (core (file-name-directory (locate-library "drgnx-file")))
           (at (+ (float-time) 2)) (outs nil)
           (start (lambda (tag)
                    (let ((b (generate-new-buffer " *drgnx-file-child*" t)))
                      (push b outs)
                      (make-process
                       :name tag :buffer b :noquery t
                       :command (list (expand-file-name invocation-name invocation-directory) "--batch" "-Q"
                                      "--eval" "(setq load-prefer-newer t)" "-L" core "-l" "drgnx-file"
                                      "--eval"
                                      (format "(progn (sleep-for (max 0 (- %f (float-time))))
                                                      (dotimes (i 100)
                                                        (drgnx-file-update %S (lambda (d) (list :items (cons (intern (format \"%s-%%d\" i)) (plist-get d :items))))
                                                                           :timeout 20))
                                                      (princ \"DONE\\n\"))"
                                              at f tag))))))
           (procs (list (funcall start "a") (funcall start "b"))))
      (let ((deadline (+ (float-time) 30)))
        (while (and (cl-some #'process-live-p procs) (< (float-time) deadline)) (accept-process-output nil 0.05)))
      (unwind-protect
          (progn
            (should (cl-every (lambda (p) (and (not (process-live-p p)) (= (process-exit-status p) 0))) procs))
            (dolist (b outs) (should (string-match-p "DONE" (with-current-buffer b (buffer-string)))))
            (let ((items (plist-get (plist-get (drgnx-file-read f) :data) :items)))
              (should (= (length items) 200))
              (should (= (length (delete-dups (copy-sequence items))) 200)))
            (should-not (drgnx-file-test--leftovers dir)))
        (mapc #'delete-process procs)
        (mapc #'kill-buffer outs)))))

(ert-deftest drgnx-file/a-stale-lock-of-a-dead-pid-is-taken ()
  (drgnx-file-test--with-dir dir
    (let ((f (expand-file-name "s.eld" dir)))
      (drgnx-file-test--hold f (list :pid 99999999 :host (system-name) :started 1.0 :time (drgnx-file--now)))
      (should (equal (drgnx-file-update f (drgnx-file-test--add 'x) :timeout 0) '(:items (x))))
      (should-not (drgnx-file-test--leftovers dir)))))

(ert-deftest drgnx-file/a-reused-pid-is-not-the-holder ()
  (drgnx-file-test--with-dir dir
    (let ((f (expand-file-name "r.eld" dir)))
      ;; this Emacs's pid, but a holder started 1000 s earlier: the pid was reused, the holder is gone
      (drgnx-file-test--hold f (plist-put (drgnx-file-test--live-owner) :started (- (drgnx-file--pid-start (emacs-pid)) 1000)))
      (should (equal (drgnx-file-update f (drgnx-file-test--add 'x) :timeout 0) '(:items (x))))
      (should-not (drgnx-file-test--leftovers dir)))))

(ert-deftest drgnx-file/a-lock-older-than-10-s-is-taken ()
  (drgnx-file-test--with-dir dir
    (let* ((f (expand-file-name "o.eld" dir)) (t0 (float-time)) (now t0))
      (drgnx-file-test--hold f (list :pid 1 :host "another-host.invalid" :started 0.0 :time t0))
      (cl-letf (((symbol-function 'drgnx-file--now) (lambda () now)))
        (setq now (+ t0 5))
        (should-error (drgnx-file-update f (drgnx-file-test--add 'x) :timeout 0) :type 'drgnx-file-busy)
        (setq now (+ t0 11))
        (should (equal (drgnx-file-update f (drgnx-file-test--add 'x) :timeout 0) '(:items (x)))))
      (should-not (drgnx-file-test--leftovers dir)))))

(ert-deftest drgnx-file/a-held-lock-gives-busy-never-a-prompt ()
  (drgnx-file-test--with-dir dir
    (let* ((f (expand-file-name "h.eld" dir)) (owner (drgnx-file-test--live-owner)) (now (float-time)) (sleeps 0))
      (drgnx-file-test--put f "(:items (a))\n")
      (drgnx-file-test--hold f owner)
      (should (equal (drgnx-file-lock-holder f) owner))
      (cl-letf (((symbol-function 'drgnx-file--now) (lambda () now))
                ((symbol-function 'drgnx-file--sleep) (lambda (s) (cl-incf sleeps) (setq now (+ now s)))))
        (let ((inhibit-interaction t))
          (let ((err (should-error (drgnx-file-update f (drgnx-file-test--add 'x) :timeout 0) :type 'drgnx-file-busy)))
            (should (equal (nth 1 err) (file-truename f)))
            (should (equal (nth 2 err) owner)))
          (should (= sleeps 0))                                         ; :timeout 0 is one attempt
          (should-error (drgnx-file-update f (drgnx-file-test--add 'x) :timeout 0.05) :type 'drgnx-file-busy)
          (should (<= 4 sleeps 6))))                                    ; every 10 ms for 50 ms
      (should (equal (drgnx-file-test--bytes f) "(:items (a))\n"))
      (should (equal (drgnx-file-lock-holder f) owner)))))              ; somebody else's lock is left alone

(ert-deftest drgnx-file/an-unreadable-file-is-refused-untouched ()
  (drgnx-file-test--with-dir dir
    (let ((f (expand-file-name "u.eld" dir)) (called nil))
      (drgnx-file-test--put f ";; mine\n(:items (a)\n")
      (let ((err (should-error (drgnx-file-update f (lambda (d) (setq called t) d)) :type 'drgnx-file-refused)))
        (should (stringp (nth 2 err))))
      (should-not called)
      (should (equal (drgnx-file-test--bytes f) ";; mine\n(:items (a)\n"))
      (should-not (drgnx-file-test--leftovers dir)))))

(ert-deftest drgnx-file/backup-copies-aside-then-writes ()
  (drgnx-file-test--with-dir dir
    (let ((f (expand-file-name "state.eld" dir)) (got 'unset))
      (drgnx-file-test--put f "(:items (a)\n")
      (set-file-modes f #o640)
      (should (equal (drgnx-file-update f (lambda (d) (setq got d) '(:items (x))) :on-unreadable 'backup) '(:items (x))))
      (should (null got))
      (should (equal (plist-get (drgnx-file-read f) :data) '(:items (x))))
      (let ((baks (directory-files dir t "\\`state\\.eld\\.bak-[0-9]\\{8\\}-[0-9]\\{6\\}-[0-9]\\{3\\}\\'")))
        (should (= (length baks) 1))
        (should (equal (drgnx-file-test--bytes (car baks)) "(:items (a)\n"))
        (should (= (file-modes (car baks)) #o640))))))

(ert-deftest drgnx-file/backups-keep-the-newest-3 ()
  (drgnx-file-test--with-dir dir
    (let* ((f (expand-file-name "k.eld" dir)) (now 1800000000.0) (made nil))
      (drgnx-file-test--put f "(:a 1)\n")
      (cl-letf (((symbol-function 'drgnx-file--now) (lambda () now)))
        (dotimes (_ 5)
          (setq now (+ now 1.5))
          (push (file-name-nondirectory (drgnx-file-backup f)) made))
        (setq made (nreverse made))
        (should (equal (directory-files dir nil "\\.bak-") (last made 3)))
        ;; two in one millisecond do not collide
        (drgnx-file-backup f)
        (should (= (length (directory-files dir nil "\\.bak-")) 3))))))

(ert-deftest drgnx-file/a-no-op-update-writes-nothing ()
  (drgnx-file-test--with-dir dir
    (let ((f (expand-file-name "n.eld" dir)) (time (encode-time '(0 0 12 1 1 2026 nil -1 t))))
      (drgnx-file-test--put f ";; c\n(:a 1)\n")
      (set-file-times f time)
      (let ((stamp (drgnx-file-stamp f)))
        (should (equal (drgnx-file-update f #'identity) '(:a 1)))
        (should (equal (drgnx-file-stamp f) stamp))
        (should (equal (drgnx-file-test--bytes f) ";; c\n(:a 1)\n")))
      ;; an absent file and a function that keeps nil: no file is made
      (should (null (drgnx-file-update (expand-file-name "none.eld" dir) #'ignore)))
      (should-not (file-exists-p (expand-file-name "none.eld" dir)))
      (should-not (drgnx-file-test--leftovers dir)))))

(ert-deftest drgnx-file/an-update-that-mutates-its-argument-is-written ()
  (drgnx-file-test--with-dir dir
    (let ((f (expand-file-name "mu.eld" dir)) (seen nil))
      (drgnx-file-test--put f "(:a 1 :b 2)\n")
      (should (equal (drgnx-file-update f (lambda (d) (plist-put d :a 2))) '(:a 2 :b 2)))
      (should (equal (plist-get (drgnx-file-read f) :data) '(:a 2 :b 2)))
      ;; RENDER gets the data as read, untouched by FN
      (drgnx-file-update f (lambda (d) (plist-put d :a 3))
                         :render (lambda (old data new) (setq seen (list data new)) (string-replace ":a 2" ":a 3" old)))
      (should (equal seen '((:a 2 :b 2) (:a 3 :b 2))))
      (should (equal (drgnx-file-test--bytes f) "(:a 3 :b 2)\n")))))

(ert-deftest drgnx-file/a-write-over-max-bytes-is-refused ()
  (drgnx-file-test--with-dir dir
    (let ((f (expand-file-name "big.eld" dir)) (u (expand-file-name "up.eld" dir)))
      (drgnx-file-test--put f "(:a 1)\n")
      (let ((err (should-error (drgnx-file-write f '(:a "0123456789") :max-bytes 10) :type 'drgnx-file-refused)))
        (should (equal (nth 2 err) "over 10 bytes")))
      (let ((drgnx-file-max-bytes 12))                                 ; the default cap is the read cap
        (should-error (drgnx-file-write f '(:a "0123456789")) :type 'drgnx-file-refused)
        (should (drgnx-file-write-text (expand-file-name "report.txt" dir) "0123456789012345")))  ; text: no cap
      (should (equal (drgnx-file-test--bytes f) "(:a 1)\n"))
      (should-error (drgnx-file-update u (lambda (_) '(:a "0123456789")) :max-bytes 10) :type 'drgnx-file-refused)
      (should-not (file-exists-p u))
      (should (equal (drgnx-file-update u (lambda (_) '(:a "0123456789")) :max-bytes 64) '(:a "0123456789")))
      (should-not (drgnx-file-test--leftovers dir)))))

(ert-deftest drgnx-file/the-lock-is-released-on-error ()
  (drgnx-file-test--with-dir dir
    (let ((f (expand-file-name "l.eld" dir)))
      (should-error (drgnx-file-update f (lambda (_) (error "Boom"))) :type 'error)
      (should-not (drgnx-file-test--leftovers dir))
      (should (null (drgnx-file-lock-holder f)))
      (should (equal (drgnx-file-update f (drgnx-file-test--add 'x) :timeout 0) '(:items (x)))))))

(ert-deftest drgnx-file/render-gets-the-old-text ()
  (drgnx-file-test--with-dir dir
    (let ((f (expand-file-name "rg.eld" dir)) (seen nil))
      (drgnx-file-test--put f ";; my comment\n(:a 1 :zz unknown)\n")
      (drgnx-file-update f (lambda (d) (plist-put (copy-sequence d) :a 2))
                         :render (lambda (old data new)
                                   (setq seen (list old data new))
                                   (replace-regexp-in-string ":a 1" ":a 2" old t t)))
      (should (equal seen '(";; my comment\n(:a 1 :zz unknown)\n" (:a 1 :zz unknown) (:a 2 :zz unknown))))
      (should (equal (drgnx-file-test--bytes f) ";; my comment\n(:a 2 :zz unknown)\n"))
      ;; a render that does not give NEW back is refused, the file kept
      (should-error (drgnx-file-update f (lambda (d) (plist-put (copy-sequence d) :a 3)) :render (lambda (old _d _n) old))
                    :type 'drgnx-file-refused)
      (should (equal (drgnx-file-test--bytes f) ";; my comment\n(:a 2 :zz unknown)\n")))))

;;; file-test.el ends here
