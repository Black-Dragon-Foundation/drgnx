# Formatting

drgnx's Emacs Lisp is formatted by `bin/drgnx fmt`, the way Emacs itself indents it — nothing to configure, no
other tool.

```sh
bin/drgnx fmt                 # format every .el file of drgnx
bin/drgnx fmt FILE…           # just these
bin/drgnx fmt --check [FILE…] # report, change nothing (exit 1: a file would change)
```

What it does to each file:

- **Refuses a file that does not read** — an unbalanced parenthesis or an open string — and leaves it untouched
  (exit 2, with the file and line).
- **Learns how drgnx's own macros indent** from their `(declare (indent N))` (and `(put 'NAME
  'lisp-indent-function N)`) across the code, and loads the libraries drgnx uses (cl-lib, pcase, ert, svg, …) for
  theirs, so `(drgnx-work-test--with root …)` and `(ert-deftest …)` bodies indent as declared.
- **Reindents** every line (spaces, never tabs), **trims trailing whitespace**, ends the file with **one newline**.
- **Keeps the text of strings and comments**: docstring lines and trailing comments stay where they are.

It is enforced twice: the pre-commit hook (`.githooks/pre-commit`) refuses staged `.el` files that are not
formatted, and `test/unit/fmt-tree-test.el` fails when any file of the tree is not.
