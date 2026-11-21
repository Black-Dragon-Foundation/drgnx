;;; dart: a built-in language pack (docs/develop/packs.md)
(:pack "dart" :schema 1 :version "1" :name "Dart" :summary "Dart language support"
 :files (:extensions ("dart"))
 :mode (:classic dart-mode)
 :format (:formatter dart :command ("dart" "format") :standard t)
 :adapters ((:id "flutter" :name "Dart, Flutter" :types ("dart" "flutter") :not-built-in t))
 :license "GPL-3.0-or-later" :maintainers ("drgnx"))
