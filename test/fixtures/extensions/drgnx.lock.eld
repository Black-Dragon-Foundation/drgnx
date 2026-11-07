;; drgnx package lock (test fixture) — written by drgnx sync
(:version 1 :packages
	  ((magit :version "4.1" :archive "melpa" :kind tar :file "magit-4.1.tar" :sha256 "aa" :size 10
		  :requires ((with-editor "3.0") (dash "2.19")) :summary "A Git porcelain inside Emacs" :wanted user)
	   (with-editor :version "3.4.1" :archive "gnu" :kind tar :file "with-editor-3.4.1.tar" :sha256 "bb" :size 10
			:requires ((dash "2.19")) :summary "Use the Emacs you started from" :verified t)
	   (dash :version "2.19.1" :archive "gnu" :kind tar :file "dash-2.19.1.tar" :sha256 "cc" :size 10
		 :requires nil :summary "A modern list API for Emacs")
	   (newer-emacs-only :version "8.0" :archive "gnu" :kind tar :file "n-8.0.tar" :sha256 "dd" :size 10
			     :requires nil :wanted user)
	   (in-a-directory :version "1.0" :archive "local" :kind tar :file "d-1.0.tar" :sha256 "ee" :size 10
			   :requires nil :wanted user)
	   (handmade :version "1.0" :kind tar :requires nil :summary "Put here by hand")
	   (from-a-repo :kind git :url "https://example.invalid/r.git" :rev "main" :commit "abcdef0"
			:requires nil :summary "From its repository")))
