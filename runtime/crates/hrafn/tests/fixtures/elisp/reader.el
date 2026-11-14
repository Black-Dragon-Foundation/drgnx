;;; reader.el --- Reader corner cases -*- lexical-binding: t; -*-

(setq a '(1 . 2) b ?\) c ?\" d "a ; not a comment (" e "multi
line")
(setq f [1 (2 3) "x"] g #s(hash-table data (a 1)) h `(1 ,a ,@b))
(defun reader-é (x) "Unicode: é ü." (list x ?é))
(setq i ?\C-a j ?\M-\C-b k ?\x41 l ?\N{LATIN SMALL LETTER A})
(setq m 'foo\ bar n '\,)  ; a trailing comment
#'car
(setq o #b101 p #xff q 1.5e3 r -0.5 s 'sym?)
#:uninterned
(setq t1 (lambda (x) (+ x 1))) (setq u 1)
(let ((s "\"quoted\" \\ done")) s)
