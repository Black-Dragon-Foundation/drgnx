; What a top-level Python statement defines; a class's methods are members.
(class_definition) @container

; a function directly in a class is a method (before the function pattern)
(class_definition body: (block (function_definition name: (_) @name) @definition.method))
(class_definition body: (block (decorated_definition definition: (function_definition name: (_) @name) @definition.method)))

(function_definition name: (_) @name) @definition.function
(class_definition name: (_) @name) @definition.class

; a decorated definition is its definition, wrapped
(decorated_definition definition: (_) @wrapped) @wrapper

; docstrings
(function_definition body: (block . (expression_statement (string) @doc))) @docowner
(class_definition body: (block . (expression_statement (string) @doc))) @docowner
