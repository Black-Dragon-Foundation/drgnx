; What a C# declaration defines; a type's methods, constructors, properties and nested types are members, and a namespace's
; types are its members (a file-scoped `namespace N;` has no body: its types sit at the top).
(class_declaration) @container
(struct_declaration) @container
(interface_declaration) @container
(record_declaration) @container
(namespace_declaration) @container

(class_declaration name: (_) @name) @definition.class
(struct_declaration name: (_) @name) @definition.struct
(interface_declaration name: (_) @name) @definition.interface
(enum_declaration name: (_) @name) @definition.enum
(record_declaration name: (_) @name) @definition.record
(delegate_declaration name: (_) @name) @definition.delegate
(namespace_declaration name: (_) @name) @definition.namespace
(method_declaration name: (_) @name) @definition.method
(constructor_declaration name: (_) @name) @definition.constructor
(destructor_declaration name: (_) @name) @definition.destructor
(operator_declaration operator: _ @name) @definition.operator
(property_declaration name: (_) @name) @definition.property
(event_declaration name: (_) @name) @definition.event
(event_field_declaration (variable_declaration (variable_declarator (identifier) @name))) @definition.event
