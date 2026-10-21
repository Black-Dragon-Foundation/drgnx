;; drgnx's known-good package lock — a first drgnx sync installs these; maintainers: drgnx lock --ship
(:version 1 :packages
	  ((ace-window :version "0.10.0" :archive "gnu" :kind tar
		       :file "ace-window-0.10.0.tar" :sha256
		       "64b7f5abebbd2762f147b301f2e7f20bb521cb0e5819d717c65d8df86098bfe9"
		       :size 61440 :requires ((avy "0.5.0")) :summary
		       "Quickly switch windows." :commit
		       "7003c88cd9cad58dc35c7cd13ebc61c355fb5be7" :url
		       "https://github.com/abo-abo/ace-window")
	   (apheleia :version "20261017.2152" :archive "melpa" :kind
		     tar :file "apheleia-20261017.2152.tar" :sha256
		     "fda7b9f3091725dc83314e5e2b798707306fc71b2dfbd2cdd507c4a141b0c4f5"
		     :size 430080 :requires nil :summary
		     "Reformat buffer stably" :commit
		     "21e42e64247452d1586294072b0062d60b3b0de2" :url
		     "https://github.com/radian-software/apheleia")
	   (avy :version "0.5.0" :archive "gnu" :kind tar :file
		"avy-0.5.0.tar" :sha256
		"0da035b910ef4a6a9abcc9ef3121b77fb5a3c5de99c399416b3c578c06adccf5"
		:size 122880 :requires ((cl-lib "0.5")) :summary
		"Jump to arbitrary positions in visible text and select text quickly.")
	   (closql :version "20261001.1545" :archive "melpa" :kind tar
		   :file "closql-20261001.1545.tar" :sha256
		   "b565a183c4970e1aa92f93bd379150467776748f6b1f6900842652b9595f15c1"
		   :size 30720 :requires
		   ((compat "31.1") (cond-let "1.1") (emacsql "4.4")
		    (llama "1.0"))
		   :summary "Store EIEIO objects using EmacSQL"
		   :commit "48955ae02cfc7dad93b6bdc9ffd8d4b760dfb62b"
		   :url "https://github.com/emacscollective/closql")
	   (cond-let :version "1.1.5" :archive "nongnu" :kind tar
		     :file "cond-let-1.1.5.tar" :sha256
		     "cb12ebffaab37fc12d60a3d749d304f67012a6580750f260b013b124bfb592e6"
		     :size 40960 :requires nil :summary
		     "Additional and improved binding conditionals"
		     :commit
		     "09292a77001434f59ab55c775dec2b98cb18d028" :url
		     "https://github.com/tarsius/cond-let")
	   (corfu :version "2.16" :archive "gnu" :kind tar :file
		  "corfu-2.16.tar" :sha256
		  "3ee5a608ca1001e5e6d723df7d2577b162ae3271e9649ccc5e650f585bf785c4"
		  :size 245760 :requires ((compat "31")) :summary
		  "COmpletion in Region FUnction" :commit
		  "b468efac023dda39332acc943edc9895c80b5a6f" :url
		  "https://github.com/minad/corfu")
	   (dape :version "0.27.1" :archive "gnu" :kind tar :file
		 "dape-0.27.1.tar" :sha256
		 "67d5f1d4f5ad5abc66a65582f5ce2c5125f864ea5256afb423fc79f5000243d9"
		 :size 358400 :requires ((jsonrpc "1.0.25")) :summary
		 "Debug Adapter Protocol for Emacs" :commit
		 "dcbdffc68a3c89bbb89956161edde9f0fe062e64" :url
		 "https://github.com/svaante/dape")
	   (diff-hl :version "1.11.2" :archive "gnu" :kind tar :file
		    "diff-hl-1.11.2.tar" :sha256
		    "87dfec1f904595045d3dd215525f50445264e5d94e6591e2b9cc044ce74a91b1"
		    :size 215040 :requires ((cl-lib "0.2")) :summary
		    "Highlight uncommitted changes using VC" :commit
		    "5e467e66847069d29922efb1a91a25a78dbad3d5" :url
		    "https://github.com/dgutov/diff-hl")
	   (eat :version "0.9.4" :archive "nongnu" :kind tar :file
		"eat-0.9.4.tar" :sha256
		"14971fc562f0820794eb6af78beebc7dc3ba898221e785c2d272a9f0fccfc54a"
		:size 778240 :requires ((compat "29.1")) :summary
		"Emulate A Terminal, in a region, in a buffer and in Eshell"
		:commit "c91451f2d17453c19d3fa76faa4945cbe54e14ce"
		:url "https://codeberg.org/akib/emacs-eat")
	   (eglot-booster :kind git :url
			  "https://github.com/jdtsmith/eglot-booster"
			  :rev "main" :commit
			  "510f579409627c333ef0e9157db713b1004da842"
			  :version "0.1.0" :requires
			  ((jsonrpc "1.0") (eglot "1.0") (seq "2.24"))
			  :summary "Boost eglot using lsp-booster")
	   (emacsql :version "4.4.2" :archive "nongnu" :kind tar :file
		    "emacsql-4.4.2.tar" :sha256
		    "36f061fd9718e29a97ab8f85a94677fb2258e7ed6fcbbf661e087947561edc40"
		    :size 143360 :requires nil :summary
		    "High-level SQL database front-end" :commit
		    "7a4c607912c8fdd1fca4def4915d68f43b12d4da" :url
		    "https://github.com/magit/emacsql")
	   (evil :version "20260728.1438" :archive "melpa" :kind tar
		 :file "evil-20260728.1438.tar" :sha256
		 "9c81c4ce6b0efa336728e7eeb2408da30678fe22679af643d53acc7a11db6e91"
		 :size 931840 :requires
		 ((cl-lib "0.5") (goto-chg "1.6") (nadvice "0.3"))
		 :summary "Extensible vi layer" :commit
		 "6a3e1ddd04ac504a016590940d0af2a3361b9efd" :url
		 "https://github.com/emacs-evil/evil")
	   (evil-collection :version "20261014.225" :archive "melpa"
			    :kind tar :file
			    "evil-collection-20261014.225.tar" :sha256
			    "fab3c297864dfdefc83d804753366550bfd34e65f987271d9aa707acd84e1bca"
			    :size 1638400 :requires ((evil "1.2.13"))
			    :summary
			    "A set of keybindings for Evil mode"
			    :commit
			    "3948a7890960d389dffa637203a6760df68b1c1c"
			    :url
			    "https://github.com/emacs-evil/evil-collection")
	   (forge :version "20261020.1944" :archive "melpa" :kind tar
		  :file "forge-20261020.1944.tar" :sha256
		  "bb4b6a3d9f1c8953a3ba2184c1c7e0ed757f14580e7b24b301b1c2aecd0c4df2"
		  :size 563200 :requires
		  ((compat "31.0") (closql "2.4") (cond-let "1.1")
		   (emacsql "4.4") (ghub "5.3") (llama "1.0")
		   (magit "4.7") (markdown-mode "2.8")
		   (transient "0.13") (yaml "1.2"))
		  :summary "Access Git forges from Magit" :commit
		  "79582e7fc5f0d56324e722bac3ba14c4dff70523" :url
		  "https://github.com/magit/forge")
	   (ghub :version "20261001.1601" :archive "melpa" :kind tar
		 :file "ghub-20261001.1601.tar" :sha256
		 "cfc95ad3925ef89626996760f667c4691b38ba74881847d519e8a1005ceae425"
		 :size 122880 :requires
		 ((compat "31.1") (cond-let "1.1") (llama "1.0")
		  (treepy "0.1.3"))
		 :summary "Client libraries for Git forge APIs"
		 :commit "01e2bc064ab4965d332efa11fafeda2a43f338d1"
		 :url "https://github.com/magit/ghub")
	   (goto-chg :version "20240407.1110" :archive "melpa" :kind
		     tar :file "goto-chg-20240407.1110.tar" :sha256
		     "e140e45a795cf4706cd500ecc120f6cca8f170b614fd8ba52d0e275009a83034"
		     :size 20480 :requires nil :summary
		     "Go to last change" :commit
		     "72f556524b88e9d30dc7fc5b0dc32078c166fda7" :url
		     "https://github.com/emacs-evil/goto-chg")
	   (gptel :version "0.9.9.6" :archive "nongnu" :kind tar :file
		  "gptel-0.9.9.6.tar" :sha256
		  "0aa684b3e273ef6788756cffa4d018fe0bed0ecc853640fb82abaacd9d7ca5dd"
		  :size 1003520 :requires
		  ((transient "0.7.8") (compat "30.1.0.0")) :summary
		  "Interact with ChatGPT or other LLMs" :commit
		  "2b02618b2eba819b996eca7f71bf4dd4b91eb532" :url
		  "https://github.com/karthink/gptel")
	   (indent-bars :version "1.0.1" :archive "gnu" :kind tar
			:file "indent-bars-1.0.1.tar" :sha256
			"49b75d50585a93d7c49e0e064649c6cf8f296412e1717350490d2af0b4e685b5"
			:size 174080 :requires ((compat "30"))
			:summary "Highlight indentation with bars"
			:commit
			"36620c5f3fba2ba8f23d7ef947e0d1d09e412bf5"
			:url "https://github.com/jdtsmith/indent-bars")
	   (keycast :version "1.4.8" :archive "nongnu" :kind tar :file
		    "keycast-1.4.8.tar" :sha256
		    "20fdaa11b47000de010cf35f8b6d22dfdc07122261496451220ad9d304c3ea65"
		    :size 40960 :requires
		    ((compat "31.0") (cond-let "1.1")) :summary
		    "Show current command and its binding" :commit
		    "a6518e1b48b08ba883e9b1a2db0872d5bf3d85f4" :url
		    "https://github.com/tarsius/keycast")
	   (kkp :version "20260706.858" :archive "melpa" :kind tar
		:file "kkp-20260706.858.tar" :sha256
		"1ef566f8cc68cc0bf8cb3ee4aaffa63b258be8621a89229d2d3b2df4b945c8e5"
		:size 71680 :requires ((compat "29.1.3.4")) :summary
		"Enable support for the Kitty Keyboard Protocol"
		:commit "82b7443e10a2ba287467b62e90b6adb6dd93dc99"
		:url "https://github.com/benotn/kkp")
	   (llama :version "1.0.6" :archive "nongnu" :kind tar :file
		  "llama-1.0.6.tar" :sha256
		  "eafea6f32985ebf2c0266cdeff3a7b72eaf674c7a51e1c424fbc0e4166310337"
		  :size 40960 :requires ((compat "31.1")) :summary
		  "Compact syntax for short lambda" :commit
		  "6850d0c91b629da14fdff2300c222289d1a0029a" :url
		  "https://github.com/tarsius/llama")
	   (magit :version "4.7.1" :archive "nongnu" :kind tar :file
		  "magit-4.7.1.tar" :sha256
		  "b2d38a34aeddea92cc87b4cb9823dcd597993f800633c760587dba083acff2e5"
		  :size 2099200 :requires
		  ((compat "31.0") (cond-let "1.1") (llama "1.0")
		   (magit-section "4.7") (seq "2.24")
		   (transient "0.13") (with-editor "3.5"))
		  :summary "A Git porcelain inside Emacs" :commit
		  "659f89955cf60fe3d4326d881c412df06c69680d" :url
		  "https://github.com/magit/magit")
	   (magit-section :version "4.7.1" :archive "nongnu" :kind tar
			  :file "magit-section-4.7.1.tar" :sha256
			  "65427cfa50393325fcc5876da0bf1fa95ea170b71046e5523a19a2255f6458bf"
			  :size 143360 :requires
			  ((compat "31.0") (cond-let "1.1")
			   (llama "1.0") (seq "2.24"))
			  :summary "Sections for read-only buffers"
			  :commit
			  "659f89955cf60fe3d4326d881c412df06c69680d"
			  :url "https://github.com/magit/magit")
	   (marginalia :version "2.13" :archive "gnu" :kind tar :file
		       "marginalia-2.13.tar" :sha256
		       "e1b228d1d4aa4648982aa79ebb9a2e1d2824b7cd40e01d39ed541f1b7663edba"
		       :size 122880 :requires ((compat "31")) :summary
		       "Enrich existing commands with completion annotations"
		       :commit
		       "42eafcfddbe88d92ed96521a00a5a90a49bac4dd" :url
		       "https://github.com/minad/marginalia")
	   (markdown-mode :version "2.8" :archive "nongnu" :kind tar
			  :file "markdown-mode-2.8.tar" :sha256
			  "c265ee2c6b230f5b65d208e596c728ccb62d4c0e9e9ad568104d51ee8bd7c8a0"
			  :size 675840 :requires nil :summary
			  "Major mode for Markdown-formatted text"
			  :commit
			  "f5d520b3ee7722dd2231ab586ba51d8eb166e49b"
			  :url
			  "https://jblevins.org/projects/markdown-mode/")
	   (multiple-cursors :version "1.5.0" :archive "nongnu" :kind
			     tar :file "multiple-cursors-1.5.0.tar"
			     :sha256
			     "7d7d782b8a3a9b254db91e24f54bae6b089964ba595aa97250bc9e529555db16"
			     :size 133120 :requires ((cl-lib "0.5"))
			     :summary "Multiple cursors for emacs."
			     :commit
			     "89f1a8df9b1fc721b1672b4c7b6d3ab451e7e3ef"
			     :url
			     "https://github.com/magnars/multiple-cursors.el")
	   (orderless :version "1.8" :archive "gnu" :kind tar :file
		      "orderless-1.8.tar" :sha256
		      "9b4b1253bab2e1d984ad0a31028716d0eff2cd358144bb9caced3b15088e69aa"
		      :size 194560 :requires ((compat "31")) :summary
		      "Completion style for matching regexps in any order"
		      :commit
		      "3d2c2e6468ddf51e69c78e8212e5fd9006d2ce8a" :url
		      "https://github.com/oantolin/orderless")
	   (treepy :version "0.1.3" :archive "nongnu" :kind tar :file
		   "treepy-0.1.3.tar" :sha256
		   "1fcce921b398f73ba28e880dda7feb993d35de7a2ead0b649e76740bf1c6bc1f"
		   :size 71680 :requires nil :summary
		   "Generic tree traversal tools" :commit
		   "28f0e2c2c75ea186e8beb570a4a70087926ff80b" :url
		   "https://github.com/volrath/treepy.el")
	   (vertico :version "2.15" :archive "gnu" :kind tar :file
		    "vertico-2.15.tar" :sha256
		    "5c3492edb1e0020da711d9a4213a3878e90e7af8e2e6375757901f4b399872ff"
		    :size 266240 :requires ((compat "31")) :summary
		    "VERTical Interactive COmpletion" :commit
		    "a9998a777f1d92348f84d091bb15b87df933a7a2" :url
		    "https://github.com/minad/vertico")
	   (vlf :version "1.7.2" :archive "gnu" :kind tar :file
		"vlf-1.7.2.tar" :sha256
		"7be29cef561199a58c12b522d62336d3d50ab3016a9228702b8b67bd55eb57d9"
		:size 153600 :requires nil :summary "View Large Files"
		:commit "efffeb5f54191d41a503d1d51343bb327fe2f871"
		:url "https://github.com/m00natic/vlfi")
	   (vundo :version "2.4.0" :archive "gnu" :kind tar :file
		  "vundo-2.4.0.tar" :sha256
		  "59eab71cedb9424277144bb862b967a7db0f25e248e69d07ac66bf1da3a142aa"
		  :size 92160 :requires nil :summary
		  "Visual undo tree" :commit
		  "b89f719824fe5da0f6a7590fad3ece798fd59909" :url
		  "https://github.com/casouri/vundo")
	   (websocket :version "1.16" :archive "gnu" :kind tar :file
		      "websocket-1.16.tar" :sha256
		      "b11ff735b0ac1d94d0024c63371e192c5e36c6f3619cf78ea08eaa4f963cc32a"
		      :size 122880 :requires ((cl-lib "0.5")) :summary
		      "Emacs WebSocket client and server" :commit
		      "03d1cca4bd910a8df73e4ec637836c6ac25213a2" :url
		      "https://github.com/ahyatt/emacs-websocket")
	   (wgrep :version "3.0.0" :archive "nongnu" :kind tar :file
		  "wgrep-3.0.0.tar" :sha256
		  "ff73b18324a80176d050344a764f8a176ff2d52fb00e3475f1b5c9dc8d2749a2"
		  :size 122880 :requires nil :summary
		  "Writable grep buffer and apply the changes to files"
		  :commit "2d1c0509215499e927817b0d7d3f133db678e010"
		  :url
		  "http://github.com/mhayashi1120/Emacs-wgrep/raw/master/wgrep.el")
	   (with-editor :version "3.5.4" :archive "nongnu" :kind tar
			:file "with-editor-3.5.4.tar" :sha256
			"6dd3156efcec9be9ee2e47881c26aceb35858508c203341cc6d10f51b1637f26"
			:size 102400 :requires
			((compat "31.0") (cond-let "1.1")
			 (llama "1.0"))
			:summary "Use the Emacsclient as $EDITOR"
			:commit
			"5021ef6885381cf5b2852f7a3f67ca8c4be1dca2"
			:url "https://github.com/magit/with-editor")
	   (yaml :version "1.2.4" :archive "gnu" :kind tar :file
		 "yaml-1.2.4.tar" :sha256
		 "9e6260055013feb84a8a9077e7f510f39e2aaedd57f9310bd33154090132518a"
		 :size 215040 :requires nil :summary
		 "YAML parser for Elisp" :commit
		 "5546f36bde24a9a8c1934e0f6ce205cd41d72537" :url
		 "https://github.com/zkry/yaml.el")))
