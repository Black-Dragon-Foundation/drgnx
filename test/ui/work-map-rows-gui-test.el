;;; work-map-rows-gui-test.el --- GUI rows: the Work map and trail on the hub's rows, against the view rules -*- lexical-binding: t -*-
;; test-class: cond
;; test-pattern: handshake
;; The render offload's rule rows (docs/develop/core.md, "Hub-fed views") on the Work map and a trail fed by a real
;; hub: the 30-agent fixture (test/fixtures/work-space-thirty-fixture.el; a test-hooks ratatoskr with ratatoskr-mock
;; beside it), every agent streaming while the rows are checked.  `text-scale' moves the view to a new display class
;; that the hub's reset fills; a second frame at twice the font is a second class with its own reset; a theme change
;; mid-stream leaves no row of the old epoch on screen; a face override made after a patch shows on the next draw.
;; Needs Sjá (the map takes the hub's rows only with it).

(require 'ert)
(require 'cl-lib)
(require 'seq)
(require 'drgnx-uitest)

(defconst drgnx-work-map-rows-gui--repo
  (expand-file-name "../../" (file-name-as-directory (or (getenv "DRGNX_UI_TEST") default-directory))))
(dolist (d '("core" "wb" "modules/ui"))
  (add-to-list 'load-path (expand-file-name d drgnx-work-map-rows-gui--repo)))
(require 'drgnx)
(require 'drgnx-view)
(require 'drgnx-view-env)
(load (expand-file-name "test/fixtures/work-space-thirty-fixture" drgnx-work-map-rows-gui--repo) nil t)
(load (expand-file-name "test/fixtures/modules-fixture" drgnx-work-map-rows-gui--repo) nil t)
(load (expand-file-name "test/fixtures/wait-fixture" drgnx-work-map-rows-gui--repo) nil t)

(declare-function drgnx-work-trail-open "drgnx-work-trail")
(declare-function drgnx-work-thirty-start "work-space-thirty-fixture")
(declare-function drgnx-work-thirty-stop "work-space-thirty-fixture")
(declare-function drgnx-work-thirty-map "work-space-thirty-fixture")
(declare-function nidhogg-view-get "nidhogg-views")
(defvar drgnx-view-old-path)

(defun drgnx-work-map-rows-gui--bin ()
  "The hub: DRGNX_RATATOSKR_BIN, else the checkout's own build (a GUI session does not inherit the variable)."
  (let ((bin (or (getenv "DRGNX_RATATOSKR_BIN")
                 (expand-file-name "runtime/target/debug/ratatoskr" drgnx-work-map-rows-gui--repo))))
    (unless (file-executable-p bin) (ert-fail (format "needs a test-hooks ratatoskr built in the checkout (%s)" bin)))
    bin))

(defmacro drgnx-work-map-rows-gui--with (&rest body)
  "BODY with the 30-agent map on the hub's rows alone in the root frame's selected window; `buf' is bound."
  (declare (indent 0))
  `(progn
     (skip-unless (and (display-graphic-p) (fboundp 'nidhogg-view--call)))
     (drgnx-test-with-modules '(tools/work-space)
       (let ((drgnx-view-old-path nil) (root (drgnx-uitest-root-frame)) (buf nil))
         (unwind-protect
             (with-selected-frame root
               (delete-other-windows)
               (drgnx-work-thirty-start (drgnx-work-map-rows-gui--bin))
               (setq buf (drgnx-work-thirty-map t))
               (delete-other-windows)
               (set-window-buffer (selected-window) buf)
               (should (buffer-local-value 'drgnx-view-patch buf))
               (drgnx-work-map-rows-gui--settle buf)
               ,@body)
           (mapc #'disable-theme custom-enabled-themes)
           (when (buffer-live-p buf) (kill-buffer buf))
           (drgnx-work-thirty-stop))))))

(defun drgnx-work-map-rows-gui--state (buffer) (buffer-local-value 'drgnx-view-patch buffer))

(defun drgnx-work-map-rows-gui--settle (buffer &optional pred what)
  "Wait until BUFFER's view holds a version of its class, is not stale, asks no resync and PRED holds; draw it.  The
agents keep streaming, so this never waits for the hub to fall quiet."
  (drgnx-test-wait (lambda ()
                     (redisplay t)
                     (let ((s (drgnx-work-map-rows-gui--state buffer)))
                       (and (drgnx-view-patch-version s) (not (drgnx-view-patch-stale s))
                            (not (drgnx-view-patch-resync s)) (> (buffer-size buffer) 0)
                            (or (null pred) (funcall pred s)))))
                   :secs 30 :what (or what "the hub's rows drawn"))
  (with-current-buffer buffer (drgnx-view-draw-now drgnx-view))
  buffer)

(defun drgnx-work-map-rows-gui--named-face (buffer)
  "A named face the first styled text of BUFFER shows (its own or one it inherits), or nil."
  (with-current-buffer buffer
    (let ((pos (point-min)) found)
      (while (and (not found) pos (< pos (point-max)))
        (let ((f (get-text-property pos 'face)))
          (dolist (x (ensure-list f))
            (cond ((and (symbolp x) (facep x) (not found)) (setq found x))
                  ((and (consp x) (not found))
                   (let ((inh (plist-get x :inherit))) (setq found (car (seq-filter #'facep (ensure-list inh)))))))))
        (setq pos (next-single-property-change pos 'face)))
      found)))

(ert-deftest drgnx-work-map-rows-gui/text-scale-moves-the-map-to-its-new-class ()
  "`text-scale' in the map's buffer makes a new display class: the buffer follows it and the hub's reset for that
