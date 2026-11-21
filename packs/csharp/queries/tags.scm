; The names a C# file uses: calls, constructions and base types (references only; definitions are chunks.scm's).
(invocation_expression function: (identifier) @name) @reference.call
(invocation_expression function: (member_access_expression name: (identifier) @name)) @reference.call
(invocation_expression function: (generic_name (identifier) @name)) @reference.call
(invocation_expression function: (member_access_expression name: (generic_name (identifier) @name))) @reference.call
(object_creation_expression type: (identifier) @name) @reference.class
(object_creation_expression type: (generic_name (identifier) @name)) @reference.class
(object_creation_expression type: (qualified_name name: (identifier) @name)) @reference.class
(object_creation_expression type: (qualified_name name: (generic_name (identifier) @name))) @reference.class
(base_list (identifier) @name) @reference.class
(base_list (generic_name (identifier) @name)) @reference.class
(base_list (qualified_name name: (identifier) @name)) @reference.class
(base_list (qualified_name name: (generic_name (identifier) @name))) @reference.class
