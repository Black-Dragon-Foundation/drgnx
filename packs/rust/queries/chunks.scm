; What a top-level Rust item defines, and its members (language packs, docs/develop/packs.md: the chunker's rules).
(impl_item) @container
(trait_item) @container
(mod_item) @container

; functions inside an impl or a trait are methods: these come before the function patterns
(impl_item body: (declaration_list (function_item name: (_) @name) @definition.method))
(trait_item body: (declaration_list (function_item name: (_) @name) @definition.method))
(trait_item body: (declaration_list (function_signature_item name: (_) @name) @definition.method))

(function_item name: (_) @name) @definition.function
(function_signature_item name: (_) @name) @definition.function
(struct_item name: (_) @name) @definition.struct
(enum_item name: (_) @name) @definition.enum
(union_item name: (_) @name) @definition.union
(trait_item name: (_) @name) @definition.trait
(mod_item name: (_) @name) @definition.module
(macro_definition name: (_) @name) @definition.macro
(type_item name: (_) @name) @definition.type
(const_item name: (_) @name) @definition.constant
(static_item name: (_) @name) @definition.static
(impl_item type: (_) @name) @definition.impl
