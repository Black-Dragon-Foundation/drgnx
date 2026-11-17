;; Fold ranges (docs/develop/packs.md, "Fold queries"): @fold.KIND captures (function, class, comment, import, test,
;; region, cell, heading) and plain @fold (a block).  A node folds from its first line to its last; a node within one
;; line is no range, and of the nodes starting on one line the largest stays (on a tie, the more specific kind).
;; Predicates: #eq?, #not-eq?, #any-of? and #match? only, a #match? pattern in the subset Emacs and Rust regexps share.
;; Written for drgnx; which nodes fold follows nvim-treesitter's folds.scm (Apache-2.0, LICENSES/Apache-2.0.txt).

(function_item) @fold.function
(closure_expression) @fold.function
(macro_definition) @fold.function
[(impl_item) (trait_item) (struct_item) (enum_item) (union_item) (mod_item)] @fold.class
(use_declaration) @fold.import
(block_comment) @fold.comment

; #[test] fn …, and #[cfg(test)] mod …
((attribute_item (attribute (identifier) @_test)) . (function_item) @fold.test
 (#eq? @_test "test"))
((attribute_item (attribute (identifier) @_cfg (token_tree (identifier) @_t))) . (mod_item) @fold.test
 (#eq? @_cfg "cfg") (#eq? @_t "test"))

[(block) (match_block) (match_arm) (arguments) (parameters) (array_expression) (field_initializer_list)
 (field_declaration_list) (enum_variant_list) (declaration_list) (token_tree) (use_list)] @fold
