;;; git-records-test.el --- git status read per batch from Nidhogg's records framing -*- lexical-binding: t -*-
;; test-class: det
;; Pattern D (pure, the real framer when the build has it) for the equality and switch rows; pattern A (every order of a
;; pure core, `drgnx-test-every-order') for the rename that crosses a batch.  No process: the framer is
;; `nidhogg-workers--test-frame' (the reader's own code) when this Emacs has it, else `drgnx-git-records-test--frame',
;; a Lisp split at the NUL that gives the same batches for these streams.
(require 'ert)
(require 'cl-lib)
(require 'drgnx-paths)
(load (expand-file-name "test/fixtures/orders-fixture" drgnx-dir) nil t)
(require 'drgnx-git)
(defvar nidhogg-workers-framing)        ; a `let' of it binds it dynamically, also on an Emacs without the feature

(defconst drgnx-git-records-test--status
  (concat "# branch.oid 0123456789abcdef\0# branch.head feature/é\0# branch.upstream origin/main\0# branch.ab +2 -1\0"
          "1 .M N... 100644 100644 100644 aaa bbb src/app/main.py\0"
          "1 A. N... 000000 100644 100644 000 ccc new file.py\0"
          "1 .D N... 100644 100644 000000 aaa bbb gone.txt\0"
          "2 R. N... 100644 100644 100644 ddd eee R100 lib/renamed é.py\0lib/old.py\0"
          "2 C. N... 100644 100644 100644 ddd eee C75 lib/copy.py\0! not-a-path-because-skipped\0"
          "u UU N... 100644 100644 100644 100644 f g h conflict.txt\0"
          "? notes ü.txt\0"
          "? scratch/\0"
          "! build/\0"
          "! out.o\0")
  "A porcelain v2 stream: renames, a copy whose origin looks like an ignored entry, unmerged, ignored, non-ASCII.")

