;;; debug-adapters.eld --- the debug adapters drgnx knows  -*- lisp-data -*-

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
;;   :install   how to get it, shown in the picker's "not installed" row
;;   :not-built-in t: drgnx names it but cannot start it; the user adds it in the setting `debug.adapters`
;;
;; The commands of the untested entries come from dape (https://github.com/svaante/dape, GPL-3.0-or-later), whose
;; recipes list each adapter's plain command line; thanks to its authors.

((:id "debugpy" :name "Python (debugpy)" :types ("debugpy" "python") :languages ("python") :tested t
  :find (:python-module "debugpy")
  :start (:stdio ("{python}" "-m" "debugpy.adapter"))
  :defaults ((:name "Python: Current File" :type "debugpy" :request "launch" :program "${file}"
              :console "integratedTerminal" :cwd "${workspaceFolder}"))
  :install (:pip "debugpy==1.8.22"
            :hash "sha256:a9e9d3550e15ca479c59333e90845029190531f0cacfedab3b815a57bd913947"))
 (:id "js-debug" :name "JavaScript (js-debug)" :types ("pwa-node" "node" "node-terminal")
  :languages ("javascript" "typescript" "js" "ts") :tested t
  :find (:tools "js-debug/src/dapDebugServer.js")
  :start (:tcp ("node" "{program}" "{port}" "127.0.0.1"))
  :defaults ((:name "Node: Launch File" :type "pwa-node" :request "launch" :program "${file}"
              :cwd "${workspaceFolder}"))
  :install (:url "https://github.com/microsoft/vscode-js-debug/releases/download/v1.140.1/js-debug-dap-v1.140.1.tar.gz"
            :sha256 "c72fab31bcbfdce6ad1f42adfd28eff8d4681dd3b03b5e2e6f9e72e6f9927faf" :into "js-debug"))
 (:id "delve" :name "Go (delve)" :types ("go") :languages ("go") :tested t
  :find (:path "dlv")
  :start (:tcp ("{program}" "dap" "--listen" "127.0.0.1:{port}"))
  :defaults ((:name "Go: Launch Package" :type "go" :request "launch" :mode "debug" :program "${fileDirname}"))
  :install (:system "dnf install delve"))
 (:id "lldb-dap" :name "C, C++, Rust (lldb-dap)" :types ("lldb-dap" "lldb-vscode") :languages ("c" "c++" "rust")
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
 (:id "bash-debug" :name "Bash (bash-debug)" :types ("bashdb") :languages () :tested nil
  :find (:tools "bash-debug/extension/out/bashDebug.js")
  :start (:stdio ("node" "{program}")))
 (:id "rdbg" :name "Ruby (rdbg)" :types ("rdbg") :languages () :tested nil
  :find (:path "rdbg")
  :start (:tcp ("{program}" "--open" "--host" "127.0.0.1" "--port" "{port}")))
 (:id "netcoredbg" :name ".NET (netcoredbg)" :types ("coreclr" "netcoredbg") :languages () :tested nil
  :find (:path "netcoredbg")
  :start (:stdio ("{program}" "--interpreter=vscode")))
 (:id "cpptools" :name "C, C++ (cpptools)" :types ("cppdbg" "cppvsdbg") :not-built-in t)
 (:id "codelldb" :name "C, C++, Rust (CodeLLDB)" :types ("lldb") :not-built-in t)
 (:id "java" :name "Java (jdtls)" :types ("java") :not-built-in t)
 (:id "flutter" :name "Dart, Flutter" :types ("dart" "flutter") :not-built-in t)
 (:id "godot" :name "Godot" :types ("godot") :not-built-in t)
 (:id "xdebug" :name "PHP (xdebug)" :types ("php") :not-built-in t)
 (:id "ocamlearlybird" :name "OCaml (earlybird)" :types ("ocaml.earlybird") :not-built-in t))
