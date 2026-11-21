;; Fold ranges (docs/develop/packs.md, "Fold queries"): @fold.KIND captures (function, class, comment, import, test,
;; region, cell, heading) and plain @fold (a block).  A node folds from its first line to its last; a node within one
;; line is no range, and of the nodes starting on one line the largest stays (on a tie, the more specific kind).
;; Predicates: #eq?, #not-eq?, #any-of? and #match? only, a #match? pattern in the subset Emacs and Rust regexps share.
;; Written for drgnx; which nodes fold follows nvim-treesitter's folds.scm (Apache-2.0, LICENSES/Apache-2.0.txt).

[(method_declaration) (constructor_declaration) (destructor_declaration) (operator_declaration)
 (lambda_expression) (local_function_statement)] @fold.function
[(class_declaration) (interface_declaration) (struct_declaration) (enum_declaration) (record_declaration)
 (namespace_declaration)] @fold.class
(comment) @fold.comment

; [Test], [Fact], [Theory], [TestMethod] (NUnit, xUnit, MSTest)
((method_declaration (attribute_list (attribute name: (identifier) @_a))) @fold.test
 (#any-of? @_a "Test" "Fact" "Theory" "TestMethod"))

[(block) (declaration_list) (enum_member_declaration_list) (argument_list) (parameter_list) (accessor_list)
 (initializer_expression) (switch_section)] @fold
