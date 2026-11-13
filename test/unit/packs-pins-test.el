;;; packs-pins-test.el --- batch tests: every built-in pack's grammar pin is the pin of the Emacs mode that uses it -*- lexical-binding: t -*-
;; test-class: det
;; The pack follows the mode (docs/develop/packs.md): a Nidhogg rebase that moves a mode's grammar pin fails here, not in
;; a user's highlighting.  Each mode file is loaded (its `treesit-language-source-alist' entry is added by loading it),
;; under the library's own ABI (Rust's and PHP's modes pin a different commit under ABI < 15).
(require 'ert)
(require 'treesit)
(require 'drgnx-paths)
(require 'drgnx-packs)

(defun drgnx-packs-pins-test--entry (lang mode)
  "LANG's `treesit-language-source-alist' entry once MODE's library is loaded."
  (when (and (symbolp mode) (autoloadp (symbol-function mode)))
    (autoload-do-load (symbol-function mode) mode))
  (assq lang treesit-language-source-alist))

(ert-deftest drgnx-packs-pins/the-library-is-abi-15 ()
  ;; the pack pins are the modes' pins under ABI 15 (Rust's and PHP's modes pin another commit below it)
  (should (>= (treesit-library-abi-version) 15)))

(ert-deftest drgnx-packs-pins/every-builtin-grammar-is-the-pin-of-its-mode ()
  (let ((drgnx-packs-dir nil) (drgnx-packs--manifests nil) (checked 0))
    (dolist (p (drgnx-packs-builtins))
      (let* ((m (cdr p)) (mode (plist-get m :mode)) (ts (plist-get mode :ts)))
        (when (and ts (plist-get mode :builtin))
          (dolist (g (drgnx-packs--owned-grammars m))
            (let* ((lang (plist-get g :name)) (e (drgnx-packs-pins-test--entry lang ts)))
              (should (list (car p) lang e))
              (should e)
              (let ((url (nth 1 e)) (plist (nthcdr 2 e)))
                (should (equal (list (car p) lang url) (list (car p) lang (plist-get g :repo))))
                (should (equal (list (car p) lang (plist-get plist :commit)) (list (car p) lang (plist-get g :commit))))
                (should (equal (list (car p) lang (or (plist-get plist :source-dir) "src"))
                               (list (car p) lang (or (plist-get g :src) "src")))))
              (cl-incf checked))))))
    (should (>= checked 17))))

(ert-deftest drgnx-packs-pins/a-pack-without-a-builtin-mode-pins-nothing-to-compare ()
  (let ((drgnx-packs-dir nil) (drgnx-packs--manifests nil))
    (dolist (name '("terraform" "dart"))
      (should-not (plist-get (drgnx-packs-manifest name) :grammars)))))

(provide 'packs-pins-test)
;;; packs-pins-test.el ends here