class fills it again, while the agents stream."
  (require 'face-remap)
  (drgnx-work-map-rows-gui--with
    (let ((class (drgnx-view-patch-class (drgnx-work-map-rows-gui--state buf))))
      (unwind-protect
          (progn
            (with-current-buffer buf (text-scale-set 2))
            (drgnx-work-map-rows-gui--settle buf (lambda (s) (not (equal class (drgnx-view-patch-class s))))
                                             "the map in its new class")
            (should (member (drgnx-view-patch-class (drgnx-work-map-rows-gui--state buf))
                            (drgnx-view-env-classes (drgnx-view-patch-view (drgnx-work-map-rows-gui--state buf))))))
        (with-current-buffer buf (text-scale-set 0))))))

(ert-deftest drgnx-work-map-rows-gui/two-frames-two-classes ()
  "The map shown in a second frame whose default font is twice the first's: one env per class, each class starts with
its own reset, and the buffer keeps the class it is paired with, never stale."
  (drgnx-work-map-rows-gui--with
    (let* ((view (drgnx-view-patch-view (drgnx-work-map-rows-gui--state buf))) (resets nil)
           (count (lambda (event data)
                    (when (and (equal event "view-patch") (equal (plist-get data :view) view)
                               (drgnx-view-patch--reset-p data))
                      (push (plist-get data :class) resets))))
           (frame (make-frame '((width . 80) (height . 20))))
           (paired (drgnx-view-patch-class (drgnx-work-map-rows-gui--state buf))))
      (unwind-protect
          (progn
            (add-hook 'drgnx-hub-event-functions count)
            (set-face-attribute 'default frame :height (* 2 (face-attribute 'default :height)))
            (set-window-buffer (frame-root-window frame) buf)
            (drgnx-test-wait (lambda () (eq t (frame-visible-p frame))) :secs 10 :what "the second frame shown")
            (drgnx-view-env-update view)
            (drgnx-test-wait (lambda () (seq-some (lambda (c) (not (equal c paired))) resets)) :secs 30
                             :what "the second class's reset")
            (should (= 2 (length (drgnx-view-env-classes view))))
            (drgnx-work-map-rows-gui--settle buf)
            (should (member (drgnx-view-patch-class (drgnx-work-map-rows-gui--state buf))
                            (drgnx-view-env-classes view))))
        (remove-hook 'drgnx-hub-event-functions count)
        (delete-frame frame)))))

(ert-deftest drgnx-work-map-rows-gui/a-theme-change-mid-stream-leaves-no-old-epoch ()
  "Dark, then light, while the agents stream: each theme takes the next epoch, and once drawn the map holds only rows
of that epoch (not stale, the env's epoch); a screenshot of each."
  (drgnx-work-map-rows-gui--with
    (let ((s (drgnx-work-map-rows-gui--state buf)) (last 0))
      (dolist (theme '(drgnx-dark drgnx-light))
        (load-theme theme t)
        (drgnx-work-map-rows-gui--settle
         buf (lambda (s) (and (> (drgnx-view-patch-epoch s) last)
                              (eql (drgnx-view-patch-epoch s)
                                   (drgnx-view-env-epoch (drgnx-view-patch-view s) (drgnx-view-patch-class s)))))
         (format "the map in %s's epoch" theme))
        (should-not (drgnx-view-patch-stale s))
        (setq last (drgnx-view-patch-epoch s))
        (drgnx-test-wait-presented)
        (let ((shot (plist-get (drgnx-uitest-capture (make-temp-file "work-rows" t)) :root)))
          (should (file-exists-p shot))
          (drgnx-uitest--evidence shot))
        (mapc #'disable-theme custom-enabled-themes)))))

(ert-deftest drgnx-work-map-rows-gui/a-face-override-shows-on-the-next-draw ()
  "The map's rows name faces, never colours: an override of a face they show, made after a patch, is on screen at the
next draw with no new patch asked for."
  (drgnx-work-map-rows-gui--with
    (let ((face (drgnx-work-map-rows-gui--named-face buf)))
      (should face)
      (unwind-protect
          (progn
            (set-face-attribute face nil :underline t)
            (redisplay t)
            (should (eq t (face-attribute face :underline))))
        (set-face-attribute face nil :underline 'unspecified)))))

(ert-deftest drgnx-work-map-rows-gui/the-trail-takes-its-new-class-after-text-scale ()
  "A trail of a streaming agent on the hub's rows: drawn, then `text-scale' moves it to a new class the hub fills."
  (require 'face-remap)
  (drgnx-work-map-rows-gui--with
    (let* ((team (append (nidhogg-view-get (drgnx-view-patch-handle (drgnx-work-map-rows-gui--state buf)) 'list "team")
                         nil))
           (sid (string-remove-prefix "agent:" (seq-find (lambda (id) (string-prefix-p "agent:" id)) team)))
           (trail (drgnx-work-trail-open buf sid)))
      (unwind-protect
          (progn
            (set-window-buffer (selected-window) trail)
            (should (buffer-local-value 'drgnx-view-patch trail))
            (drgnx-work-map-rows-gui--settle trail nil "the trail drawn")
            (let ((class (drgnx-view-patch-class (drgnx-work-map-rows-gui--state trail))))
              (with-current-buffer trail (text-scale-set 2))
              (drgnx-work-map-rows-gui--settle trail (lambda (s) (not (equal class (drgnx-view-patch-class s))))
                                               "the trail in its new class")))
        (when (buffer-live-p trail) (kill-buffer trail))))))

;;; work-map-rows-gui-test.el ends here
