; Tables and views
(create_table
  (object_reference
    name: (identifier) @name)) @definition.type

(create_view
  (object_reference
    name: (identifier) @name)) @definition.type

; Functions
(create_function
  (object_reference
    name: (identifier) @name)) @definition.function
