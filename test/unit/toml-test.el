;;; toml-test.el --- batch tests: the TOML reader and the one-table writer -*- lexical-binding: t -*-
(require 'ert)
(require 'drgnx-toml)

(defconst drgnx-toml-test--codex
  "# Codex config, edited by hand
model = \"gpt-5\"   # the default
approval_policy = \"on-request\"

# GitHub
[mcp_servers.a]
command = \"npx\"
args = [\"-y\", \"@x/server\"]
env = { TOKEN = \"abc\", \"A B\" = 1 }

# the second server
[mcp_servers.b.env]
KEY = 'lit\\eral'

[[skills.config]]
path = \"/skills/one\"
enabled = true

[[skills.config]]
path = \"/skills/two\"
enabled = false

[projects.\"/p\"]
trust_level = \"trusted\"
"
  "A config shaped like Codex's own.")

(defun drgnx-toml-test--err (string)
  "The data of the `drgnx-toml-error' STRING raises when parsed."
  (cdr (should-error (drgnx-toml-parse string) :type 'drgnx-toml-error)))

(ert-deftest drgnx-toml/parses-codex-config ()
  (should (equal (drgnx-toml-parse drgnx-toml-test--codex)
                 '(("model" . "gpt-5")
                   ("approval_policy" . "on-request")
                   ("mcp_servers"
                    ("a" ("command" . "npx")
                     ("args" . ["-y" "@x/server"])
                     ("env" ("TOKEN" . "abc") ("A B" . 1)))
                    ("b" ("env" ("KEY" . "lit\\eral"))))
                   ("skills"
                    ("config" . [(("path" . "/skills/one") ("enabled" . t))
                                 (("path" . "/skills/two") ("enabled" . :false))]))
                   ("projects" ("/p" ("trust_level" . "trusted")))))))

(ert-deftest drgnx-toml/value-forms ()
  (should (equal (drgnx-toml-parse
                  (concat "a = 1_000\nb = -3\nc = 0xff\nd = 1.5e2\ne = inf\nf = 1979-05-27\ng = 1979-05-27 07:32:00Z\n"
                          "h = \"a\\tb\\u00e9\"\ni = \"\"\"\nline one\nline \\\n   two\"\"\"\nj = '''raw\\n'''\n"
                          "k = [\n  1,\n  # c\n  2,\n]\nl = {}\nm.n.o = 1\n[p]\nq = [[1, 2], [3]]\n"))
                 `(("a" . 1000) ("b" . -3) ("c" . 255) ("d" . 150.0) ("e" . 1.0e+INF)
                   ("f" . "1979-05-27") ("g" . "1979-05-27 07:32:00Z")
                   ("h" . ,(concat "a\tb" (string #xe9)))
                   ("i" . "line one\nline two") ("j" . "raw\\n")
                   ("k" . [1 2]) ("l") ("m" ("n" ("o" . 1)))
                   ("p" ("q" . [[1 2] [3]]))))))

(ert-deftest drgnx-toml/syntax-error-has-the-line ()
  (let ((err (drgnx-toml-test--err "a = 1\nb = 2\n\n[t]\nc = 3\n# x\nname = \"unterminated\nd = 4\n")))
    (should (equal (car err) 7))
    (should (stringp (cadr err))))
  (should (equal (car (drgnx-toml-test--err "a = 1\nb = \n")) 2))
  (should (equal (car (drgnx-toml-test--err "a = 1\na = 2\n")) 2))
  (should (equal (car (drgnx-toml-test--err "[t]\n[t]\n")) 2))
  (should (equal (car (drgnx-toml-test--err "x = [1,\n 2\ny = 3\n")) 3)))

(ert-deftest drgnx-toml/set-table-keeps-every-other-byte ()
  (let* ((old drgnx-toml-test--codex)
         (region (drgnx-toml-table-region old '("mcp_servers" "a")))
         (new (drgnx-toml-set-table old '("mcp_servers" "a")
                                    '(("command" . "uvx") ("env" ("TOKEN" . "x\"y")) ("args" . ["z"])))))
    (should region)
    (should (string-prefix-p "[mcp_servers.a]" (substring old (car region))))
    ;; the region ends with the env line; the comment that leads to the next table is outside it
    (should (string-suffix-p "\"A B\" = 1 }\n" (substring old 0 (cdr region))))
    (should (equal (substring new 0 (car region)) (substring old 0 (car region))))
    (should (string-prefix-p "\n# the second server\n" (substring old (cdr region))))
    (should (equal new (concat (substring old 0 (car region))
                               "[mcp_servers.a]\ncommand = \"uvx\"\nenv = { TOKEN = \"x\\\"y\" }\nargs = [\"z\"]\n"
                               (substring old (cdr region)))))
    (should (string-match-p "# GitHub\n\\[mcp_servers.a\\]\ncommand = \"uvx\"\n" new))
    (should (string-match-p "# the second server\n\\[mcp_servers.b.env\\]" new))
    (should (string-prefix-p "# Codex config, edited by hand\nmodel = \"gpt-5\"   # the default" new))
    (should (equal (cdr (assoc "a" (cdr (assoc "mcp_servers" (drgnx-toml-parse new)))))
                   '(("command" . "uvx") ("env" ("TOKEN" . "x\"y")) ("args" . ["z"]))))))

(ert-deftest drgnx-toml/a-table-with-sub-tables-is-one-region ()
  (let* ((old "[a]\nx = 1\n\n[a.b]\ny = 2\n[a.b.c]\nz = 3\n# tail comment\n\n[d]\nk = 1\n")
         (region (drgnx-toml-table-region old '("a")))
         (new (drgnx-toml-set-table old '("a") '(("x" . 9)))))
    (should (equal (substring old (car region) (cdr region)) "[a]\nx = 1\n\n[a.b]\ny = 2\n[a.b.c]\nz = 3\n"))
    (should (equal new "[a]\nx = 9\n# tail comment\n\n[d]\nk = 1\n"))
    (should (equal (drgnx-toml-table-region old '("a" "b")) '(11 . 37)))
    (should-not (drgnx-toml-table-region old '("zz")))))

(ert-deftest drgnx-toml/add-and-remove-a-table ()
  (let* ((old drgnx-toml-test--codex)
         (added (drgnx-toml-set-table old '("model_providers" "openrouter")
                                      '(("name" . "OpenRouter") ("base_url" . "https://openrouter.ai/api/v1")))))
    (should (string-prefix-p old added))
    (should (string-suffix-p "\n[model_providers.openrouter]\nname = \"OpenRouter\"\nbase_url = \"https://openrouter.ai/api/v1\"\n"
                             added))
    ;; removing it brings back the original, byte for byte
    (should (equal (drgnx-toml-set-table added '("model_providers" "openrouter") nil) old))
    ;; a middle table goes without leaving a double blank line
    (should (equal (drgnx-toml-set-table "x = 1\n\n[a]\nk = 1\n\n[b]\nk = 2\n" '("a") nil) "x = 1\n\n[b]\nk = 2\n"))
    ;; removing what is not there changes nothing
    (should (equal (drgnx-toml-set-table old '("nope") nil) old))
    ;; an empty or unterminated file
    (should (equal (drgnx-toml-set-table "" '("a" "b") '(("k" . t))) "[a.b]\nk = true\n"))
    (should (equal (drgnx-toml-set-table "x = 1" '("a") '(("k" . :false))) "x = 1\n\n[a]\nk = false\n"))
    ;; quoted names
    (should (equal (drgnx-toml-set-table "" '("projects" "/p") '(("trust_level" . "trusted")))
                   "[projects.\"/p\"]\ntrust_level = \"trusted\"\n"))))

(ert-deftest drgnx-toml/array-entry-replace-append-remove ()
  (let* ((old drgnx-toml-test--codex)
         (is (lambda (p) (lambda (e) (equal (cdr (assoc "path" e)) p))))
         (replaced (drgnx-toml-set-array-entry old '("skills" "config") (funcall is "/skills/two")
                                               '(("path" . "/skills/two") ("enabled" . t))))
         (appended (drgnx-toml-set-array-entry old '("skills" "config") (funcall is "/skills/three")
                                               '(("path" . "/skills/three") ("enabled" . t))))
         (removed (drgnx-toml-set-array-entry old '("skills" "config") (funcall is "/skills/one") nil)))
    ;; replace: only the second entry's lines differ
    (should (equal replaced (string-replace "enabled = false" "enabled = true" old)))
    ;; append: at the end, after a blank line
    (should (string-prefix-p old appended))
    (should (string-suffix-p "\n[[skills.config]]\npath = \"/skills/three\"\nenabled = true\n" appended))
    (should (= 3 (length (cdr (assoc "config" (cdr (assoc "skills" (drgnx-toml-parse appended))))))))
    ;; remove: the first entry and its blank line are gone, everything else stays
    (should (equal removed (replace-regexp-in-string "\\[\\[skills.config\\]\\]\npath = \"/skills/one\"\nenabled = true\n\n" "" old)))
    (should (equal (drgnx-toml-set-array-entry old '("skills" "config") (funcall is "/nope") nil) old))
    ;; an entry's sub-table belongs to it
    (let ((nested "[[a]]\nn = 1\n[a.sub]\nx = 1\n\n[[a]]\nn = 2\n"))
      (should (equal (drgnx-toml-set-array-entry nested '("a") (lambda (e) (equal (cdr (assoc "n" e)) 1)) '(("n" . 5)))
                     "[[a]]\nn = 5\n\n[[a]]\nn = 2\n"))
      ;; PRED sees the entry with its sub-table
      (let (seen)
        (drgnx-toml-set-array-entry nested '("a") (lambda (e) (push e seen) nil) nil)
        (should (equal (car (last seen)) '(("n" . 1) ("sub" ("x" . 1)))))))))

(ert-deftest drgnx-toml/other-forms-refused ()
  (let ((dotted "model = 1\nmcp_servers.c.command = \"x\"\n")
        (inline "[t]\nk = 1\n\n[u]\nx = { d = { command = \"y\" } }\n")
        (inline-top "mcp_servers = { d = { command = \"y\" } }\n"))
    ;; they parse
    (should (equal (cdr (assoc "mcp_servers" (drgnx-toml-parse dotted))) '(("c" ("command" . "x")))))
    (should (equal (cdr (assoc "d" (cdr (assoc "mcp_servers" (drgnx-toml-parse inline-top)))))
                   '(("command" . "y"))))
    ;; but are not edited, and the error names the line
    (let ((err (should-error (drgnx-toml-set-table dotted '("mcp_servers" "c") '(("command" . "z")))
                             :type 'drgnx-toml-error)))
      (should (equal (cadr err) 2))
      (should (string-match-p "does not edit" (nth 2 err))))
    (let ((err (should-error (drgnx-toml-set-table inline-top '("mcp_servers" "d") '(("command" . "z")))
                             :type 'drgnx-toml-error)))
      (should (equal (cadr err) 1)))
    (let ((err (should-error (drgnx-toml-set-table inline '("u" "x" "d") nil) :type 'drgnx-toml-error)))
      (should (equal (cadr err) 5)))
    ;; a table that is really an array of tables, or sits under one
    (should (equal (cadr (should-error (drgnx-toml-set-table drgnx-toml-test--codex '("skills" "config") '(("a" . 1)))
                                       :type 'drgnx-toml-error))
                   15))
    (should (should-error (drgnx-toml-set-table drgnx-toml-test--codex '("skills" "config" "x") '(("a" . 1)))
                          :type 'drgnx-toml-error))
    ;; a table in two pieces
    (should (equal (cadr (should-error (drgnx-toml-set-table "[a.b]\nx = 1\n[c]\ny = 1\n[a.d]\nz = 1\n" '("a")
                                                             '(("k" . 1)))
                                       :type 'drgnx-toml-error))
                   5))
    ;; an array of tables written as an inline array
    (should (should-error (drgnx-toml-set-array-entry "config = [{ path = \"x\" }]\n" '("config") #'ignore '(("path" . "y")))
                          :type 'drgnx-toml-error))
    ;; nothing is written when it is refused: the same string is untouched (strings are immutable), and a
    ;; table that does not clash with the dotted key is fine
    (should (string-suffix-p "[mcp_servers.e]\ncommand = \"q\"\n"
                             (drgnx-toml-set-table dotted '("mcp_servers" "e") '(("command" . "q")))))))

(ert-deftest drgnx-toml/header-lookalikes-and-crlf ()
  ;; a header written inside a multi-line string or an array is not a header
  (let* ((old "[a]\nnote = \"\"\"\n[b]\nx = 1\n\"\"\"\nlist = [\n  # [c]\n  \"[d]\",\n]\n\n[e]\nk = 1\n")
         (new (drgnx-toml-set-table old '("a") '(("n" . 1)))))
    (should (equal (cdr (assoc "a" (drgnx-toml-parse old)))
                   '(("note" . "[b]\nx = 1\n") ("list" . ["[d]"]))))
    (should (equal new "[a]\nn = 1\n\n[e]\nk = 1\n")))
  ;; CRLF files: the bytes outside the table stay, line ends included
  (let* ((old "x = 1\r\n\r\n[a]\r\nk = 1 # c\r\n\r\n[b]\r\nk = 2\r\n")
         (new (drgnx-toml-set-table old '("a") '(("k" . 2)))))
    (should (equal (drgnx-toml-parse old) '(("x" . 1) ("a" ("k" . 1)) ("b" ("k" . 2)))))
    (should (string-prefix-p "x = 1\r\n\r\n[a]\nk = 2\n" new))
    (should (equal new "x = 1\r\n\r\n[a]\nk = 2\n\r\n[b]\r\nk = 2\r\n"))))

(ert-deftest drgnx-toml/encodes-values ()
  (should (equal (drgnx-toml-encode-value "a\"b\\c\nd\x01") "\"a\\\"b\\\\c\\nd\\u0001\""))
  (should (equal (drgnx-toml-encode-value ["x" 1 2.5 t :false]) "[\"x\", 1, 2.5, true, false]"))
  (should (equal (drgnx-toml-encode-value '(("a" . 1) ("b c" ("d" . "e")))) "{ a = 1, \"b c\" = { d = \"e\" } }"))
  (should (equal (drgnx-toml-encode-value nil) "{}"))
  (should (equal (drgnx-toml-encode-value [(("k" . 1))]) "[{ k = 1 }]"))
  (should (equal (drgnx-toml-encode-value 1.0e+INF) "inf"))
  (should (equal (drgnx-toml-encode-value 3) "3"))
  (should-error (drgnx-toml-encode-value '(1 2)) :type 'drgnx-toml-error)
  ;; what is written reads back as it was
  (let ((tbl '(("s" . "q\"\\\t\u00e9") ("v" . [1 2.5 "x"]) ("t" ("n" ("k" . t)) ("f" . :false)))))
    (should (equal (drgnx-toml-parse (drgnx-toml-set-table "" '("x") tbl)) (list (cons "x" tbl))))))

(provide 'toml-test)
