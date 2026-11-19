;;; doc-agents-gui-test.el --- GUI tests: documents written with agents, the live paragraph and the comments (run by `drgnx test --ui') -*- lexical-binding: t -*-
;; test-class: det
;; test-pattern: pure
;; The writing agent's paragraph (the one under its newest edit range, from presence) is marked with its mark in the
;; margin and a quiet fill that moves with it; a comment is a thread anchored to a paragraph, steered to the writer
;; through `comments/add' (never a cancel), marked in the margin "N comments", answered in the thread's card.  The hub is
;; stubbed at `drgnx-hub-call'.

(require 'ert)
(require 'cl-lib)
(require 'drgnx-uitest)

(defconst drgnx-ui-doc-agents--repo
  (expand-file-name "../../" (file-name-as-directory (or (getenv "DRGNX_UI_TEST") default-directory))))
(dolist (d '("core" "wb" "modules/tools"))
  (add-to-list 'load-path (expand-file-name d drgnx-ui-doc-agents--repo)))
(require 'drgnx)
(require 'drgnx-ui-kit)
(require 'drgnx-doc-agents)
(defvar drgnx-hub--events)

(defconst drgnx-ui-doc-agents--text
  "# Side bars\n\n1. Intent\n\nGet back to Files in one click.\n\n2. The left rail\n\nPlaces: Work, Files, Search.\n\n3. Agents on the right\n\nEach agent is a card.\n")

(defmacro drgnx-ui-doc-agents--with (calls &rest body)
  "BODY in a buffer of the document with `drgnx-doc-agents-mode' on for the record plan:p1, the hub stubbed (each call pushed
on CALLS as (METHOD . PARAMS); `comments/add' answers a thread sent to the writer)."
  (declare (indent 1))
  `(let ((,calls nil))
     (skip-unless (display-graphic-p))
     (cl-letf (((symbol-function 'drgnx-hub-call)
                (lambda (method params &optional cb)
                  (push (cons method params) ,calls)
                  (when (and cb (equal method "comments/add"))
                    (funcall cb (list :comment "c1" :sent_to "s1" :anchor (plist-get params :anchor)) nil))))
               ((symbol-function 'process-live-p) (lambda (p) (eq p 'stub)))
               ((symbol-function 'drgnx-hub--call-on) (lambda (_c method params &rest _) (push (cons method params) ,calls) nil)))
       (with-temp-buffer
         (insert drgnx-ui-doc-agents--text)
         (setq drgnx-hub--events (quote stub))
         (setq drgnx-doc-agents--record "plan:p1")
         (drgnx-doc-agents-mode 1)
         (unwind-protect (progn ,@body) (drgnx-doc-agents-mode -1) (setq drgnx-hub--events nil))))))

(defun drgnx-ui-doc-agents--line (text)
  "Go to the start of the line holding TEXT."
  (goto-char (point-min)) (search-forward text) (beginning-of-line))

(ert-deftest drgnx-ui-doc-agents/writing-paragraph-is-marked ()
  (drgnx-ui-doc-agents--with calls
    (drgnx-ui-doc-agents--line "Places: Work")
    (let ((line (line-number-at-pos)))
      (drgnx-doc-agents-mark-writer line line 3 "C"))
    (let ((o (car (overlays-in (point-min) (point-max)))) (found nil))
      (dolist (ov (overlays-in (point-min) (point-max)))
        (when (overlay-get ov 'drgnx-doc-agents-writer) (setq found ov)))
      (should found)
      (should (equal "Places: Work, Files, Search."
                     (string-trim (buffer-substring-no-properties (overlay-start found) (overlay-end found)))))
      (should (string-match-p "C" (substring-no-properties (overlay-get found 'before-string))))
      (should (overlay-get found 'face))
      (ignore o))
    ;; the next edit is in the next paragraph: the one overlay moves, none is left behind
    (drgnx-ui-doc-agents--line "Each agent is a card")
    (let ((line (line-number-at-pos))) (drgnx-doc-agents-mark-writer line line 3 "C"))
    (let ((writers (cl-remove-if-not (lambda (ov) (overlay-get ov 'drgnx-doc-agents-writer)) (overlays-in (point-min) (point-max)))))
      (should (= 1 (length writers)))
      (should (string-match-p "Each agent is a card" (buffer-substring-no-properties (overlay-start (car writers)) (overlay-end (car writers))))))))

(ert-deftest drgnx-ui-doc-agents/comment-add-steers-the-writer-and-reply-shows ()
  (drgnx-ui-doc-agents--with calls
    (drgnx-ui-doc-agents--line "Places: Work")
    (drgnx-doc-agents-comment-add "Say what a place is.")
    (let ((add (cdr (cl-find "comments/add" calls :key #'car :test #'equal))))
      (should (equal "plan:p1" (plist-get add :record)))
      (should (string-prefix-p "Places: Work" (plist-get (plist-get add :anchor) :quote)))
      (should (equal "Say what a place is." (plist-get add :text))))
    ;; the thread's card is asked for again
    (should (member "doc-comments/set" (mapcar #'car calls)))
    ;; the writer answers: the paragraph's margin marker counts the thread's two comments
    (drgnx-doc-agents--show-threads
     (list (list :root (list :id "c1" :text "Say what a place is." :author "user")
                 :replies (vector (list :id "c2" :text "Done." :author "writer"))
                 :anchor (list :quote "Places: Work, Files, Search." :state "here") :sent_to "s1")))
    (let ((markers (cl-remove-if-not (lambda (ov) (overlay-get ov 'drgnx-doc-agents-comments)) (overlays-in (point-min) (point-max)))))
      (should (= 1 (length markers)))
      (should (string-match-p "2" (substring-no-properties (overlay-get (car markers) 'before-string))))
      (should (equal "2 comments" (get-text-property 0 'help-echo (overlay-get (car markers) 'before-string)))))))

(ert-deftest drgnx-ui-doc-agents/send-never-cancels ()
  (drgnx-ui-doc-agents--with calls
    (drgnx-ui-doc-agents--line "Get back to Files")
    (drgnx-doc-agents-comment-add "Shorter.")
    (drgnx-doc-agents-reply "c1" "And the title.")
    (dolist (m (mapcar #'car calls))
      (should (member m '("comments/add" "comments/reply" "doc-comments/set"))))
    (should-not (cl-some (lambda (c) (string-match-p "cancel\\|stop\\|kill" (car c))) calls))))

(ert-deftest drgnx-ui-doc-agents/removed-anchor-keeps-its-quote ()
  "A thread whose paragraph is gone has no marker in the document; its quote is kept for the card."
  (drgnx-ui-doc-agents--with calls
    (drgnx-doc-agents--show-threads
     (list (list :root (list :id "c1" :text "Why?" :author "user") :replies [] :sent_to "s1"
                 :anchor (list :quote "A paragraph that is gone" :state "removed"))))
    (should-not (cl-remove-if-not (lambda (ov) (overlay-get ov 'drgnx-doc-agents-comments)) (overlays-in (point-min) (point-max))))
    (should (equal '("A paragraph that is gone") (mapcar (lambda (th) (plist-get (plist-get th :anchor) :quote)) (drgnx-doc-agents--orphans))))))

(ert-deftest drgnx-ui-doc-agents/writing-paragraph-pulses-unless-reduced-motion ()
  "The writer's paragraph pulses (one repeating timer, owned by the mode) and stops with reduced motion or the mode off."
  (drgnx-ui-doc-agents--with calls
    (drgnx-ui-doc-agents--line "Places: Work")
    (let ((line (line-number-at-pos)) (drgnx-reduced-motion nil))
      (drgnx-doc-agents-mark-writer line line 3 "C")
      (should (timerp drgnx-doc-agents--pulse-timer)))
    (let ((drgnx-reduced-motion t))
      (drgnx-ui-doc-agents--line "Each agent is a card")
      (let ((line (line-number-at-pos))) (drgnx-doc-agents-mark-writer line line 3 "C"))
      (should-not drgnx-doc-agents--pulse-timer))))

(provide 'doc-agents-gui-test)
;;; doc-agents-gui-test.el ends here
