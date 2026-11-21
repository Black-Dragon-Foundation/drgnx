; What a top-level C form defines.
((function_definition) @definition.function
 (#set! drgnx.name "c-declarator"))
(preproc_def name: (_) @name) @definition.macro
(preproc_function_def name: (_) @name) @definition.macro
(struct_specifier name: (_) @name body: (_)) @definition.struct
(union_specifier name: (_) @name body: (_)) @definition.union
(enum_specifier name: (_) @name body: (_)) @definition.enum
(type_definition declarator: (_) @name @definition.type)

; a declaration or typedef holds the specifier it defines
(declaration) @transparent
(type_definition) @transparent
