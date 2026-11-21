; What a top-level JavaScript statement defines; a class's methods are members.
(class_declaration) @container
(class) @container

(function_declaration name: (_) @name) @definition.function
(generator_function_declaration name: (_) @name) @definition.function
(class_declaration name: (_) @name) @definition.class
(class name: (_) @name) @definition.class
(method_definition name: (_) @name) @definition.method

; a const holding a function is a function
(lexical_declaration
  (variable_declarator name: (identifier) @name
    value: [(arrow_function) (function_expression) (generator_function)]) @definition.function)
(variable_declaration
  (variable_declarator name: (identifier) @name
    value: [(arrow_function) (function_expression) (generator_function)]) @definition.function)
(lexical_declaration) @transparent
(variable_declaration) @transparent

(export_statement declaration: (_) @wrapped) @wrapper
(export_statement value: (_) @wrapped) @wrapper
