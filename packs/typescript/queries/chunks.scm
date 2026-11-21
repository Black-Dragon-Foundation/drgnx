; What a top-level TypeScript statement defines; a class's methods and a namespace's declarations are members.
(class_declaration) @container
(abstract_class_declaration) @container
(class) @container
(internal_module) @container
(module) @container

(function_declaration name: (_) @name) @definition.function
(generator_function_declaration name: (_) @name) @definition.function
(class_declaration name: (_) @name) @definition.class
(class name: (_) @name) @definition.class
(method_definition name: (_) @name) @definition.method
(abstract_class_declaration name: (_) @name) @definition.class
(function_signature name: (_) @name) @definition.function
(abstract_method_signature name: (_) @name) @definition.method
(method_signature name: (_) @name) @definition.method
(interface_declaration name: (_) @name) @definition.interface
(type_alias_declaration name: (_) @name) @definition.type
(enum_declaration name: (_) @name) @definition.enum
(internal_module name: (_) @name) @definition.module
(module name: (_) @name) @definition.module

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
(expression_statement . [(internal_module) (module)] @wrapped .) @wrapper
