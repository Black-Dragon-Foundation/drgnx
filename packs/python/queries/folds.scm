;; Fold ranges (docs/develop/packs.md, "Fold queries"): @fold.KIND captures (function, class, comment, import, test,
;; region, cell, heading) and plain @fold (a block).  A node folds from its first line to its last; a node within one
;; line is no range, and of the nodes starting on one line the largest stays (on a tie, the more specific kind).
;; Predicates: #eq?, #not-eq?, #any-of? and #match? only, a #match? pattern in the subset Emacs and Rust regexps share.
;; Written for drgnx; which nodes fold follows nvim-treesitter's folds.scm (Apache-2.0, LICENSES/Apache-2.0.txt).

(function_definition) @fold.function
(class_definition) @fold.class
(import_from_statement) @fold.import
(expression_statement (string) @fold.comment)

; test_… functions and Test… classes (pytest, unittest)
((function_definition name: (identifier) @_name) @fold.test
 (#match? @_name "^test"))
((class_definition name: (identifier) @_name) @fold.test
 (#match? @_name "^Test"))

[(if_statement) (elif_clause) (else_clause) (for_statement) (while_statement) (try_statement) (except_clause)
 (finally_clause) (with_statement) (match_statement) (case_clause) (dictionary) (list) (tuple) (set)
 (argument_list) (parameters) (list_comprehension) (dictionary_comprehension) (parenthesized_expression)] @fold
