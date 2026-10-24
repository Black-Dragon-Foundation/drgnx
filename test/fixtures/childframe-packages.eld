;; The child-frame packages the compositor tests and the popup workloads run against (docs/develop/harness.md,
;; "Child-frame packages").  (NAME VERSION :archive ARCHIVE :sha256 SHA256-OF-THE-ARCHIVE-FILE), pinned on 2026-10-21;
;; `drgnx childframe-elpa DIR' installs exactly these.  MELPA serves only its newest build, so a MELPA pin that
;; the archive has moved past fails the install until the pin is bumped here (a hash and a version, nothing else).
((posframe "1.5.3" :archive "gnu"
           :sha256 "74a021fe39a527abcf85cadd18e433c44bc77fc10bc0b79b42c8038d1ee9c02d")
 (corfu "2.16" :archive "gnu"
        :sha256 "3ee5a608ca1001e5e6d723df7d2577b162ae3271e9649ccc5e650f585bf785c4")
 (eldoc-box "20260903.1246" :archive "melpa"
            :sha256 "c965012dfe0629bae8953136d5029fc8dd2392be0b47b65c22b1fd83b01304b2")
 (company-box "20240320.921" :archive "melpa"
              :sha256 "43d562a816d512117194862b9740d7dd637a5b61aa9655f446bd845dfe6441d7")
 (which-key-posframe "20230313.1841" :archive "melpa"
                     :sha256 "5e233cdfa979c2d11a525f2f306b9e27d4245456c5857e2e336c5a3917afdfaf")
 (transient-posframe "20241212.940" :archive "melpa"
                     :sha256 "609f27b6d3a3778065de8301daae8a4f4f1b71169878827aeb8fa1b26c367e93")
 (vertico-posframe "0.9.2" :archive "gnu"
                   :sha256 "446205af06e53dd3b80ba544b68fcb7100f833783d466b1f79614e29a40203f7")
 (mini-frame "20260619.549" :archive "melpa"
             :sha256 "0d977fe1438b421a1c4b26ef2d39d23c9ef89db94b97bc0744969b90d293b98d"))
