;; Fold ranges (docs/develop/packs.md, "Fold queries"): @fold.KIND captures (function, class, comment, import, test,
;; region, cell, heading) and plain @fold (a block).  A node folds from its first line to its last; a node within one
;; line is no range, and of the nodes starting on one line the largest stays (on a tie, the more specific kind).
;; Predicates: #eq?, #not-eq?, #any-of? and #match? only, a #match? pattern in the subset Emacs and Rust regexps share.
;; Written for drgnx; which nodes fold follows nvim-treesitter's folds.scm (Apache-2.0, LICENSES/Apache-2.0.txt).

[(function_declaration) (function_expression) (generator_function_declaration) (generator_function)
 (arrow_function) (method_definition)] @fold.function
[(class_declaration) (class)] @fold.class
(comment) @fold.comment
(import_statement) @fold.import

; describe(…), it(…), test(…)
((call_expression function: (identifier) @_fn) @fold.test
 (#any-of? @_fn "describe" "it" "test"))

[(statement_block) (object) (array) (arguments) (formal_parameters) (template_string) (switch_body) (switch_case)
 (class_body) (object_pattern) (array_pattern) (named_imports) (export_clause) (parenthesized_expression)] @fold
[(interface_declaration) (enum_declaration) (abstract_class_declaration) (internal_module) (module)] @fold.class
[(object_type) (enum_body)] @fold
