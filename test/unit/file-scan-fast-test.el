;;; file-scan-fast-test.el --- batch tests: the token scan's fast path accepts nothing the reader refuses -*- lexical-binding: t -*-
;; test-class: det

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; `drgnx-file--scan' steps over plain symbols, numbers and strings by a regexp instead of `read'ing them
;; (`drgnx-file--skip-plain-atom').  The bounded reader stays the security boundary, so every text here goes through
;; `drgnx-file--parse' twice, with the fast path on and off, and the two results must be the same: whatever the full
;; scan refuses (a reader macro, a backquote, a comma, a unibyte or raw-byte string, an integer beyond 64 bits,
;; unbalanced text, nesting beyond the limit, `#.' …) the fast path refuses with the same problem and place.
;; Race-proof pattern D: pure.

;;; Code:
(require 'ert)
(require 'cl-lib)
(require 'drgnx-file)

(defvar drgnx-file--scan-fast)

(defconst drgnx-file-scan-fast-test--hostile
  `("(a #.(delete-file \"x\"))" "(a #s(hash-table))" "(a `(b ,c))" "(a ,@b)" "(a ,b)" "#1=(a . #1#)" "(a #'b #x10 #b11 #24r1k)"
    "(a #_b)" "(a ##)" "(a #@10 xyz)" "(a #[(x) \"\\300\" [] 1])" "(a #&3\"\\1\")" "(a #^[nil nil])"
    "(a \"\\xe9\")" "(a \"\\351\")" "(a \"\\M-a\")" "(a \"é\\xe9\")" "(a \"ok\")" "(a \"unterminated"
    "(a 123456789012345678901)" "(a 9223372036854775807)" "(a 9223372036854775808)" "(a -9223372036854775809)"
    "(a 12345678901234567890.)" "(a 1e400)" "(a 1.5 -2 +3 .5)" "(a b?c ?\\C-a ?, ?# ?\\()" "(a b#c)" "(a b,c)" "(a b`c)"
    "(a . b)" "(a .b)" "(a\\ b c)" "(a\\#b)" "(a b\\,c)" "(\"a\" . \"b\")" "(a (b (c" "a b" ")" "((a)" "(a))" "(a b) c"
    ";; a comment, with `quotes' and #.(evil)\n(a b)" "(a ; #.(x)\n b)" "(a \"; ,x\" b)" "(a \"x\n; \" #.(y))"
    "(a b)\n#.(z)" "" "   \n;; only a comment\n" "(a \u00a0b)" "(a \0b)" "(a é b)" "(a #xFFFFFFFFFFFFFFFFFFFF)"
    ,(concat "(a \"" (make-string 200000 ?x) "\")")                  ; a huge string
    ,(concat "(a \"" (make-string 200000 ?x) "\\xe9\")")             ; a huge string with an escape
    ,(concat (make-string 5000 ?\() "a" (make-string 5000 ?\)))       ; nested beyond the limit
    ,(concat (make-string 5000 ?\() "a")                             ; … and unbalanced
    ,(concat "(" (mapconcat #'identity (make-list 3000 "sym") " ") " #.(x))")
    ,(concat "(" (mapconcat #'identity (make-list 3000 "12345678901234567890") " ") ")"))
  "Texts the bounded reader refuses, or handles with care.")

(defun drgnx-file-scan-fast-test--both (text)
  "(FAST . FULL): `drgnx-file--parse' of TEXT with the fast path on and off."
  (cons (let ((drgnx-file--scan-fast t)) (drgnx-file--parse text))
        (let ((drgnx-file--scan-fast nil)) (drgnx-file--parse text))))

(ert-deftest drgnx-file-scan-fast/hostile-text-is-refused-as-before ()
  (dolist (text drgnx-file-scan-fast-test--hostile)
    (let ((r (drgnx-file-scan-fast-test--both text)))
      (should (equal (car r) (cdr r))))))

(ert-deftest drgnx-file-scan-fast/what-must-be-refused-is-refused-with-the-fast-path-on ()
  (dolist (text '("(a #.(delete-file \"x\"))" "(a `(b ,c))" "(a ,@b)" "(a #s(hash-table))" "(a \"\\xe9\")" "(a \"\\351\")"
                  "(a 9223372036854775808)" "(a b#c)" "(a b,c)" "(a b`c)" "(a (b (c" "(a #1=b)" "(a \"é\\xe9\")"))
    (let ((drgnx-file--scan-fast t))
      (should (eq (car (drgnx-file--parse text)) 'problem)))))

(ert-deftest drgnx-file-scan-fast/random-text-from-the-risky-pieces-gives-the-same-result ()
  (let ((pieces ["(" ")" "[" "]" "a" "foo" "b?c" "?" "\"" "\"s\"" "\"\\x41\"" "\"é\"" "#" "#'" "#." "#(" "#x1f" "'" "`" ","
                 ",@" "\\" "\\ " "." " . " ";" ";x" "\n" " " "\t" "1" "-7" "1.5" "123456789012345678901" "é" "\u00a0" "nil"
                 ":k" "+" "a#b" "a'b" "\"a\\\"b\""])
        (n 3000))
    (random "scan-fast")                                             ; a fixed seed
    (dotimes (_ n)
      (let ((text (mapconcat (lambda (_) (aref pieces (random (length pieces)))) (make-list (1+ (random 14)) nil) "")))
        (let ((r (drgnx-file-scan-fast-test--both text)))
          (should (equal (car r) (cdr r))))))))

(ert-deftest drgnx-file-scan-fast/the-fast-path-skips-only-what-the-reader-would-accept ()
  ;; each plain atom is one the full scan reads without a finding; the others are left to `read'
  (with-temp-buffer
    (dolist (case '(("abc " t 3) ("a-b_c:d " t 7) ("-12 " t 3) ("1.5e3 " t 5) ("\"a b\n c\" " t 8) ("\"é\" " t 3)
                    ("a?b " t 3) ("?a " nil 0) ("a\\ b " nil 0) ("\"a\\\"b\" " nil 0) ("123456789012345678901 " nil 0)
                    ("12345678901234567 " t 17) ("a#b " t 1) ("a'b " t 1) ("a,b " t 1)))
      (erase-buffer)
      (insert (car case))
      (goto-char (point-min))
      (should (eq (and (drgnx-file--skip-plain-atom) t) (nth 1 case)))
      (should (= (1- (point)) (nth 2 case))))))

;;; file-scan-fast-test.el ends here
