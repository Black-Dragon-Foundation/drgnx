;; Fold ranges (docs/develop/packs.md, "Fold queries"): @fold.KIND captures (function, class, comment, import, test,
;; region, cell, heading) and plain @fold (a block).  A node folds from its first line to its last; a node within one
;; line is no range, and of the nodes starting on one line the largest stays (on a tie, the more specific kind).
;; Predicates: #eq?, #not-eq?, #any-of? and #match? only, a #match? pattern in the subset Emacs and Rust regexps share.
;; Written for drgnx; which nodes fold follows nvim-treesitter's folds.scm (Apache-2.0, LICENSES/Apache-2.0.txt).

[(method_declaration) (constructor_declaration) (lambda_expression)] @fold.function
[(class_declaration) (interface_declaration) (enum_declaration) (record_declaration) (annotation_type_declaration)]
 @fold.class
(block_comment) @fold.comment

; @Test methods (JUnit)
((method_declaration (modifiers (marker_annotation name: (identifier) @_a))) @fold.test
 (#eq? @_a "Test"))

[(block) (class_body) (interface_body) (enum_body) (constructor_body) (argument_list) (formal_parameters)
 (array_initializer) (switch_block)] @fold
