;; drgnx's known-good package lock — a first drgnx sync installs these; maintainers: drgnx lock --ship
(:version 1 :packages
	  ((ace-window :version "0.10.0" :archive "gnu" :kind tar
		       :file "ace-window-0.10.0.tar" :sha256
		       "64b7f5abebbd2762f147b301f2e7f20bb521cb0e5819d717c65d8df86098bfe9"
		       :size 61440 :requires ((avy "0.5.0")) :summary
		       "Quickly switch windows.")
	   (apheleia :version "20260915.1628" :archive "melpa" :kind
		     tar :file "apheleia-20260915.1628.tar" :sha256
		     "4f3a23920197753aa9c42ce45f61ea2b9302d4908f7d83a97fa2b9a40f6660a3"
		     :size 430080 :requires nil :summary
		     "Reformat buffer stably")
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
		   :summary "Store EIEIO objects using EmacSQL")
	   (compat :version "31.1.0.0" :archive "gnu" :kind tar :file
		   "compat-31.1.0.0.tar" :sha256
		   "d0b21a401990575b0fed84f5e692440c3e16aaa8e679172e38ee131b88ecff9c"
		   :size 409600 :requires nil :summary
		   "Emacs Lisp Compatibility Library")
	   (cond-let :version "1.1.5" :archive "nongnu" :kind tar
		     :file "cond-let-1.1.5.tar" :sha256
		     "cb12ebffaab37fc12d60a3d749d304f67012a6580750f260b013b124bfb592e6"
		     :size 40960 :requires nil :summary
		     "Additional and improved binding conditionals")
	   (corfu :version "2.16" :archive "gnu" :kind tar :file
		  "corfu-2.16.tar" :sha256
		  "3ee5a608ca1001e5e6d723df7d2577b162ae3271e9649ccc5e650f585bf785c4"
		  :size 245760 :requires ((compat "31")) :summary
		  "COmpletion in Region FUnction")
	   (dape :version "0.27.1" :archive "gnu" :kind tar :file
		 "dape-0.27.1.tar" :sha256
		 "67d5f1d4f5ad5abc66a65582f5ce2c5125f864ea5256afb423fc79f5000243d9"
		 :size 358400 :requires ((jsonrpc "1.0.25")) :summary
		 "Debug Adapter Protocol for Emacs")
	   (diff-hl :version "1.11.2" :archive "gnu" :kind tar :file
		    "diff-hl-1.11.2.tar" :sha256
		    "87dfec1f904595045d3dd215525f50445264e5d94e6591e2b9cc044ce74a91b1"
		    :size 215040 :requires ((cl-lib "0.2")) :summary
		    "Highlight uncommitted changes using VC")
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
		    "High-level SQL database front-end")
	   (forge :version "20261006.1249" :archive "melpa" :kind tar
		  :file "forge-20261006.1249.tar" :sha256
		  "6238ba6c067a0be2656ba7aabb582a8d830d9fa2e4de0b041d501e6a23c99c55"
		  :size 563200 :requires
		  ((compat "31.0") (closql "2.4") (cond-let "1.1")
		   (emacsql "4.4") (ghub "5.3") (llama "1.0")
		   (magit "4.7") (markdown-mode "2.8")
		   (transient "0.13") (yaml "1.2"))
		  :summary "Access Git forges from Magit")
	   (ghub :version "20261001.1601" :archive "melpa" :kind tar
		 :file "ghub-20261001.1601.tar" :sha256
		 "cfc95ad3925ef89626996760f667c4691b38ba74881847d519e8a1005ceae425"
		 :size 122880 :requires
		 ((compat "31.1") (cond-let "1.1") (llama "1.0")
		  (treepy "0.1.3"))
		 :summary "Client libraries for Git forge APIs")
	   (gptel :version "0.9.9.6" :archive "nongnu" :kind tar :file
		  "gptel-0.9.9.6.tar" :sha256
		  "0aa684b3e273ef6788756cffa4d018fe0bed0ecc853640fb82abaacd9d7ca5dd"
		  :size 1003520 :requires
		  ((transient "0.7.8") (compat "30.1.0.0")) :summary
		  "Interact with ChatGPT or other LLMs")
	   (indent-bars :version "1.0.1" :archive "gnu" :kind tar
			:file "indent-bars-1.0.1.tar" :sha256
			"49b75d50585a93d7c49e0e064649c6cf8f296412e1717350490d2af0b4e685b5"
			:size 174080 :requires ((compat "30"))
			:summary "Highlight indentation with bars")
	   (keycast :version "1.4.8" :archive "nongnu" :kind tar :file
		    "keycast-1.4.8.tar" :sha256
		    "20fdaa11b47000de010cf35f8b6d22dfdc07122261496451220ad9d304c3ea65"
		    :size 40960 :requires
		    ((compat "31.0") (cond-let "1.1")) :summary
		    "Show current command and its binding")
	   (llama :version "1.0.6" :archive "nongnu" :kind tar :file
		  "llama-1.0.6.tar" :sha256
		  "eafea6f32985ebf2c0266cdeff3a7b72eaf674c7a51e1c424fbc0e4166310337"
		  :size 40960 :requires ((compat "31.1")) :summary
		  "Compact syntax for short lambda")
	   (magit :version "4.7.1" :archive "nongnu" :kind tar :file
		  "magit-4.7.1.tar" :sha256
		  "b2d38a34aeddea92cc87b4cb9823dcd597993f800633c760587dba083acff2e5"
		  :size 2099200 :requires
		  ((compat "31.0") (cond-let "1.1") (llama "1.0")
		   (magit-section "4.7") (seq "2.24")
		   (transient "0.13") (with-editor "3.5"))
		  :summary "A Git porcelain inside Emacs")
	   (magit-section :version "4.7.1" :archive "nongnu" :kind tar
			  :file "magit-section-4.7.1.tar" :sha256
			  "65427cfa50393325fcc5876da0bf1fa95ea170b71046e5523a19a2255f6458bf"
			  :size 143360 :requires
			  ((compat "31.0") (cond-let "1.1")
			   (llama "1.0") (seq "2.24"))
			  :summary "Sections for read-only buffers")
	   (marginalia :version "2.13" :archive "gnu" :kind tar :file
		       "marginalia-2.13.tar" :sha256
		       "e1b228d1d4aa4648982aa79ebb9a2e1d2824b7cd40e01d39ed541f1b7663edba"
		       :size 122880 :requires ((compat "31")) :summary
		       "Enrich existing commands with completion annotations")
	   (markdown-mode :version "2.8" :archive "nongnu" :kind tar
			  :file "markdown-mode-2.8.tar" :sha256
			  "c265ee2c6b230f5b65d208e596c728ccb62d4c0e9e9ad568104d51ee8bd7c8a0"
			  :size 675840 :requires nil :summary
			  "Major mode for Markdown-formatted text")
	   (multiple-cursors :version "1.5.0" :archive "nongnu" :kind
			     tar :file "multiple-cursors-1.5.0.tar"
			     :sha256
			     "7d7d782b8a3a9b254db91e24f54bae6b089964ba595aa97250bc9e529555db16"
			     :size 133120 :requires ((cl-lib "0.5"))
			     :summary "Multiple cursors for emacs.")
	   (orderless :version "1.8" :archive "gnu" :kind tar :file
		      "orderless-1.8.tar" :sha256
		      "9b4b1253bab2e1d984ad0a31028716d0eff2cd358144bb9caced3b15088e69aa"
		      :size 194560 :requires ((compat "31")) :summary
		      "Completion style for matching regexps in any order")
	   (transient :version "0.13.8" :archive "gnu" :kind tar :file
		      "transient-0.13.8.tar" :sha256
		      "0fa2ee5ce7ce2fd35acd9cf86e9b2d1abec99973db8378b386b5f90b1fa1bebd"
		      :size 645120 :requires
		      ((compat "31.0") (cond-let "1.1") (llama "1.0")
		       (seq "2.24"))
		      :summary "Transient commands")
	   (treepy :version "0.1.3" :archive "nongnu" :kind tar :file
		   "treepy-0.1.3.tar" :sha256
		   "1fcce921b398f73ba28e880dda7feb993d35de7a2ead0b649e76740bf1c6bc1f"
		   :size 71680 :requires nil :summary
		   "Generic tree traversal tools")
	   (vertico :version "2.15" :archive "gnu" :kind tar :file
		    "vertico-2.15.tar" :sha256
		    "5c3492edb1e0020da711d9a4213a3878e90e7af8e2e6375757901f4b399872ff"
		    :size 266240 :requires ((compat "31")) :summary
		    "VERTical Interactive COmpletion")
	   (vundo :version "2.4.0" :archive "gnu" :kind tar :file
		  "vundo-2.4.0.tar" :sha256
		  "59eab71cedb9424277144bb862b967a7db0f25e248e69d07ac66bf1da3a142aa"
		  :size 92160 :requires nil :summary
		  "Visual undo tree")
	   (websocket :version "1.16" :archive "gnu" :kind tar :file
		      "websocket-1.16.tar" :sha256
		      "b11ff735b0ac1d94d0024c63371e192c5e36c6f3619cf78ea08eaa4f963cc32a"
		      :size 122880 :requires ((cl-lib "0.5")) :summary
		      "Emacs WebSocket client and server")
	   (wgrep :version "3.0.0" :archive "nongnu" :kind tar :file
		  "wgrep-3.0.0.tar" :sha256
		  "ff73b18324a80176d050344a764f8a176ff2d52fb00e3475f1b5c9dc8d2749a2"
		  :size 122880 :requires nil :summary
		  "Writable grep buffer and apply the changes to files")
	   (with-editor :version "3.5.4" :archive "nongnu" :kind tar
			:file "with-editor-3.5.4.tar" :sha256
			"6dd3156efcec9be9ee2e47881c26aceb35858508c203341cc6d10f51b1637f26"
			:size 102400 :requires
			((compat "31.0") (cond-let "1.1")
			 (llama "1.0"))
			:summary "Use the Emacsclient as $EDITOR")
	   (yaml :version "1.2.4" :archive "gnu" :kind tar :file
		 "yaml-1.2.4.tar" :sha256
		 "9e6260055013feb84a8a9077e7f510f39e2aaedd57f9310bd33154090132518a"
		 :size 215040 :requires nil :summary
		 "YAML parser for Elisp")))
