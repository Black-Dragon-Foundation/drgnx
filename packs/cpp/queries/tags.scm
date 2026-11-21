; The names a C++ file uses: calls, constructions and base classes (references only; definitions are chunks.scm's).
(call_expression function: (identifier) @name) @reference.call
(call_expression function: (field_expression field: (field_identifier) @name)) @reference.call
(call_expression function: (qualified_identifier name: (identifier) @name)) @reference.call
(call_expression function: (template_function name: (identifier) @name)) @reference.call
(new_expression type: (type_identifier) @name) @reference.class
(base_class_clause (type_identifier) @name) @reference.class
