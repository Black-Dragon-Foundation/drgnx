;; The child-frame packages the compositor tests and the popup workloads run against (docs/develop/harness.md,
;; "Child-frame packages").  (NAME VERSION :repo UPSTREAM-GIT-URL :commit COMMIT :tree TREE-OF-THAT-COMMIT), the
;; commits the ELPA builds named on 2026-11-01.  A commit never moves, so nothing here can go stale; test/container/
;; childframe-elpa.sh fetches each commit at image build time and refuses one whose git tree differs.  VERSION only
;; names the directory.  Bumping a package is a deliberate edit of its line (and the pins' sha256 in Containerfile.gui).
((posframe "1.5.4" :repo "https://github.com/tumashu/posframe"
           :commit "1a6a25c58559ef43821a071c43b23de5cbc3cc3a" :tree "7dd6599d13ddcd7d9cfd8e3ace78519f8b471819")
 (corfu "2.16" :repo "https://github.com/minad/corfu"
        :commit "b468efac023dda39332acc943edc9895c80b5a6f" :tree "852bec07b1fe1ca7b0b459bb4d4a8906e537fbde")
 (eldoc-box "20260903.1246" :repo "https://github.com/casouri/eldoc-box"
            :commit "89900de72dca291d5914ffc5da701b3170704229" :tree "3f08de3ba2743c23a491db4ac558e443051a1b69")
 (company-box "20240320.921" :repo "https://github.com/sebastiencs/company-box"
              :commit "c4f2e243fba03c11e46b1600b124e036f2be7691" :tree "3b58959af3030cb44e98797bff49e4b1fc31c5a1")
 (which-key-posframe "20230313.1841" :repo "https://github.com/emacsorphanage/which-key-posframe"
                     :commit "e4a9ce9a1b20de550fca51f14d055821980d534a" :tree "8eb942c04c225eff378ac47b7c606f71854a7d2d")
 (transient-posframe "20241212.940" :repo "https://github.com/yanghaoxie/transient-posframe"
                     :commit "1eb4ed61ad9f0272a887e05f00708f85f2d9efc5" :tree "5620067cc06a4f2a89d8cb9ca129784c7daa4a58")
 (vertico-posframe "0.9.2" :repo "https://github.com/tumashu/vertico-posframe"
                   :commit "d6e06a4f1b34d24cc0ca6ec69d2d6c965191b23e" :tree "ccbfa50ace11639a1ad422512c5524836b269790")
 (mini-frame "20260619.549" :repo "https://github.com/muffinmad/emacs-mini-frame"
             :commit "066af90bb2c9a52ff0bfbcdb25539e1b92b68586" :tree "5910c31075c1e86021304cb1a782a7639b09ed26")
 ;; what those need, pinned too
 (company "1.1.0" :repo "https://github.com/company-mode/company-mode"
          :commit "1cc907ac9e46ae4209eb5a341131787e0c678406" :tree "318dfd25d1d9b6ad67e71fa359da7fbaa7d21685")
 (dash "2.20.0" :repo "https://github.com/magnars/dash.el"
       :commit "fcb5d831fc08a43f984242c7509870f30983c27c" :tree "e40f544ec340615cbfd846547e0b9a7c8e48e125")
 (vertico "2.15" :repo "https://github.com/minad/vertico"
          :commit "a9998a777f1d92348f84d091bb15b87df933a7a2" :tree "360f4a70b115a360cd4c28e25e27ff8ac40f97c2")
 (frame-local "20180330.940" :repo "https://github.com/sebastiencs/frame-local"
              :commit "51c0889602626e2dcc6f1c1a812b058bc96df03c" :tree "0a206caf3c7052138e7e34bf8706c4c774ed9a98"))
