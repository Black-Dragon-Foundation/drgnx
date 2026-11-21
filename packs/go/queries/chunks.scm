; What a top-level Go declaration defines. A declaration of several specs gives each its own span.
(function_declaration name: (_) @name) @definition.function
(method_declaration name: (_) @name) @definition.method
((type_spec name: (_) @name type: (struct_type)) @definition.struct
 (#set! drgnx.split))
((type_spec name: (_) @name type: (interface_type)) @definition.interface
 (#set! drgnx.split))
((type_spec name: (_) @name) @definition.type
 (#set! drgnx.split))
((type_alias name: (_) @name) @definition.type
 (#set! drgnx.split))
((const_spec name: (_) @name) @definition.constant
 (#set! drgnx.split))
((var_spec name: (_) @name) @definition.variable
 (#set! drgnx.split))
(var_spec_list) @skip

; a declaration holds the specs it defines
(type_declaration) @transparent
(const_declaration) @transparent
(var_declaration) @transparent
