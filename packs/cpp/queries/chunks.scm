; What a top-level C++ form defines; classes, structs, unions, namespaces and extern blocks hold members.
(class_specifier) @container
(struct_specifier) @container
(union_specifier) @container
(namespace_definition) @container
(linkage_specification) @container

; a function written in a class body is a method: this comes before the function pattern
((field_declaration_list (function_definition) @definition.method)
 (#set! drgnx.name "c-declarator"))
((function_definition) @definition.function
 (#set! drgnx.name "c-declarator"))
; a specialization's name is the template's (`Hash<Foo*>` is `Hash`)
(class_specifier name: [(type_identifier) @name (template_type name: (_) @name)] body: (_)) @definition.class
(struct_specifier name: [(type_identifier) @name (template_type name: (_) @name)] body: (_)) @definition.struct
(union_specifier name: [(type_identifier) @name (template_type name: (_) @name)] body: (_)) @definition.union
(enum_specifier name: (_) @name body: (_)) @definition.enum
(namespace_definition name: (_) @name) @definition.namespace
(alias_declaration name: (_) @name) @definition.type
(type_definition declarator: (_) @name @definition.type)
(concept_definition name: (_) @name) @definition.concept
(preproc_def name: (_) @name) @definition.macro
(preproc_function_def name: (_) @name) @definition.macro

; a declaration, typedef or member declaration holds the specifier it defines
(declaration) @transparent
(type_definition) @transparent
(field_declaration) @transparent

; template <...> wraps the class, function or alias it makes generic
(template_declaration
  [(class_specifier) (struct_specifier) (function_definition) (declaration) (alias_declaration) (concept_definition)] @wrapped) @wrapper
