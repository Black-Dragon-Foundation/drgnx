;; Fold ranges (docs/develop/packs.md, "Fold queries"): @fold.KIND captures (function, class, comment, import, test,
;; region, cell, heading) and plain @fold (a block).  A node folds from its first line to its last; a node within one
;; line is no range, and of the nodes starting on one line the largest stays (on a tie, the more specific kind).
;; Predicates: #eq?, #not-eq?, #any-of? and #match? only, a #match? pattern in the subset Emacs and Rust regexps share.
;; Written for drgnx; which nodes fold follows nvim-treesitter's folds.scm (Apache-2.0, LICENSES/Apache-2.0.txt).

(function_definition) @fold.function
[(struct_specifier body: (_)) (union_specifier body: (_)) (enum_specifier body: (_))] @fold.class
(comment) @fold.comment

[(compound_statement) (initializer_list) (argument_list) (parameter_list) (field_declaration_list) (enumerator_list)
 (case_statement) (preproc_if) (preproc_ifdef) (preproc_elif) (preproc_else)] @fold
