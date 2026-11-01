;; The child-frame packages the compositor tests and the popup workloads run against (docs/develop/harness.md,
;; "Child-frame packages").  (NAME VERSION :archive ARCHIVE :sha256 SHA256-OF-THE-ARCHIVE-FILE), pinned on 2026-10-21;
;; `drgnx childframe-elpa DIR' installs exactly these, and the GUI test image bakes them (test/container/childframe-elpa.sh)
;; at /opt/childframe-elpa.  The archives keep only their newest build, so bumping a pin is a deliberate edit (version
;; and hash) that rebuilds the image; the image already built keeps working.
((posframe "1.5.4" :archive "gnu"
           :sha256 "9faf005afe58c0f32e3a36fa26eb1611b5a4b1cf93a47d5ee5f65f0b50958b30")
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
             :sha256 "0d977fe1438b421a1c4b26ef2d39d23c9ef89db94b97bc0744969b90d293b98d")
 ;; what those need, pinned too: the image bakes exactly this list (test/container/Containerfile.gui)
 (company "1.1.0" :archive "gnu"
          :sha256 "2c492f7219dde601c8826496169df22983f49defeb4cc528584cf3e2134c134f")
 (dash "2.20.0" :archive "gnu"
       :sha256 "28f84b0905f84520163f5dd2087e47cac042bd27b7ec34eeb293f1ada7d36cb2")
 (vertico "2.15" :archive "gnu"
          :sha256 "5c3492edb1e0020da711d9a4213a3878e90e7af8e2e6375757901f4b399872ff")
 (frame-local "20180330.940" :archive "melpa"
              :sha256 "7bd934b88490bb87fc197f54949f3daa73f63f47a4c7dc31052d9e8db028e8ee"))
