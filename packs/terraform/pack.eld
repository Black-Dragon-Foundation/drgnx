;;; terraform: a built-in language pack (docs/develop/packs.md)
(:pack "terraform" :schema 1 :version "1" :name "Terraform" :summary "Terraform language support"
 :files (:extensions ("tf" "tfvars"))
 :mode (:classic terraform-mode)
 :format (:formatter terraform :command ("terraform" "fmt" "-") :standard t)
 :license "GPL-3.0-or-later" :maintainers ("drgnx"))
