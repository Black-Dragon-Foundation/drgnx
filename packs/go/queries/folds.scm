;; Fold ranges (docs/develop/packs.md, "Fold queries"): @fold.KIND captures (function, class, comment, import, test,
;; region, cell, heading) and plain @fold (a block).  A node folds from its first line to its last; a node within one
;; line is no range, and of the nodes starting on one line the largest stays (on a tie, the more specific kind).
;; Predicates: #eq?, #not-eq?, #any-of? and #match? only, a #match? pattern in the subset Emacs and Rust regexps share.
;; Written for drgnx; which nodes fold follows nvim-treesitter's folds.scm (Apache-2.0, LICENSES/Apache-2.0.txt).

[(function_declaration) (method_declaration) (func_literal)] @fold.function
(type_declaration) @fold.class
(import_declaration) @fold.import
(comment) @fold.comment

; TestX, BenchmarkX, FuzzX, ExampleX
((function_declaration name: (identifier) @_name) @fold.test (#match? @_name "^Test"))
((function_declaration name: (identifier) @_name) @fold.test (#match? @_name "^Benchmark"))
((function_declaration name: (identifier) @_name) @fold.test (#match? @_name "^Fuzz"))
((function_declaration name: (identifier) @_name) @fold.test (#match? @_name "^Example"))

[(block) (literal_value) (argument_list) (parameter_list) (field_declaration_list) (interface_type)
 (expression_switch_statement) (type_switch_statement) (select_statement) (expression_case) (type_case)
 (communication_case) (default_case) (const_declaration) (var_declaration)] @fold
