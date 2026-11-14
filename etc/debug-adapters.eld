;;; debug-adapters.eld --- the debug adapters drgnx knows  -*- lisp-data -*-

;; The adapters of a language live in that language's pack (`packs/NAME/pack.eld`, `:adapters`, the same schema): debugpy in
;; python, js-debug in javascript, delve in go, bash-debug in shell, rdbg in ruby, cpptools in cpp, java, flutter in dart and
;; xdebug in php. What stays here serves no single language: the C/C++/Rust debuggers, .NET, Godot and OCaml.
;;
;; Read by the hub as data only (strings, numbers, symbols and lists; nothing is evaluated):
;; docs/develop/debugging.md, "Adapters". One entry per adapter:
;;
;;   :id        its name in drgnx
;;   :types     the launch.json `type`s it serves
;;   :languages the major-mode languages whose defaults it gives
;;   :tested    t when drgnx's live tests run it
;;   :find      how to find it: (:path "PROGRAM"), (:python-module "MODULE") or (:tools "RELATIVE/FILE")
;;   :start     (:stdio (ARGV...)) or (:tcp (ARGV...)); ARGV may hold {program} (what :find found), {python},
;;              {tools} and {port} (a free port on 127.0.0.1 the hub picks)
;;   :defaults  configurations offered when launch.json has none for the file's language
;;   :install   how to get it (Debug: Install Adapter; the picker's "not installed" row says which):
;;              (:pip "NAME==VERSION" :hash "sha256:…")  into the tools venv, the hash required;
;;              (:url "https://…" :sha256 "…" :into "DIR" [:root "FOLDER"])  a tar.gz or zip checked against the digest
;;                and unpacked to tools/DIR (only the archive's FOLDER, when given);
;;              (:into "DIR" :platforms ((:platform "linux-x64" :url … :sha256 …) …))  the same, one pin per platform
;;                (linux-x64, linux-arm64, darwin-x64, darwin-arm64);
;;              (:system "COMMAND")  a system package: the command is shown, never run
;;   :not-built-in t: drgnx names it but cannot start it; the user adds it in the setting `debug.adapters`
;;
;; The commands of the untested entries come from dape (https://github.com/svaante/dape, GPL-3.0-or-later), whose
;; recipes list each adapter's plain command line; thanks to its authors.

((:id "lldb-dap" :name "C, C++, Rust (lldb-dap)" :types ("lldb-dap" "lldb-vscode") :languages ("c" "c++" "rust")
  :tested t
  :find (:path "lldb-dap")
  :start (:stdio ("{program}"))
  :defaults ((:name "LLDB: Launch Program" :type "lldb-dap" :request "launch" :program "${input:program}"
              :cwd "${workspaceFolder}"))
  :install (:system "dnf install lldb"))
 (:id "gdb" :name "C, C++ (gdb)" :types ("gdb") :languages () :tested nil
  :find (:path "gdb")
  :start (:stdio ("{program}" "--interpreter=dap"))
  :install (:system "dnf install gdb"))
 (:id "codelldb" :name "C, C++, Rust (CodeLLDB)" :types ("lldb") :languages () :tested t
  :find (:tools "codelldb/extension/adapter/codelldb")
  :start (:tcp ("{program}" "--port" "{port}"))
  :install (:into "codelldb"
            :platforms
            ((:platform "linux-x64" :url "https://github.com/vadimcn/codelldb/releases/download/v1.12.3/codelldb-linux-x64.vsix"
              :sha256 "1cd7f386598022b51a5b93b9ffa23e812b23f519cfe1833384ec4bef4bfd1be1")
             (:platform "linux-arm64" :url "https://github.com/vadimcn/codelldb/releases/download/v1.12.3/codelldb-linux-arm64.vsix"
              :sha256 "0887f67d440554617894266f80706b700907c36b95e6e49d23b95a0e05318101")
             (:platform "darwin-x64" :url "https://github.com/vadimcn/codelldb/releases/download/v1.12.3/codelldb-darwin-x64.vsix"
              :sha256 "e25cc716b94c62c07fec268ff2785d2b797245b160502baef8b9c970a0c4d8e8")
             (:platform "darwin-arm64" :url "https://github.com/vadimcn/codelldb/releases/download/v1.12.3/codelldb-darwin-arm64.vsix"
              :sha256 "2f114a990e1b368dd1dbd33c80c0e719767af2d228391ec0df0571c957f9ac91"))))
 (:id "godot" :name "Godot" :types ("godot") :not-built-in t)
 (:id "ocamlearlybird" :name "OCaml (earlybird)" :types ("ocaml.earlybird") :not-built-in t))
