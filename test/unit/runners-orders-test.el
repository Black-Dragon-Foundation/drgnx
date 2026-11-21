;;; runners-orders-test.el --- runner cards against the hub's events and the user's answers, in every order -*- lexical-binding: t -*-
;; test-class: det
;; Pattern A (every order): the cards are a function of a pure state the three sources feed: the hub's `runners-changed'
;; lists, the hub's `runners/need-keys' asks and the user's key hand-overs.  The oracle is independent of the core: it
;; reads the order itself.
(require 'ert)
(require 'cl-lib)
(require 'seq)
(require 'drgnx)
(load (expand-file-name "modules/tools/drgnx-runners-view" drgnx-dir) nil t)
(load (expand-file-name "modules/tools/drgnx-runners" drgnx-dir) nil t)
(load (expand-file-name "test/fixtures/orders-fixture" drgnx-dir) nil t)

(defconst runners-orders-test--ready
  '(:name "desktop" :host "desk" :trust "mine" :state "ready"))
(defconst runners-orders-test--login
  '(:name "desktop" :host "desk" :trust "mine" :state "needs a login: ssh desk true"))
(defconst runners-orders-test--benched
  '(:name "desktop" :host "desk" :trust "mine" :state "benched: image pull failed twice (14:02, 14:20)"))

(defun runners-orders-test--oracle (events)
  "The card texts EVENTS (an order) must leave, worked out without the core: the last `runners' event's runner, and the
names whose last ask came after their last hand-over."
  (let* ((runner (or (cl-some (lambda (e) (and (eq (car e) 'runners) (car (cadr e)))) (reverse events))))
         (asked nil))
    (dolist (e events)
      (pcase (car e)
        ('need (dolist (n (cadr e)) (cl-pushnew n asked :test #'equal)))
        ('sent (dolist (n (cadr e)) (setq asked (delete n asked))))))
    (append (when (and runner (string-prefix-p "needs a login" (plist-get runner :state)))
              (list "Log in to desktop: run `ssh desk true` in a terminal"))
            (when (and runner (string-prefix-p "benched" (plist-get runner :state)))
              (list "desktop benched: image pull failed twice (14:02, 14:20)"))
            (when asked (list "needs your keys: run Runners: Load Keys")))))

(defun runners-orders-test--texts (state)
  (mapcar (lambda (c) (plist-get c :text)) (drgnx-runners-cards state)))

(ert-deftest drgnx-runners-orders/need-keys-then-settle-in-any-order ()
  "Pattern A: a key card stands exactly while some ask came after the last hand-over of its name; a login or benched card
stands exactly while the last list says so."
  (let ((seen-key nil) (seen-none nil))
    (drgnx-test-every-order
     :kinds '(runners need sent)
     :sources (list (cons 'hub (list (list 'runners (list runners-orders-test--login))
                                     (list 'runners (list runners-orders-test--ready))))
                    (cons 'hub-again (list (list 'runners (list runners-orders-test--benched))))
                    (cons 'asks (list '(need ("A")) '(need ("B"))))
                    (cons 'user (list '(sent ("A")) '(sent ("A" "B")))))
     :init #'drgnx-runners-state
     :step (lambda (st ev) (cons (drgnx-runners-step st ev) nil))
     :check (lambda (st order)
              (let ((want (runners-orders-test--oracle order)) (got (runners-orders-test--texts st)))
                (if (string-search "keys" (string-join want)) (setq seen-key t) (setq seen-none t))
                (unless (equal (sort (copy-sequence want) #'string<) (sort (copy-sequence got) #'string<))
                  (format "wanted %S, got %S" want got)))))
    (should seen-key)
    (should seen-none)))

(ert-deftest drgnx-runners-orders/no-room-is-a-card ()
  "Pattern D: a runner whose floor and reserve leave no room for jobs is a card with the hub's words (the numbers and the
ways out); the card goes once a list says there is room."
  (let* ((why "mac has no room for jobs: 5376 MiB available")
         (st (drgnx-runners-step (drgnx-runners-state)
                                 (list 'runners (list (list :name "mac" :state "ready" :no_room why))))))
    (should (equal (runners-orders-test--texts st) (list why)))
    (should (equal (plist-get (car (drgnx-runners-cards st)) :id) '(no-room "mac")))
    (setq st (drgnx-runners-step st (list 'runners (list (list :name "mac" :state "ready")))))
    (should-not (runners-orders-test--texts st))))

(provide 'runners-orders-test)
;;; runners-orders-test.el ends here
