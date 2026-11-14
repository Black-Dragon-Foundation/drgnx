;;; generators.el --- generators for the off-the-main-thread workloads (sources, a compile log, a big repository) -*- lexical-binding: t -*-
;; Loaded by perf-session.el and by the tests; nothing here touches the user's files: every function writes where it is told.
;; Generators instead of big files (the plan): the 200k-line compile log, the 1 and 2 MB sources and the 200k-file
;; repository are made when a workload sets up.  The same arguments give the same bytes, so a digest compares.

;;; Code:
(require 'subr-x)
(require 'cl-lib)

(defun drgnx-perf-w-gen-snippet (kind n)
  "The Nth function of language KIND (c, ts, py): about 250 bytes, with strings, comments and nesting."
  (pcase kind
    ('c (format "/* function %d: sums a range */\nstatic int fn_%d(int a, int b)\n{\n  int total = 0;\n  for (int i = 0; i < a; i++) {\n    if (i %% 3 == 0) total += b * i; else total -= i;\n  }\n  const char *name = \"fn_%d\";\n  return total + (int) sizeof(name) + %d;\n}\n\n" n n n n))
    ('ts (format "// function %d\nexport function fn%d(a: number, b: string): string {\n  const parts: string[] = [];\n  for (let i = 0; i < a; i++) {\n    parts.push(`${b}-${i}-%d`);\n  }\n  return parts.join(\",\");\n}\n\n" n n n))
    ('py (format "# function %d\ndef fn_%d(a, b):\n    \"\"\"Sum a range (%d).\"\"\"\n    total = 0\n    for i in range(a):\n        total += i * b if i %% 3 == 0 else -i\n    return {\"total\": total, \"name\": \"fn_%d\"}\n\n\n" n n n n))
    (_ (error "no snippet for %S" kind))))

(defun drgnx-perf-w-gen-source (kind bytes)
  "Source text in language KIND (c, ts, py) of at least BYTES bytes."
  (let ((parts nil) (size 0) (n 0))
    (while (< size bytes)
      (let ((s (drgnx-perf-w-gen-snippet kind n)))
        (push s parts) (setq size (+ size (length s)) n (1+ n))))
    (apply #'concat (nreverse parts))))

(defun drgnx-perf-w-gen-compile-log (file lines)
  "Write LINES lines of compiler output to FILE: warnings and errors in gcc's format, every line numbered (logNNNNNN)."
  (with-temp-file file
    (dotimes (i lines)
      (insert (format "log%06d.c:%d:%d: %s: unused variable 'x%d' [-Wunused-variable]\n"
                      i (1+ (% i 997)) (1+ (% i 61)) (if (zerop (% i 7)) "error" "warning") (% i 1000))))))

(defun drgnx-perf-w-gen-big-dir (dir files)
  "DIR holding FILES empty files b0000.txt… (a big folder); returns DIR."
  (make-directory dir t)
  (let ((i 0))
    (while (< i files)
      (let ((batch (cl-loop for k from i below (min files (+ i 500)) collect (expand-file-name (format "b%04d.txt" k) dir))))
        (apply #'call-process "touch" nil nil nil batch)
        (setq i (+ i 500)))))
  dir)

(defun drgnx-perf-w-gen-repo (root dirs per-dir &optional git)
  "ROOT with DIRS folders of PER-DIR empty files each (dNNN/fNNN.txt); GIT: a repository with everything committed
and the first 50 files of the folders d000… changed.  Returns ROOT."
  (make-directory root t)
  (dotimes (d dirs)
    (let ((dir (expand-file-name (format "d%03d" d) root)))
      (make-directory dir t)
      (apply #'call-process "touch" nil nil nil
             (cl-loop for f below per-dir collect (expand-file-name (format "f%03d.txt" f) dir)))))
  (when (and git (executable-find "git"))
    (let ((default-directory (file-name-as-directory root)))
      (call-process "git" nil nil nil "init" "-q")
      (call-process "git" nil nil nil "add" "-A")
      (call-process "git" nil nil nil "-c" "user.email=perf@drgnx" "-c" "user.name=perf" "commit" "-qm" "perf")
      (dotimes (i (min 50 dirs))
        (write-region "changed\n" nil (expand-file-name (format "d%03d/f000.txt" i) root) nil 'silent))))
  root)

(provide 'generators)
;;; generators.el ends here
