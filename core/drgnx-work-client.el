;;; drgnx-work-client.el --- The Work map's client: the map views this Emacs subscribed to the hub -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; The hub keeps one map per (connection, view), lays it out and sends its rows as `view-patch' events, with the map's
;; model for Sjá (docs/develop/hub.md, "The Work map").  This library keeps the views (an id string each) and calls the
;; hub for them: `work/map/subscribe', `set' and `close', on the connection the patches come back on.  It subscribes
;; again from `drgnx-hub-connected-functions' and says a view is "reconnecting" when the hub goes and while a
;; subscription has no answer (`drgnx-work-client-status-functions').  Nothing here draws.
;; See docs/develop/work-space.md.

;;; Code:
(require 'cl-lib)
(require 'subr-x)

(cl-defstruct (drgnx-work-client--view (:constructor drgnx-work-client--make-view) (:copier nil))
  "One map view of this Emacs.  PARAMS: the plist `work/map/subscribe' takes (without :view).  STATUS: `subscribing',
`live', `reconnecting' or `hidden'."
  id params (status 'subscribing) (shown t) (gen 0))

(defvar drgnx-work-client--views (make-hash-table :test #'equal)
  "View id → `drgnx-work-client--view'.  A view is closed with its buffer (the module's kill hook) or by the module's
teardown, which empties the table; there is a handful, never more than the maps the user opens.")

(defvar drgnx-work-client-status-functions nil
  "Called with (VIEW-ID STATUS) when a view's status changes (`live', `reconnecting', `hidden').")

(defun drgnx-work-client-views () "The ids of the open views." (hash-table-keys drgnx-work-client--views))

(defun drgnx-work-client--get (id) (gethash id drgnx-work-client--views))

(defun drgnx-work-client-status (id)
  "View ID's status as a string: \"subscribing\", \"live\", \"reconnecting\" or \"hidden\"."
  (when-let* ((v (drgnx-work-client--get id))) (symbol-name (drgnx-work-client--view-status v))))

(defun drgnx-work-client-shown-p (id)
  "Whether the hub was told view ID is shown."
  (when-let* ((v (drgnx-work-client--get id))) (and (drgnx-work-client--view-shown v) t)))

(defun drgnx-work-client--run (hook &rest args)
  (if (fboundp 'drgnx-guard-run-hook)
      (apply #'drgnx-guard-run-hook hook args)
    (apply #'run-hook-with-args hook args)))

(defun drgnx-work-client--status (view status)
  (unless (eq status (drgnx-work-client--view-status view))
    (setf (drgnx-work-client--view-status view) status)
    (drgnx-work-client--run 'drgnx-work-client-status-functions
                            (drgnx-work-client--view-id view) (symbol-name status))))

(defvar drgnx-hub--events)
(declare-function drgnx-hub--call-on "drgnx-hub-client")

(defun drgnx-work-client--call (method params callback)
  "Ask the hub METHOD with PARAMS on this Emacs's subscribed connection, the one the map's patches come back on (the
hub sends a view's patches to the connection that subscribed it).  Non-nil when it was asked; nil while the
connection is down: the views subscribe again when it is up (`drgnx-work-client-connected')."
  (when (and (boundp 'drgnx-hub--events) (process-live-p drgnx-hub--events))
    (drgnx-hub--call-on drgnx-hub--events method params callback)
    t))

(defun drgnx-work-client--subscribe (view)
  "Ask the hub for VIEW's rows.  The answer counts only for the subscription it was asked in (a later one, or a close,
makes it stale).  Without a connection the view waits, keeping what it has."
  (let ((gen (cl-incf (drgnx-work-client--view-gen view))) (id (drgnx-work-client--view-id view)))
    (unless (drgnx-work-client--call "work/map/subscribe" (append (list :view id) (drgnx-work-client--view-params view))
                                     (lambda (result err) (drgnx-work-client--subscribed id gen result err)))
      (drgnx-work-client--status view 'reconnecting))))

(defun drgnx-work-client--subscribed (id gen result err)
  "The hub answered view ID's subscription GEN: the patches (a reset first) bring the map."
  (let ((view (drgnx-work-client--get id)))
    (when (and view (= gen (drgnx-work-client--view-gen view)))
      (drgnx-work-client--status view (cond ((or err (null result)) 'reconnecting)
                                            ((drgnx-work-client--view-shown view) 'live)
                                            (t 'hidden))))))

(cl-defun drgnx-work-client-open (id workspace &key (width 226) density filters collapsed selected)
  "Open the view ID on WORKSPACE (a plist :id :roots) and ask the hub for it; returns ID.  WIDTH is the drawing width
in units of 4 px.  The hub builds the view's rows and sends them as `view-patch' to the classes this Emacs sent a
`view/env' for (the env's view is ID)."
  (let ((view (drgnx-work-client--make-view
               :id id
               :params (append (list :workspace (list :id (plist-get workspace :id) :roots (plist-get workspace :roots))
                                     :width_units width)
                               (and density (list :density density)) (and filters (list :filters filters))
                               (and collapsed (list :collapsed collapsed)) (and selected (list :selected selected))))))
    (puthash id view drgnx-work-client--views)
    (condition-case nil (drgnx-work-client--subscribe view)
      (error (drgnx-work-client--status view 'reconnecting)))
    id))

(defun drgnx-work-client-set (id &rest params)
  "Tell the hub what changed in view ID: PARAMS are `work/map/set''s fields (:filters :collapsed :width_units
:density :shown :selected :outline).  A change of the saved parameters (all but :shown) is kept for the next
subscription.  Never signals: a hub that is not there is the reconnecting view's matter."
  (apply #'drgnx-work-client-set-then id #'ignore params))

(defun drgnx-work-client-set-then (id callback &rest params)
  "`drgnx-work-client-set' of view ID with PARAMS, and CALLBACK called with (RESULT ERR) when the hub answers.  The
hub sends what the change makes (the view's patches) before its answer, on the same connection."
  (when-let* ((view (drgnx-work-client--get id)))
    (let ((saved (drgnx-work-client--view-params view)))
      (cl-loop for (k v) on params by #'cddr
               unless (eq k :shown) do (setq saved (plist-put saved k v)))
      (setf (drgnx-work-client--view-params view) saved))
    (when (plist-member params :shown)
      (setf (drgnx-work-client--view-shown view) (not (memq (plist-get params :shown) '(nil :false)))))
    (ignore-errors (drgnx-work-client--call "work/map/set" (append (list :view id) params) callback))
    id))

(defun drgnx-work-client-close (id)
  "Close view ID: the hub forgets it."
  (when-let* ((view (drgnx-work-client--get id)))
    (cl-incf (drgnx-work-client--view-gen view))          ; a pending answer is stale now
    (remhash id drgnx-work-client--views)
    (ignore-errors (drgnx-work-client--call "work/map/close" (list :view id) #'ignore))
    t))

(defun drgnx-work-client-close-all ()
  "Close every view (the module's teardown)."
  (dolist (id (drgnx-work-client-views)) (drgnx-work-client-close id)))

(defun drgnx-work-client-connected ()
  "A `drgnx-hub-connected-functions' handler: every view subscribes again (the hub kept nothing)."
  (maphash (lambda (_ view) (condition-case nil (drgnx-work-client--subscribe view)
                              (error (drgnx-work-client--status view 'reconnecting))))
           drgnx-work-client--views))

(defun drgnx-work-client-disconnected ()
  "A `drgnx-hub-disconnect-functions' handler: every view keeps what it shows and says it is reconnecting."
  (maphash (lambda (_ view) (drgnx-work-client--status view 'reconnecting)) drgnx-work-client--views))

(provide 'drgnx-work-client)
;;; drgnx-work-client.el ends here
