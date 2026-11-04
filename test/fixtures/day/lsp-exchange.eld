;; A recorded language-server exchange: (METHOD . RESULT), RESULT as JSON text.  test/fixtures/lsp-replay.el answers a
;; request of that METHOD with its RESULT; any other request with null.  Notifications are not answered.
(("initialize" . "{\"capabilities\":{\"textDocumentSync\":{\"openClose\":true,\"change\":1},\"hoverProvider\":false},\"serverInfo\":{\"name\":\"replay\",\"version\":\"1\"}}")
 ("shutdown" . "null"))
