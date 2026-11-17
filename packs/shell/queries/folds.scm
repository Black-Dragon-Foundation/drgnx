;; Fold ranges (docs/develop/packs.md, "Fold queries"): @fold.KIND captures (function, class, comment, import, test,
;; region, cell, heading) and plain @fold (a block).  A node folds from its first line to its last; a node within one
;; line is no range, and of the nodes starting on one line the largest stays (on a tie, the more specific kind).
;; Predicates: #eq?, #not-eq?, #any-of? and #match? only, a #match? pattern in the subset Emacs and Rust regexps share.
;; Written for drgnx; which nodes fold follows nvim-treesitter's folds.scm (Apache-2.0, LICENSES/Apache-2.0.txt).

(function_definition) @fold.function

[(compound_statement) (subshell) (if_statement) (elif_clause) (else_clause) (for_statement) (c_style_for_statement)
 (while_statement) (case_statement) (case_item) (do_group)] @fold
