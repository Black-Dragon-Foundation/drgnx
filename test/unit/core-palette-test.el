;;; core-palette-test.el --- batch tests: the command palette -*- lexical-binding: t -*-
(require 'ert)
(require 'drgnx-palette)

(defvar drgnx-test--palette-ran nil)
(defun drgnx-test--palette-cmd () (interactive) (setq drgnx-test--palette-ran t))

(ert-deftest drgnx-palette/candidates-and-run ()
  (let ((drgnx-commands--table (make-hash-table :test #'eq)) (drgnx-commands--order nil)
        (drgnx-commands-problems nil) (drgnx-test--palette-ran nil))
    (drgnx-command-define 'p :title "Do It" :category "Test" :command #'drgnx-test--palette-cmd)
    (drgnx-command-define 'gone :title "Gone" :category "Test" :command 'drgnx-test--missing)
    (should (equal (mapcar #'car (drgnx-palette-candidates)) '("Test: Do It")))
    (cl-letf (((symbol-function 'completing-read) (lambda (&rest _) "Test: Do It")))
      (drgnx-palette))
    (should drgnx-test--palette-ran)))

;; The answer is resolved here, not by the completion UI: `require-match' is nil, so a `#question' that no
;; completion style would offer (orderless filters candidates itself) still reaches the command.
(defun drgnx-test--palette-with-search (answer styles &rest opts)
  "Run the palette with ANSWER typed, under completion STYLES; return (SEARCH-ARGS REQUIRE-MATCH RAN)."
  (let ((drgnx-commands--table (make-hash-table :test #'eq)) (drgnx-commands--order nil)
        (drgnx-commands-problems nil) (asked nil) (require-match 'unset) (drgnx-test--palette-ran nil)
        (completion-styles styles))
    (drgnx-command-define 'p :title "Do It" :category "Test" :command #'drgnx-test--palette-cmd)
    (when (plist-get opts :extra)
      (drgnx-command-define 'p2 :title "Do That" :category "Test" :command #'drgnx-test--palette-cmd))
    (drgnx-command-define 'search-semantic :title "Semantic Search" :category "Search"
                          :command (lambda (&optional q) (interactive (list "prompted")) (push q asked)))
    (cl-letf (((symbol-function 'completing-read)
               (lambda (_prompt _tbl _pred rm &rest _) (setq require-match rm) answer)))
      (drgnx-palette))
    (list asked require-match drgnx-test--palette-ran)))

(ert-deftest drgnx-palette/hash-runs-semantic-search ()
  (dolist (styles (append '((basic)) (and (locate-library "orderless") '((orderless basic)))))
    (pcase-let ((`(,asked ,rm ,_) (drgnx-test--palette-with-search "#  where do we parse json " styles)))
      (should (equal asked '("where do we parse json")))       ; the text after #, trimmed
      (should-not rm))                                         ; the UI never refuses the input
    ;; a bare # prompts (the command's own prompt)
    (should (equal (car (drgnx-test--palette-with-search "#" styles)) '("prompted")))
    ;; a label runs; empty does nothing; anything else is a clear error
    (should (nth 2 (drgnx-test--palette-with-search "Test: Do It" styles)))
    (should-not (car (drgnx-test--palette-with-search "" styles)))
    (should-not (nth 2 (drgnx-test--palette-with-search "  " styles)))
    (let ((err (should-error (drgnx-test--palette-with-search "nonsense" styles) :type 'user-error)))
      (should (string-match-p "No command: nonsense" (cadr err))))
    ;; a partial label resolves the way completion would (require-match t used to): unique runs it
    (should (nth 2 (drgnx-test--palette-with-search "Test: Do" styles)))
    (should (equal (car (drgnx-test--palette-with-search "Search: Sem" styles)) '("prompted")))
    ;; ambiguous: the names
    (let ((err (should-error (drgnx-test--palette-with-search "Test:" styles :extra t) :type 'user-error)))
      (should (string-match-p "Ambiguous: .*Test: Do It.*Test: Do That" (cadr err))))))

(ert-deftest drgnx-palette/a-label-starting-with-hash-wins ()
  (let ((drgnx-commands--table (make-hash-table :test #'eq)) (drgnx-commands--order nil)
        (drgnx-commands-problems nil) (drgnx-test--palette-ran nil) (asked nil))
    (drgnx-command-define 'h :title "tag" :category "#" :command #'drgnx-test--palette-cmd)
    (drgnx-command-define 'search-semantic :title "Semantic Search" :category "Search"
                          :command (lambda (&optional q) (interactive) (push q asked)))
    (cl-letf (((symbol-function 'completing-read) (lambda (&rest _) "#: tag")))
      (drgnx-palette))
    (should drgnx-test--palette-ran)
    (should-not asked)))
