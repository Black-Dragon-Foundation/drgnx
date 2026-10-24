;;; drgnx-secrets-scan.el --- Does a text look like a credential? -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; The Lisp twin of `runstav::secrets::looks_like_secret' (runtime/crates/runstav/src/secrets.rs); both run the cases
;; of test/fixtures/secret-cases.json.  Change the two together.
;; Its own file, needing only cl-lib and subr-x: the settings history checks every change it records with it (core,
;; loaded at start), without loading secrets.age's code and the AI layer that `drgnx-secrets' brings.

;;; Code:

(require 'cl-lib)
(require 'subr-x)

(defconst drgnx-secrets--key-prefixes
  '("sk-" "sk-ant-" "sk-or-" "ghp_" "gho_" "github_pat_" "glpat-" "xoxa-" "xoxb-" "xoxp-")
  "Token prefixes of an API key.")

(defconst drgnx-secrets--keywords '("password" "passwd" "secret" "token" "api_key" "api-key" "apikey")
  "Words that, followed by `=' or `:' and a value, make an assignment.")

(defun drgnx-secrets--tokens (text)
  "The runs of [A-Za-z0-9+_-] in TEXT."
  (let ((case-fold-search nil)) (split-string text "[^A-Za-z0-9+_-]+" t)))

(defun drgnx-secrets--key-prefix-p (token)
  "Whether TOKEN is a known key prefix and at least 16 characters with a digit or a capital."
  (let ((case-fold-search nil))
    (cl-some (lambda (p)
               (and (string-prefix-p p token)
                    (let ((rest (substring token (length p))))
                      (and (>= (length rest) 16) (string-match-p "[0-9A-Z]" rest)))))
             drgnx-secrets--key-prefixes)))

(defun drgnx-secrets--value-follows-p (rest)
  "Whether REST (what follows a keyword) is `= value' or `: value' with a value of 8 or more characters."
  (let ((case-fold-search nil))
    (when (string-match-p "\\`[\"']" rest) (setq rest (substring rest 1)))
    (setq rest (string-trim-left rest "[ \t]+"))
    (when (string-match-p "\\`[=:]" rest)
      (let* ((v (string-trim-left (substring rest 1) "[ \t]+"))
             (v (car (split-string v "[[:space:]]" nil)))
             (v (string-trim (or v "") "[\"',;]+" "[\"',;]+")))
        (>= (length v) 8)))))

(defun drgnx-secrets--entropy (token)
  "Shannon entropy of the ASCII TOKEN in bits per character."
  (let ((counts (make-hash-table)) (n (float (length token))) (sum 0.0))
    (mapc (lambda (c) (puthash c (1+ (gethash c counts 0)) counts)) token)
    (maphash (lambda (_ c) (let ((p (/ c n))) (setq sum (- sum (* p (log p 2)))))) counts)
    sum))

(defun drgnx-secrets--high-entropy-p (token)
  "Whether TOKEN is 40 characters or more, of three classes or more, with 4.5 bits per character or more."
  (let ((case-fold-search nil) (n (length token)))
    (and (>= n 40)
         (not (and (memq n '(40 64)) (string-match-p "\\`[0-9a-fA-F]+\\'" token)))
         (>= (cl-count-if #'identity (list (string-match-p "[a-z]" token) (string-match-p "[A-Z]" token)
                                           (string-match-p "[0-9]" token) (string-match-p "[+_-]" token)))
             3)
         (>= (drgnx-secrets--entropy token) 4.5))))

(defun drgnx-secrets-looks-like (text)
  "The name (a string) of the first rule of the shared secret table that TEXT matches, or nil.
The rules, in order: private-key, aws-key-id, key-prefix, assignment, high-entropy."
  (let ((case-fold-search nil))
    (cond ((string-match-p "-----BEGIN [A-Z ]*PRIVATE KEY-----" text) "private-key")
          ((string-match-p "AKIA[0-9A-Z]\\{16\\}" text) "aws-key-id")
          ((cl-some #'drgnx-secrets--key-prefix-p (drgnx-secrets--tokens text)) "key-prefix")
          ((let ((lower (downcase text)))
             (cl-some (lambda (k)
                        (let ((from 0) hit)
                          (while (and (not hit) (setq from (string-search k lower from)))
                            (setq from (+ from (length k))
                                  hit (drgnx-secrets--value-follows-p (substring text from))))
                          hit))
                      drgnx-secrets--keywords))
           "assignment")
          ((cl-some #'drgnx-secrets--high-entropy-p (drgnx-secrets--tokens text)) "high-entropy"))))

(provide 'drgnx-secrets-scan)
;;; drgnx-secrets-scan.el ends here
