;;; view-patch-test.el --- batch tests: hub-built row patches, inserted (wb/drgnx-view.el) -*- lexical-binding: t -*-
;; test-class: det
(require 'ert)
(require 'cl-lib)
(require 'drgnx-paths)
(require 'drgnx-view)
(load (expand-file-name "test/fixtures/orders-fixture" drgnx-dir) nil t)

(defvar drgnx-view-patch-test--sent nil "What the inserter sent the hub, newest first: (METHOD . PARAMS).")

(defmacro drgnx-view-patch-test--with (&rest body)
  "BODY in a fresh buffer `buf' attached as the hub-fed pair (\"v\" . \"c\") at epoch 1, sending captured."
  (declare (indent 0))
  `(let ((drgnx-view-patch--buffers (make-hash-table :test #'equal))
         (drgnx-view-patch--hooked nil)
         (drgnx-view-patch-test--sent nil)
         (drgnx-view-patch-send-function (lambda (m p) (push (cons m p) drgnx-view-patch-test--sent))))
     (with-temp-buffer
       (let* ((buf (current-buffer)) (view (drgnx-view-patch-attach "v" "c" :epoch 1)))
         (ignore buf view)
         (unwind-protect (progn ,@body)
           (drgnx-view-patch-teardown)
           (drgnx-timer-cancel (cons 'drgnx-view buf)))))))   ; the view's draw timer, armed by the marks

(defun drgnx-view-patch-test--row (key text &rest more)
  (append (list :key key :text text) more))

(cl-defun drgnx-view-patch-test--patch (ops &key (hub 7) (base 0) (version 1) (epoch 1) images)
  (list :view "v" :class "c" :hub hub :base base :version version :env_epoch epoch :ops ops :images images))

(defun drgnx-view-patch-test--reset (keys &rest args)
  (apply #'drgnx-view-patch-test--patch
         (list (list :reset (mapcar (lambda (k) (drgnx-view-patch-test--row k (format "row %s" k))) keys)))
         args))

(defun drgnx-view-patch-test--draw ()
  (drgnx-view-draw-now drgnx-view)
  (buffer-substring-no-properties (point-min) (point-max)))

(defun drgnx-view-patch-test--resyncs ()
  (cl-count-if (lambda (s) (equal (car s) "view/resync")) drgnx-view-patch-test--sent))

;;;; One patch at a time

(ert-deftest drgnx-view-patch/replace-patches-the-row ()
  ;; the selection on a replaced row is the class step's (view-nav-test.el: replaced-row-keeps-its-class)
  (drgnx-view-patch-test--with
    (drgnx-view-apply-patch (drgnx-view-patch-test--reset '("a" "b")))
    (drgnx-view-patch-test--draw)
    (drgnx-view-apply-patch (drgnx-view-patch-test--patch
                             (list (list :replace (list (drgnx-view-patch-test--row "b" "row B"))))
                             :base 1 :version 2))
    (should (equal "row a\nrow B\n" (drgnx-view-patch-test--draw)))))

(ert-deftest drgnx-view-patch/a-pass-reads-the-line-height-once ()
  ;; every row with a height needs the default line height; it cannot change inside one draw pass, so the pass reads it
  ;; once, and the next pass reads it again (a `text-scale' in between shows)
  (drgnx-view-patch-test--with
    (let ((calls 0) (orig (symbol-function 'default-line-height)))
      (cl-letf (((symbol-function 'default-line-height) (lambda (&rest args) (cl-incf calls) (apply orig args))))
        (drgnx-view-apply-patch
         (drgnx-view-patch-test--patch
          (list (list :reset (mapcar (lambda (k) (drgnx-view-patch-test--row k "tall" :height (list :lines 2)))
                                     '("a" "b" "c" "d"))))))
        (drgnx-view-patch-test--draw)
        (should (= calls 1))
        (drgnx-view-apply-patch
         (drgnx-view-patch-test--patch
          (list (list :replace (list (drgnx-view-patch-test--row "b" "taller" :height (list :lines 3))
                                     (drgnx-view-patch-test--row "c" "taller" :height (list :lines 3)))))
          :base 1 :version 2))
        (drgnx-view-patch-test--draw)
        (should (= calls 2))))))

(ert-deftest drgnx-view-patch/unknown-face-is-dropped-not-interned ()
  (drgnx-view-patch-test--with
    (let ((name "drgnx-view-patch-test-no-such-face-4711"))
      (drgnx-view-apply-patch (drgnx-view-patch-test--patch
                               (list (list :reset (list (drgnx-view-patch-test--row
                                                         "a" "xy" :runs (list (list 0 1 name) (list 1 2 "bold"))))))))
      (drgnx-view-patch-test--draw)
      (should-not (intern-soft name))
      (should-not (get-text-property (point-min) 'face))
      (should (eq 'bold (get-text-property (1+ (point-min)) 'face))))))

(ert-deftest drgnx-view-patch/stop-specs-are-shared ()
  (drgnx-view-patch-test--with
    (let ((drgnx-view-patch-measure-function (lambda (_) 0)))
      (drgnx-view-apply-patch (drgnx-view-patch-test--patch
                               (list (list :reset (list (drgnx-view-patch-test--row "a" "x y" :stops '((1 40)))
                                                        (drgnx-view-patch-test--row "b" "z w" :stops '((1 40))))))))
      (drgnx-view-patch-test--draw)
      (let ((sa (get-text-property (+ (drgnx-view-row-start drgnx-view "a") 1) 'display))
            (sb (get-text-property (+ (drgnx-view-row-start drgnx-view "b") 1) 'display)))
        (should (equal '(space :align-to (40)) sa))
        (should (eq sa sb))))))

(ert-deftest drgnx-view-patch/missing-image-resyncs ()
  (drgnx-view-patch-test--with
    (drgnx-view-apply-patch (drgnx-view-patch-test--reset '("a")))
    (should (eq 'resync (drgnx-view-apply-patch
                         (drgnx-view-patch-test--patch
                          (list (list :replace (list (drgnx-view-patch-test--row "a" " x" :images '((0 "00ab-1" "*"))))))
                          :base 1 :version 2))))
    (should (= 1 (drgnx-view-patch-test--resyncs)))
    ;; the same image sent with the patch applies
    (should (eq 'apply (drgnx-view-apply-patch
                        (drgnx-view-patch-test--patch
                         (list (list :replace (list (drgnx-view-patch-test--row "a" " x" :images '((0 "00ab-1" "*"))))))
                         :base 1 :version 2 :images '(("00ab-1" "<svg xmlns=\"http://www.w3.org/2000/svg\"/>"))))))))

(ert-deftest drgnx-view-patch/newer-base-resyncs-once ()
  (drgnx-view-patch-test--with
    (drgnx-view-apply-patch (drgnx-view-patch-test--reset '("a")))
    (dolist (b '(3 4 5))
      (should (eq 'resync (drgnx-view-apply-patch
                           (drgnx-view-patch-test--patch (list (list :remove '("a"))) :base b :version (1+ b))))))
    (should (= 1 (drgnx-view-patch-test--resyncs)))
    ;; the reset that answers it clears the outstanding resync
    (drgnx-view-apply-patch (drgnx-view-patch-test--reset '("a") :base 6 :version 7))
    (drgnx-view-apply-patch (drgnx-view-patch-test--patch (list (list :remove '("a"))) :base 9 :version 10))
    (should (= 2 (drgnx-view-patch-test--resyncs)))))

(ert-deftest drgnx-view-patch/older-base-is-dropped ()
  (drgnx-view-patch-test--with
    (drgnx-view-apply-patch (drgnx-view-patch-test--reset '("a") :base 4 :version 5))
    (should (eq 'drop (drgnx-view-apply-patch
                       (drgnx-view-patch-test--patch (list (list :remove '("a"))) :base 3 :version 4))))
    (should (= 0 (drgnx-view-patch-test--resyncs)))
    (should (equal "row a\n" (drgnx-view-patch-test--draw)))))

(ert-deftest drgnx-view-patch/overflowing-line-is-refit-and-reported ()
  (drgnx-view-patch-test--with
    ;; every character is 10 px: "abcdefgh" (80 px) overflows its stop at 50
    (let ((drgnx-view-patch-measure-function (lambda (s) (* 10 (length s))))
          (drgnx-view--text-width-function (lambda (s) (* 10 (length s)))))
      (drgnx-view-apply-patch (drgnx-view-patch-test--patch
                               (list (list :reset (list (drgnx-view-patch-test--row "a" "abcdefgh rest"
                                                                                    :stops '((8 50))))))))
      (let ((text (drgnx-view-patch-test--draw)))
        (should (string-prefix-p "abcd…" text))
        (should (= (length "abcdefgh rest\n") (length text))))   ; later positions keep their place
      (should (= 1 (drgnx-view-patch-refits drgnx-view-patch)))
      (let ((m (cdr (assoc "view/measured" drgnx-view-patch-test--sent))))
        (should (equal '(("ui" "abcdefgh" 80)) (plist-get m :measured)))))))

(ert-deftest drgnx-view-patch/fitting-line-costs-one-measure ()
  (drgnx-view-patch-test--with
    (let ((n 0))
      (let ((drgnx-view-patch-measure-function (lambda (s) (cl-incf n) (* 10 (length s)))))
        (drgnx-view-apply-patch (drgnx-view-patch-test--patch
                                 (list (list :reset (list (drgnx-view-patch-test--row "a" "abc rest" :stops '((3 50)))
                                                          (drgnx-view-patch-test--row "b" "plain"))))))
        (drgnx-view-patch-test--draw)
        ;; one measure for the row with a stop, none for the row without
        (should (= 1 n))
        (should (= 0 (drgnx-view-patch-refits drgnx-view-patch)))))))

(ert-deftest drgnx-view-patch/board-fits-through-drgnx-view-fit ()
  (should (fboundp 'drgnx-view-fit))
  (let ((drgnx-view--text-width-function (lambda (s) (* 10 (length s))))
        (drgnx-view--fit-memo (make-hash-table :test #'equal)))
    (should (equal "abc…" (drgnx-view-fit "abcdefgh" 40)))
    (should (equal "ab" (drgnx-view-fit "ab" 40))))
  ;; the map and the timeline's lane labels fit through it (the Board's are fitted in the hub since sja-complete B2),
  ;; and the map's old name is gone (no alias)
  (dolist (f '("drgnx-work-map.el" "drgnx-work-trail.el"))
    (with-temp-buffer
      (insert-file-contents (expand-file-name (concat "modules/tools/" f) drgnx-dir))
      (should (search-forward "(drgnx-view-fit " nil t))
      (goto-char (point-min))
      (should-not (re-search-forward "drgnx-work-map--fit\\_>" nil t)))))

;;;; Every order

(defun drgnx-view-patch-test--core-init ()
  (list :state (drgnx-view-patch--make :view "v" :class "c" :epoch 1)
        :rows nil :applied nil :sent 0 :selected nil :select-last nil :epoch-shown nil))

(defun drgnx-view-patch-test--core-step (s ev)
  "One event on the inserter's own bookkeeping (`drgnx-view-patch--accept', `--forget'), no buffer: the rows applied
are kept as a list, newest first."
  (let ((st (plist-get s :state)))
    (pcase (car ev)
      ('patch
       (let ((p (cadr ev)))
         (when (eq 'apply (drgnx-view-patch--accept st p))
           (when (drgnx-view-patch--reset-p p) (setq s (plist-put s :epoch-shown (plist-get p :env_epoch))))
           (setq s (plist-put s :applied (cons p (plist-get s :applied)))))))
      ('disconnect (drgnx-view-patch--forget st))
      ('env (setf (drgnx-view-patch-epoch st) (cadr ev)))
      ('select (setq s (plist-put s :select-last (cadr ev)))))
    (cons (plist-put s :sent (drgnx-view-patch-resyncs st)) nil)))

(defun drgnx-view-patch-test--p (hub base version epoch &optional reset)
  (list 'patch (drgnx-view-patch-test--patch
                (if reset (list (list :reset (list (list :key "a" :text "a"))))
                  (list (list :replace (list (list :key "a" :text (format "%s" version))))))
                :hub hub :base base :version version :epoch epoch)))

(ert-deftest drgnx-view-patch/reconnect-applies-no-old-patch ()
  ;; the old hub (7) is in flight at the disconnect; the new hub (8)'s reset comes after the reconnect
  (drgnx-test-every-order
   :kinds '(patch disconnect select)
   :sources `(("old hub" ,(drgnx-view-patch-test--p 7 0 1 1 t) ,(drgnx-view-patch-test--p 7 1 2 1)
               ,(drgnx-view-patch-test--p 7 2 3 1))
              ("link" (disconnect))
              ("new hub" ,(drgnx-view-patch-test--p 8 0 1 1 t) ,(drgnx-view-patch-test--p 8 1 2 1))
              ("user" (select "a")))
   :edges '((("old hub" . 0) . ("link" . 0)) (("link" . 0) . ("new hub" . 0)))
   :init #'drgnx-view-patch-test--core-init :step #'drgnx-view-patch-test--core-step
   :check (lambda (s _)
            ;; after the new hub's reset, every patch applied is the new hub's
            (let ((after (seq-take-while (lambda (p) (not (and (eql 8 (plist-get p :hub))
                                                               (drgnx-view-patch--reset-p p))))
                                         (plist-get s :applied))))
              (cond ((cl-some (lambda (p) (eql 7 (plist-get p :hub))) after)
                     "an old hub's patch applied after the new hub's reset")
                    ((not (eql 2 (drgnx-view-patch-version (plist-get s :state))))
                     (format "ends at version %S, not the new hub's 2" (drgnx-view-patch-version (plist-get s :state)))))))))

(ert-deftest drgnx-view-patch/held-patches-are-dropped-at-reset ()
  ;; patches for epoch 1 are in flight when the editor sends epoch 2; the hub's reset at 2 follows the env
  (drgnx-test-every-order
   :kinds '(patch env disconnect)
   :sources `(("hub" ,(drgnx-view-patch-test--p 7 0 1 1 t) ,(drgnx-view-patch-test--p 7 1 2 1)
               ,(drgnx-view-patch-test--p 7 2 3 1) ,(drgnx-view-patch-test--p 7 3 4 2 t))
              ("editor" (env 2))
              ("link" (disconnect)))
   :edges '((("hub" . 0) . ("editor" . 0)) (("editor" . 0) . ("hub" . 3)) (("hub" . 3) . ("link" . 0)))
   :init #'drgnx-view-patch-test--core-init :step #'drgnx-view-patch-test--core-step
   :check (lambda (s _)
            (let ((st (plist-get s :state)))
              (cond ((drgnx-view-patch-held st) "held patches left after the reset")
                    ((not (eql 2 (plist-get s :epoch-shown))) "the epoch 2 reset was not applied")
                    ((cl-some (lambda (p) (< (plist-get p :env_epoch) (plist-get s :epoch-shown)))
                              (seq-take-while (lambda (p) (not (drgnx-view-patch--reset-p p))) (plist-get s :applied)))
                     "mixed epochs: an old epoch's patch applied after the new reset"))))))

(ert-deftest drgnx-view-patch/in-flight-patches-after-reset-send-no-resync ()
  ;; a resync's reset (version 5) overtakes nothing: the patches the hub had sent before it (bases 2, 3) arrive after
  (drgnx-test-every-order
   :kinds '(patch select)
   :sources `(("before" ,(drgnx-view-patch-test--p 7 0 1 1 t))
              ("in flight" ,(drgnx-view-patch-test--p 7 2 3 1) ,(drgnx-view-patch-test--p 7 3 4 1))
              ("reset" ,(drgnx-view-patch-test--p 7 4 5 1 t))
              ("user" (select "a")))
   :edges '((("before" . 0) . ("reset" . 0)) (("reset" . 0) . ("in flight" . 0)))
   :init #'drgnx-view-patch-test--core-init :step #'drgnx-view-patch-test--core-step
   :check (lambda (s _)
            (cond ((> (plist-get s :sent) 0) (format "%d resyncs sent" (plist-get s :sent)))
                  ((not (eql 5 (drgnx-view-patch-version (plist-get s :state)))) "not at the reset's version")))))

(ert-deftest drgnx-view-patch/no-mixed-epochs-on-screen ()
  (drgnx-test-every-order
   :kinds '(patch env select)
   :sources `(("hub" ,(drgnx-view-patch-test--p 7 0 1 1 t) ,(drgnx-view-patch-test--p 7 1 2 1)
               ,(drgnx-view-patch-test--p 7 2 3 2 t) ,(drgnx-view-patch-test--p 7 3 4 2))
              ("editor" (env 2))
              ("user" (select "a")))
   :edges '((("hub" . 0) . ("editor" . 0)) (("editor" . 0) . ("hub" . 2)))
   :init #'drgnx-view-patch-test--core-init :step #'drgnx-view-patch-test--core-step
   :check (lambda (s _)
            ;; every patch applied since the last reset is of that reset's epoch
            (let* ((applied (plist-get s :applied))
                   (since (seq-take-while (lambda (p) (not (drgnx-view-patch--reset-p p))) applied))
                   (reset (nth (length since) applied)))
              (cond
               ((not (eql 2 (plist-get s :epoch-shown))) "the epoch 2 reset was not applied")
               ((cl-some (lambda (p) (/= (plist-get p :env_epoch) (plist-get reset :env_epoch))) since)
                "rows of two epochs on screen"))))))

;;;; The rule rows: the fixture view `rows-demo', fed by a real hub (test/fixtures/rows-demo-fixture.el)

(load (expand-file-name "test/fixtures/rows-demo-fixture" drgnx-dir) nil t)

(defun drgnx-view-patch-test--rows (prefix n)
  (let (rows) (dotimes (i n) (push (drgnx-rows-demo-row (format "r%d" i) (format "%s %d" prefix i)) rows)) (nreverse rows)))

(ert-deftest drgnx-view-rows/look-change-mid-stream-ends-on-the-new-epoch ()
  "A stale window: rows stream while the look changes (a theme or a font: the editor's next epoch).  Patches of the
old epoch are held and the view dims; the new epoch's reset drops them, and the view ends plain, on the new epoch,
with the last rows."
  (drgnx-rows-demo-with
    (let ((b (drgnx-rows-demo-open "c")))
      (drgnx-rows-demo-feed (drgnx-view-patch-test--rows "a" 3))
      (drgnx-rows-demo-settle b)
      (should (equal "a 0\na 1\na 2\n" (drgnx-rows-demo-text b)))
      ;; the look changes while the next rows are on their way
      (drgnx-rows-demo-feed (drgnx-view-patch-test--rows "b" 3))
      (drgnx-rows-demo-env "c" 2 :palette [["edge" "#000002"]])
      (drgnx-rows-demo-feed (drgnx-view-patch-test--rows "c" 4))
      (drgnx-rows-demo-settle b)
      (let ((s (drgnx-rows-demo-state b)))
        (should (= 2 (drgnx-view-patch-epoch s)))
        (should-not (drgnx-view-patch-held s))
        (should-not (drgnx-view-patch-stale s)))
      (should (equal "c 0\nc 1\nc 2\nc 3\n" (drgnx-rows-demo-text b))))))

(ert-deftest drgnx-view-rows/two-classes-keep-their-own-rows ()
  "Two display classes of one view: each buffer gets the rows of its class, and a new epoch in one resets only it."
  (drgnx-rows-demo-with
    (let ((one (drgnx-rows-demo-open "one")) (two (drgnx-rows-demo-open "two")))
      (drgnx-rows-demo-feed (drgnx-view-patch-test--rows "x" 2))
      (drgnx-rows-demo-settle one)
      (drgnx-rows-demo-settle two)
      (should (equal "x 0\nx 1\n" (drgnx-rows-demo-text one)))
      (should (equal "x 0\nx 1\n" (drgnx-rows-demo-text two)))
      (let ((v1 (drgnx-view-patch-version (drgnx-rows-demo-state one))))
        (drgnx-rows-demo-env "two" 2 :cell [2 1])
        (drgnx-rows-demo-settle two)
        (should (= v1 (drgnx-view-patch-version (drgnx-rows-demo-state one))))
        (should (= 2 (drgnx-view-patch-epoch (drgnx-rows-demo-state two))))
        (should (equal "x 0\nx 1\n" (drgnx-rows-demo-text two)))))))

(ert-deftest drgnx-view-rows/face-override-after-a-patch-applies ()
  "Rows name faces, never colours: a face remapped in the view's buffer after a patch shows on the patched rows."
  (drgnx-rows-demo-with
    (let ((b (drgnx-rows-demo-open "c")))
      (drgnx-rows-demo-feed (list (drgnx-rows-demo-row "r" "hello" :runs [[0 5 "bold"]])))
      (drgnx-rows-demo-settle b)
      (with-current-buffer b (face-remap-add-relative 'bold :underline t))
      (drgnx-rows-demo-feed (list (drgnx-rows-demo-row "r" "hello again" :runs [[0 5 "bold"]])))
      (drgnx-rows-demo-settle b)
      (with-current-buffer b
        (should (equal "hello again\n" (buffer-string)))
        (should (eq 'bold (get-text-property (point-min) 'face)))
        (should (assq 'bold face-remapping-alist))))))

(ert-deftest drgnx-view-rows/dropped-patch-and-missing-image-resync ()
  "A patch lost on the way (the view's version falls behind) and an image the view lost each send one resync, and
the hub's reset brings the view back: the rows, and the image."
  (drgnx-rows-demo-with
    (let* ((b (drgnx-rows-demo-open "c")) (id "00000000000000ab-1")
           (svg "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"4\" height=\"4\"/>")
           (row (lambda (text) (drgnx-rows-demo-row "r" text :images (vector (vector 0 id "*"))))))
      (drgnx-rows-demo-feed (list (funcall row " one")) (list (list id svg)))
      (drgnx-rows-demo-settle b)
      (let ((s (drgnx-rows-demo-state b)))
        ;; a patch the view never got
        (setf (drgnx-view-patch-version s) (1- (drgnx-view-patch-version s)))
        (drgnx-rows-demo-feed (list (funcall row " two")) (list (list id svg)))
        (drgnx-rows-demo-settle b "the resync answered")
        (should (= 1 (drgnx-view-patch-resyncs s)))
        (should (equal " two\n" (drgnx-rows-demo-text b)))
        ;; an image the view lost
        (clrhash (drgnx-view-patch-images s))
        (drgnx-rows-demo-feed (list (funcall row " three")) (list (list id svg)))
        (drgnx-rows-demo-settle b "the image brought back")
        (should (= 2 (drgnx-view-patch-resyncs s)))
        (should (gethash id (drgnx-view-patch-images s)))
        (should (equal " three\n" (drgnx-rows-demo-text b)))))))

(ert-deftest drgnx-view-rows/hub-restart-resets-first-and-never-applies-the-old-hub ()
  "A hub restart: the view dims and forgets its version; the new hub (a new instance id), once the env is sent again
and the view resubscribed, starts it with a reset, and a resync after works on it.  A patch of the old hub that
arrives after that reset is dropped."
  (drgnx-rows-demo-with
    (let* ((b (drgnx-rows-demo-open "c")) (old-patches nil)
           (keep (lambda (event data) (when (equal event "view-patch") (push data old-patches))))
           ;; the view's reconnect: its env again, then its rows asked for (what `drgnx-view-env' and the view's
           ;; RESUBSCRIBE do on `drgnx-hub-connected-functions')
           (resubscribe (lambda ()
                          (drgnx-rows-demo-env "c" 1)
                          (drgnx-rows-demo-feed (drgnx-view-patch-test--rows "new" 2)))))
      (add-hook 'drgnx-hub-event-functions keep)
      (drgnx-rows-demo-feed (drgnx-view-patch-test--rows "old" 2))
      (drgnx-rows-demo-settle b)
      (drgnx-rows-demo-feed (drgnx-view-patch-test--rows "old+" 3))
      (drgnx-rows-demo-settle b)
      (remove-hook 'drgnx-hub-event-functions keep)
      (let* ((s (drgnx-rows-demo-state b)) (old-hub (drgnx-view-patch-hub s)) (stale (car old-patches)))
        (should (= 2 (length old-patches)))
        (drgnx-rows-demo-restart-hub)
        ;; the subscription closed: dimmed, version and hub forgotten, keys still work
        (should (drgnx-view-patch-stale s))
        (should-not (drgnx-view-patch-version s))
        (funcall resubscribe)
        (drgnx-rows-demo-settle b "the new hub's reset")
        (should-not (eql old-hub (drgnx-view-patch-hub s)))
        (should (= 1 (drgnx-view-patch-version s)))
        (should-not (drgnx-view-patch-stale s))
        (should (equal "new 0\nnew 1\n" (drgnx-rows-demo-text b)))
        ;; the old hub's last patch, late: dropped, nothing asked
        (should (eq 'drop (drgnx-view-apply-patch stale)))
        (should (= 0 (drgnx-view-patch-resyncs s)))
        ;; a patch lost on the new hub: one resync, answered by its reset
        (setf (drgnx-view-patch-version s) 0)
        (drgnx-rows-demo-feed (drgnx-view-patch-test--rows "newer" 2))
        (drgnx-rows-demo-settle b "the new hub's resync answered")
        (should (= 1 (drgnx-view-patch-resyncs s)))
        (should (equal "newer 0\nnewer 1\n" (drgnx-rows-demo-text b)))))))

;;;; Styles, acknowledged patches and the epoch exemption (a terminal's view)

(drgnx-view-define 'drgnx-view-patch-test-term :render #'drgnx-view-patch-render
                   :patched #'drgnx-view-patch--patched :slice drgnx-view-slice :delay 0 :ack t :epoch-reset nil)

(defmacro drgnx-view-patch-test--with-term (&rest body)
  "BODY as `drgnx-view-patch-test--with', the pair a view of the terminal-like type (acks, no epoch reset)."
  (declare (indent 0))
  `(let ((drgnx-view-patch--buffers (make-hash-table :test #'equal))
         (drgnx-view-patch--hooked nil)
         (drgnx-view-patch-test--sent nil)
         (drgnx-view-patch-send-function (lambda (m p) (push (cons m p) drgnx-view-patch-test--sent))))
     (with-temp-buffer
       (let* ((buf (current-buffer))
              (view (drgnx-view-patch-attach "v" "c" :epoch 1 :type 'drgnx-view-patch-test-term)))
         (ignore buf view)
         (unwind-protect (progn ,@body)
           (drgnx-view-patch-teardown)
           (drgnx-timer-cancel (cons 'drgnx-view buf)))))))

(defun drgnx-view-patch-test--styled (key text runs styles &rest args)
  "A reset of one row KEY with TEXT and RUNS, carrying STYLES ((ID STYLE) ...)."
  (append (apply #'drgnx-view-patch-test--patch
                 (list (list :reset (list (drgnx-view-patch-test--row key text :runs runs)))) args)
          (list :styles styles)))

(defun drgnx-view-patch-test--rgb (i)
  "The I-th program colour of a test, as the hub writes it (program data, not a theme colour)."
  (format "#%06x" (* 4099 (1+ i))))

(ert-deftest drgnx-view-patch/style-run-uses-ansi-face ()
  "An `s:' run resolves against the buffer's style table: an ansi foreground is the face `drgnx-term-color-N' itself,
attributes go into an anonymous face before it, and a default colour adds nothing."
  (drgnx-view-patch-test--with-term
    (drgnx-view-apply-patch
     (drgnx-view-patch-test--styled "1" "abcdef" '((0 2 "s:3") (2 4 "s:4") (4 6 "s:5"))
                                    '((3 (:fg (:ansi 1))) (4 (:fg (:ansi 2) :bold t :underline t)) (5 (:italic :false)))))
    (drgnx-view-patch-test--draw)
    (should (eq 'drgnx-term-color-1 (get-text-property (point-min) 'face)))
    (let ((f (get-text-property (+ 2 (point-min)) 'face)))
      (should (consp f))
      ;; the colour's face, then bold text's own (empty unless the theme gives it a colour)
      (should (equal (cdr f) '(drgnx-term-color-2 drgnx-term-bold)))
      (should (eq 'bold (plist-get (car f) :weight)))
      (should (eq t (plist-get (car f) :underline)))
      (should-not (plist-get (car f) :foreground)))
    (should-not (get-text-property (+ 4 (point-min)) 'face))
    (should (facep 'drgnx-term-color-15))
    (should (eq 'ansi-color-bright-white (face-attribute 'drgnx-term-color-15 :inherit)))))

(ert-deftest drgnx-view-patch/rgb-face-cache-is-bounded ()
  "Program colours become anonymous faces from a per-buffer LRU: one face per (colours, attributes), shared, and never
more than `drgnx-view-patch-style-face-max' kept; the least recently used go first."
  (drgnx-view-patch-test--with-term
    (let ((drgnx-view-patch-style-face-max 8) (n 20))
      (drgnx-view-apply-patch
       (drgnx-view-patch-test--styled
        "1" (make-string (1+ n) ?x)
        (append (cl-loop for i below n collect (list i (1+ i) (format "s:%d" i)))
                (list (list n (1+ n) (format "s:%d" (1- n)))))
        (cl-loop for i below n collect (list i (list :fg (list :rgb (drgnx-view-patch-test--rgb i)))))))
      (drgnx-view-patch-test--draw)
      (should (<= (hash-table-count (drgnx-view-patch-faces drgnx-view-patch)) 8))
      (let ((last (get-text-property (+ (1- n) (point-min)) 'face)))
        (should (equal (drgnx-view-patch-test--rgb (1- n)) (plist-get last :foreground))))
      ;; the same style twice is the same face object
      (should (eq (get-text-property (+ (1- n) (point-min)) 'face) (get-text-property (+ n (point-min)) 'face))))))

(ert-deftest drgnx-view-patch/unknown-style-id-resyncs ()
  "A run naming a style the buffer does not hold (and the patch does not bring) sends one `view/resync'."
  (drgnx-view-patch-test--with-term
    (drgnx-view-apply-patch (drgnx-view-patch-test--styled "1" "ab" '((0 2 "s:3")) '((3 (:bold t)))))
    (let ((row (drgnx-view-patch-test--row "1" "ab" :runs '((0 2 "s:9")))))
      (should (eq 'resync (drgnx-view-apply-patch
                           (drgnx-view-patch-test--patch (list (list :replace (list row))) :base 1 :version 2))))
      (should (= 1 (drgnx-view-patch-test--resyncs)))
      ;; held from before, or brought by the patch: applied
      (should (eq 'apply (drgnx-view-apply-patch
                          (append (drgnx-view-patch-test--patch (list (list :replace (list row))) :base 1 :version 2)
                                  (list :styles '((9 (:italic t))))))))
      (should (eq 'apply (drgnx-view-apply-patch
                          (drgnx-view-patch-test--patch
                           (list (list :replace (list (drgnx-view-patch-test--row "1" "ab" :runs '((0 2 "s:3"))))))
                           :base 2 :version 3)))))))

(ert-deftest drgnx-view-patch/epoch-exempt-view-keeps-rows-on-theme ()
  "A view exempt from the epoch reset (`:epoch-reset nil') applies a patch of an older epoch after a theme change
\(its faces repaint in place): it is not held, and the view does not dim.  A plain view still holds it."
  (drgnx-view-patch-test--with-term
    (drgnx-view-apply-patch (drgnx-view-patch-test--reset '("a")))
    (drgnx-view-patch-test--draw)
    (drgnx-view-patch-env-sent "v" "c" 2)
    (should (eq 'apply (drgnx-view-apply-patch
                        (drgnx-view-patch-test--patch
                         (list (list :insert (list :after "a" :rows (list (drgnx-view-patch-test--row "b" "row b")))))
                         :base 1 :version 2 :epoch 1))))
    (should-not (drgnx-view-patch-stale drgnx-view-patch))
    (should (equal "row a\nrow b\n" (drgnx-view-patch-test--draw))))
  (drgnx-view-patch-test--with
    (drgnx-view-apply-patch (drgnx-view-patch-test--reset '("a")))
    (drgnx-view-patch-env-sent "v" "c" 2)
    (should (eq 'hold (drgnx-view-apply-patch
                       (drgnx-view-patch-test--patch (list (list :remove '("a"))) :base 1 :version 2 :epoch 1))))))

(ert-deftest drgnx-view-patch/ack-sent-after-apply ()
  "A view that asked for acks sends `view/ack' with the version after each applied patch, and none for a patch it
drops; a plain view sends none."
  (drgnx-view-patch-test--with-term
    (drgnx-view-apply-patch (drgnx-view-patch-test--reset '("a")))
    (should (equal '("view/ack" :view "v" :class "c" :version 1) (car drgnx-view-patch-test--sent)))
    (drgnx-view-apply-patch (drgnx-view-patch-test--patch (list (list :remove '("a"))) :base 1 :version 2))
    (should (equal '("view/ack" :view "v" :class "c" :version 2) (car drgnx-view-patch-test--sent)))
    (should (eq 'drop (drgnx-view-apply-patch
                       (drgnx-view-patch-test--patch (list (list :remove '("a"))) :base 0 :version 1))))
    (should (= 2 (cl-count "view/ack" drgnx-view-patch-test--sent :key #'car :test #'equal))))
  (drgnx-view-patch-test--with
    (drgnx-view-apply-patch (drgnx-view-patch-test--reset '("a")))
    (should-not (assoc "view/ack" drgnx-view-patch-test--sent))))

(ert-deftest drgnx-view-patch/face-override-on-ansi-shows-live ()
  "An ansi colour is the face itself on the text, never a resolved colour: a remap of `drgnx-term-color-N' made after
the patch shows on the rows already inserted, with no new patch."
  (drgnx-view-patch-test--with-term
    (drgnx-view-apply-patch (drgnx-view-patch-test--styled "1" "hello" '((0 5 "s:1")) '((1 (:fg (:ansi 1))))))
    (drgnx-view-patch-test--draw)
    (face-remap-add-relative 'drgnx-term-color-1 :inherit 'error)
    (should (eq 'drgnx-term-color-1 (get-text-property (point-min) 'face)))
    (should (assq 'drgnx-term-color-1 face-remapping-alist))
    (should (equal "hello\n" (buffer-substring-no-properties (point-min) (point-max))))))
