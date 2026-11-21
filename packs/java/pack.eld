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
            :open-file (:language-id "java")
            :debug-command "vscode.java.startDebugSession"
            :fill ((:command "vscode.java.resolveMainClass" :args ("{root-uri}") :retry-empty 120
                    :select (:field "filePath" :equals "${file}") :when-missing "mainClass"
                    :into ((:key "mainClass" :field "mainClass") (:key "projectName" :field "projectName" :optional t)))
                   (:command "vscode.java.resolveMainClass" :args ("{root-uri}")
                    :select (:field "mainClass" :equals "${config:mainClass}") :when-missing "projectName"
                    :into ((:key "projectName" :field "projectName" :optional t)))
                   (:command "vscode.java.resolveClasspath" :args ("${config:mainClass}" "${config:projectName?}")
                    :into ((:key "modulePaths" :index 0) (:key "classPaths" :index 1)))
                   (:command "vscode.java.resolveJavaExecutable" :args ("${config:mainClass}" "${config:projectName?}")
                    :into ((:key "javaExec"))))))
   :defaults ((:name "Java: Current File" :type "java" :request "launch" :cwd "${workspaceFolder}"
               :console "internalConsole"))
   :install (:parts ((:into "jdk" :version "25.0.5+8" :root "jdk-25.0.5+8"
                      :platforms ((:platform "linux-x64"
                                   :url "https://github.com/adoptium/temurin25-binaries/releases/download/jdk-25.0.5%2B8/OpenJDK25U-jdk_x64_linux_hotspot_25.0.5_8.tar.gz"
                                   :sha256 "68982529869257d0ee6b824ec5aa270ff8b118bb438670da0b97ebdab178d7fb")
                                  (:platform "linux-arm64"
                                   :url "https://github.com/adoptium/temurin25-binaries/releases/download/jdk-25.0.5%2B8/OpenJDK25U-jdk_aarch64_linux_hotspot_25.0.5_8.tar.gz"
                                   :sha256 "bb5b2ded252f21c6090cf780b0a408ad0d83bbb557e702955643557f13231880")
                                  (:platform "darwin-x64" :root "jdk-25.0.5+8/Contents/Home"
                                   :url "https://github.com/adoptium/temurin25-binaries/releases/download/jdk-25.0.5%2B8/OpenJDK25U-jdk_x64_mac_hotspot_25.0.5_8.tar.gz"
                                   :sha256 "32cd4d2151c91aa00d0fc911edfd05245ed40fa6b1aa894d5f35c928cd67a59d")
                                  (:platform "darwin-arm64" :root "jdk-25.0.5+8/Contents/Home"
                                   :url "https://github.com/adoptium/temurin25-binaries/releases/download/jdk-25.0.5%2B8/OpenJDK25U-jdk_aarch64_mac_hotspot_25.0.5_8.tar.gz"
                                   :sha256 "36dc14d797aaff6d89aab302cd053fdba6207dfdcf772052fa7b023a94b0e857")))
                     (:into "jdtls" :version "1.63.0"
                      :url "https://download.eclipse.org/jdtls/milestones/1.63.0/jdt-language-server-1.63.0-202610191322.tar.gz"
                      :sha256 "b1f2abe0b3cccb462cf64fb4a5587c7d09df60cf8be7748b152cbd89d018bdc4")
                     (:into "java-debug" :version "0.53.1" :file "plugin.jar"
                      :url "https://repo1.maven.org/maven2/com/microsoft/java/com.microsoft.java.debug.plugin/0.53.1/com.microsoft.java.debug.plugin-0.53.1.jar"
                      :sha256 "4f4778d452a6a0665536f43ce4e32403a24be6593336b80dc85a322912859e24")))))
 :license "GPL-3.0-or-later" :maintainers ("drgnx"))