(defun drgnx-git-records-test--bytes (s) (encode-coding-string s 'utf-8))

(defun drgnx-git-records-test--chunks (bytes cuts)
  "BYTES (unibyte) cut at the offsets CUTS (any order, duplicates and out-of-range ones dropped)."
  (let ((pos 0) out)
    (dolist (c (sort (delete-dups (seq-filter (lambda (c) (< 0 c (length bytes))) cuts)) #'<))
      (push (substring bytes pos c) out)
      (setq pos c))
    (nreverse (cons (substring bytes pos) out))))

(defun drgnx-git-records-test--frame (chunks)
  "The batches a reader gives for CHUNKS: one per chunk, the records that chunk completed, decoded as UTF-8.
`nidhogg-workers--test-frame' returns one list for all chunks, so when it is there the batches are cut by
feeding it the chunks one at a time, each with the bytes the last left over (its REST)."
  (if (fboundp 'nidhogg-workers--test-frame)
      (let (batches (rest ""))
        (dolist (c chunks)
          (let ((r (nidhogg-workers--test-frame (list (concat rest c)) nil 'records :separator 0 :coding 'utf-8-unix)))
            (push (mapcar #'car (nth 0 r)) batches)
            (setq rest (nth 1 r))))
        (nreverse batches))
    (let (batches (rest ""))
      (dolist (c chunks)
        (let* ((all (concat rest c)) (parts (split-string all "\0")) )
          (setq rest (car (last parts)))
          (push (mapcar (lambda (p) (decode-coding-string p 'utf-8-unix)) (butlast parts)) batches)))
      (nreverse batches))))

(defun drgnx-git-records-test--read (batches)
  "BATCHES (lists of records) read the way the shell reads them: (FILES-ENTRIES . BRANCH)."
  (let ((acc (drgnx-git--acc-make)))
    (dolist (b batches) (dolist (r b) (drgnx-git--acc-feed acc r)))
    (cons (drgnx-git-records-test--entries (drgnx-git--acc-files-done acc)) (drgnx-git--acc-branch-of acc))))

(defun drgnx-git-records-test--entries (hash)
  (let (l) (maphash (lambda (k v) (push (cons k v) l)) hash) (sort l (lambda (a b) (string< (car a) (car b))))))

(defun drgnx-git-records-test--whole ()
  (cons (drgnx-git-records-test--entries (drgnx-git-parse drgnx-git-records-test--status))
        (drgnx-git-parse-branch drgnx-git-records-test--status)))

(ert-deftest drgnx-git-records/status-equal ()
  "Pattern D: the stream cut at fixed offsets (one byte at a time, mid-record, mid-character, a few seeded) and
parsed per batch gives what `drgnx-git-parse' gives for the whole output."
  (let* ((bytes (drgnx-git-records-test--bytes drgnx-git-records-test--status))
         (n (length bytes))
         (whole (drgnx-git-records-test--whole))
         (cut-sets (list nil '(1) (list (/ n 2)) (number-sequence 1 (1- n))
                         (number-sequence 7 (1- n) 7) (number-sequence 13 (1- n) 31)
                         (let ((i 0) (l nil) (x 17)) ; a fixed pseudo-random walk
                           (while (< (setq i (+ i 1 (% x 40))) n)
                             (push i l) (setq x (% (+ (* x 75) 74) 65537)))
                           l))))
    (should (gethash "lib/renamed é.py" (drgnx-git-parse drgnx-git-records-test--status)))
    (should-not (gethash "lib/old.py" (drgnx-git-parse drgnx-git-records-test--status)))
    (should-not (gethash "not-a-path-because-skipped" (drgnx-git-parse drgnx-git-records-test--status)))
    (dolist (cuts cut-sets)
      (let ((batches (drgnx-git-records-test--frame (drgnx-git-records-test--chunks bytes cuts))))
        (should (equal (drgnx-git-records-test--read batches) whole))))))

(defun drgnx-git-records-test--rename-batches ()
  "The stream as three batches cut right after each rename's first record, so each origin opens the next batch."
  (let* ((recs (split-string drgnx-git-records-test--status "\0" t)) cut cuts)
    (cl-loop for r in recs for i from 1
             when (string-prefix-p "2 " r) do (push i cuts))
    (setq cuts (nreverse cuts))
    (let ((pos 0))
      (dolist (c (append cuts (list (length recs))))
        (push (cl-subseq recs pos c) cut)
        (setq pos c)))
    (nreverse cut)))

(ert-deftest drgnx-git-records/rename-across-batches ()
  "Pattern A: a batch ends after a rename's first record, so its origin path opens the next.  In every order of
the batches (in order), the reader's probes (a panel looking at what is read so far) and the end, the origin is never
a path or an entry of its own, the probes see only complete entries, and the end equals the whole parse."
  (let* ((batches (drgnx-git-records-test--rename-batches))
         (nb (length batches))
         (whole (drgnx-git-records-test--whole)))
    (should (> nb 2))
    (should (string-prefix-p "2 " (car (last (car batches)))))        ; the first batch ends on a rename
    (should (equal (drgnx-git-records-test--read batches) whole))
    (drgnx-test-every-order
     :kinds '(batch probe done)
     :sources (list (cons 'batches (mapcar (lambda (b) (list 'batch b)) batches))
                    (cons 'probes (list (list 'probe) (list 'probe)))
                    (cons 'end (list (list 'done))))
     :edges (list (cons (cons 'batches (1- nb)) (cons 'end 0)))
     :init (lambda () (list (drgnx-git--acc-make) nil nil))
     :step (lambda (state ev)
             (pcase (car ev)
               ('batch (dolist (r (cadr ev)) (drgnx-git--acc-feed (nth 0 state) r)))
               ('probe (push (drgnx-git-records-test--entries (drgnx-git--acc-files (nth 0 state))) (nth 1 state)))
               ('done (setf (nth 2 state)
                            (cons (drgnx-git-records-test--entries (drgnx-git--acc-files-done (nth 0 state)))
                                  (drgnx-git--acc-branch-of (nth 0 state))))))
             (cons state nil))
     :check (lambda (state _order)
              (or (cl-loop for probe in (nth 1 state)
                           thereis (and (cl-find-if (lambda (e) (string-match-p "\\`lib/old\\.py\\'" (car e))) probe)
                                        "a rename's origin path showed up as a file"))
                  (and (not (equal (nth 2 state) whole)) "the end differs from the whole parse"))))))

(ert-deftest drgnx-git-records/off-without-switch ()
  "Pattern D: without Nidhogg's framing, or with its switch off, the process is left as it is."
  (let (calls)
    (cl-letf (((symbol-function 'nidhogg-set-process-framing) (lambda (&rest a) (push a calls) t)))
      (let ((nidhogg-workers-framing nil))
        (should-not (drgnx-git--frame 'proc))
        (should-not calls))
      (let ((nidhogg-workers-framing t))
        (should (drgnx-git--acc-p (drgnx-git--frame 'proc)))
        (should (equal (cdr (car calls)) '(records :separator 0 :coding utf-8-unix :batch-function drgnx-git--batch)))))
    (let ((nidhogg-workers-framing t))
      (cl-letf (((symbol-function 'nidhogg-set-process-framing) nil)) ; the feature is not there
        (setq calls nil)
        (should-not (drgnx-git--frame 'proc))
        (should-not calls)))))

(ert-deftest drgnx-git-records/a-refused-framing-leaves-the-buffer-path ()
  "Pattern D: a framing the reader refuses gives no accumulator, so the sentinel reads the buffer."
  (let ((nidhogg-workers-framing t))
    (cl-letf (((symbol-function 'nidhogg-set-process-framing) (lambda (&rest _) (error "unsupported"))))
      (should-not (drgnx-git--frame 'proc)))))
