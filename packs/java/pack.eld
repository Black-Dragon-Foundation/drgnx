;;; java: a built-in language pack (docs/develop/packs.md)
(:pack "java" :schema 1 :version "1" :name "Java" :summary "Java language support"
 :files (:extensions ("java"))
 :grammars ((:name java :repo "https://github.com/tree-sitter/tree-sitter-java" :commit "94703d5a6bed02b98e438d7cad1136c01a60ba2c"
             :tree-sha256 "af9bb8450fab7dca452aa209ada54b3638fc23c3e4c10d10490895c1ad35144b" :src "src" :required t))
 :mode (:ts java-ts-mode :builtin t :classic java-mode)
 :format (:formatter google-java-format :command ("google-java-format" "-") :config-files (".google-java-format"))
 :hrafn (:lang "java" :chunks "queries/chunks.scm" :docs (:line "//" :block "/**" :members (block)))
 :inline (:functions ("method_declaration" "constructor_declaration" "lambda_expression")
          :loops ("enhanced_for_statement" "for_statement" "while_statement" "do_statement")
          :names ("identifier"))
 :origin (:decls ("$TY {t} = $V;"))
 :adapters ((:id "java" :name "Java (jdtls + java-debug)" :types ("java") :languages ("java") :tested t
   :find (:tools "java-debug/plugin.jar")
   :start (:lsp-command
           (:server ("{tools}/jdk/bin/java" "-Declipse.application=org.eclipse.jdt.ls.core.id1" "-Dosgi.bundles.defaultStartLevel=4"
                     "-Declipse.product=org.eclipse.jdt.ls.core.product" "-Xmx1G" "--add-modules=ALL-SYSTEM"
                     "--add-opens" "java.base/java.util=ALL-UNNAMED" "--add-opens" "java.base/java.lang=ALL-UNNAMED"
                     "-jar" "{glob:jdtls/plugins/org.eclipse.equinox.launcher_*.jar}"
                     "-configuration" "{tools}/jdtls/config_{os}{arch-suffix}" "-data" "{session}/workspace")
            :init-options (:bundles ("{tools}/java-debug/plugin.jar"))
            :debug-command "vscode.java.startDebugSession"
            :fill ((:command "vscode.java.resolveMainClass" :args ("{root-uri}")
                    :select (:field "filePath" :equals "${file}") :when-missing "mainClass"
                    :into ((:key "mainClass" :field "mainClass") (:key "projectName" :field "projectName")))
                   (:command "vscode.java.resolveMainClass" :args ("{root-uri}")
                    :select (:field "mainClass" :equals "${config:mainClass}") :when-missing "projectName"
                    :into ((:key "projectName" :field "projectName")))
                   (:command "vscode.java.resolveClasspath" :args ("${config:mainClass}" "${config:projectName}")
                    :into ((:key "modulePaths" :index 0) (:key "classPaths" :index 1)))
                   (:command "vscode.java.resolveJavaExecutable" :args ("${config:mainClass}" "${config:projectName}")
                    :into ((:key "javaExec"))))))
   :defaults ((:name "Java: Current File" :type "java" :request "launch" :cwd "${workspaceFolder}"
               :console "internalConsole"))
   :install (:parts ((:into "jdk" :version "21.0.13+9" :root "jdk-21.0.13+9"
                      :platforms ((:platform "linux-x64"
                                   :url "https://github.com/adoptium/temurin21-binaries/releases/download/jdk-21.0.13%2B9/OpenJDK21U-jdk_x64_linux_hotspot_21.0.13_9.tar.gz"
                                   :sha256 "d7f5d5cf865a2902b70ff549b97586a7d3f234e016f041ab447ea740c7d66d1c")
                                  (:platform "linux-arm64"
                                   :url "https://github.com/adoptium/temurin21-binaries/releases/download/jdk-21.0.13%2B9/OpenJDK21U-jdk_aarch64_linux_hotspot_21.0.13_9.tar.gz"
                                   :sha256 "e3522e707fc7dbe2a72c30746b1e7068301a0213ecd213d4491f35a14eb55578")
                                  (:platform "darwin-x64" :root "jdk-21.0.13+9/Contents/Home"
                                   :url "https://github.com/adoptium/temurin21-binaries/releases/download/jdk-21.0.13%2B9/OpenJDK21U-jdk_x64_mac_hotspot_21.0.13_9.tar.gz"
                                   :sha256 "9aa1d1c17ae5467a022679e7e0af5c00797d94ac462ed1a46f4db07a8a34a6dd")
                                  (:platform "darwin-arm64" :root "jdk-21.0.13+9/Contents/Home"
                                   :url "https://github.com/adoptium/temurin21-binaries/releases/download/jdk-21.0.13%2B9/OpenJDK21U-jdk_aarch64_mac_hotspot_21.0.13_9.tar.gz"
                                   :sha256 "bf036b35b071bfb2f54f2c0af8ee8d88afa95ee6eb3dce02c0f94cfc2524d04a")))
                     (:into "jdtls" :version "1.63.0"
                      :url "https://download.eclipse.org/jdtls/milestones/1.63.0/jdt-language-server-1.63.0-202610191322.tar.gz"
                      :sha256 "b1f2abe0b3cccb462cf64fb4a5587c7d09df60cf8be7748b152cbd89d018bdc4")
                     (:into "java-debug" :version "0.53.1" :file "plugin.jar"
                      :url "https://repo1.maven.org/maven2/com/microsoft/java/com.microsoft.java.debug.plugin/0.53.1/com.microsoft.java.debug.plugin-0.53.1.jar"
                      :sha256 "4f4778d452a6a0665536f43ce4e32403a24be6593336b80dc85a322912859e24")))))
 :license "GPL-3.0-or-later" :maintainers ("drgnx"))
