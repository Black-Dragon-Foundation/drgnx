;;; write-manifest.el --- manifest.eld for the LSP corpora: what a full replay of each sends -*- lexical-binding: t -*-
;; LSP_REPLAY_LIBRARY=1 emacs --batch -Q -l ../lsp-replay.el -l write-manifest.el
;; The count and byte total of the payloads of corpus-NAME.eld.gz (`lsp-replay-corpus-totals'); capture-lsp.sh runs it
;; after a capture, and test/unit/perf-workers-test.el replays each corpus through the stub and compares.

;;; Code:
(let* ((dir (file-name-directory (or load-file-name buffer-file-name)))
       (rows (mapcar (lambda (n)
                       (let ((corpus (lsp-replay-corpus-read (expand-file-name (format "corpus-%s.eld.gz" n) dir))))
                         (format " (%S %s)\n" n (substring (prin1-to-string (lsp-replay-corpus-totals corpus)) 1 -1))))
                     '("rust" "c" "ts"))))
  (with-temp-file (expand-file-name "manifest.eld" dir)
    (insert ";; Written by write-manifest.el: (NAME :messages N :bytes B), what a full replay of corpus-NAME.eld.gz sends.\n(\n"
            (apply #'concat rows) ")\n")))
;;; write-manifest.el ends here
