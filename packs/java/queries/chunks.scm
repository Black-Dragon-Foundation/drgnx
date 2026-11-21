; What a Java declaration defines; a type's methods, constructors and nested types are members.
(class_declaration) @container
(interface_declaration) @container
(enum_declaration) @container
(record_declaration) @container
(annotation_type_declaration) @container

(class_declaration name: (_) @name) @definition.class
(interface_declaration name: (_) @name) @definition.interface
(annotation_type_declaration name: (_) @name) @definition.interface
(enum_declaration name: (_) @name) @definition.enum
(record_declaration name: (_) @name) @definition.record
(method_declaration name: (_) @name) @definition.method
(constructor_declaration name: (_) @name) @definition.constructor

(enum_body_declarations) @skip
