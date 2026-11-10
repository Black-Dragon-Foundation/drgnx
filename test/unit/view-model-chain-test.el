;;; view-model-chain-test.el --- batch test: Sjá's chain class equals the hub's chain on the 30-agent fixture -*- lexical-binding: t -*-
;; test-class: det
;; Needs Sjá (a Nidhogg with `nidhogg-view--call'); skipped elsewhere.  Pattern D: pure, over a golden.
;; test/fixtures/work-space/model-thirty.json is the map's model of the 30-agent fixture as the hub sends it, and
;; `vegvisir::Model::chain' of every item it shows, written by the hub's own test (work::map::tests,
;; `chain_golden_matches_vegvisir', UPDATE_VEGVISIR_GOLDEN=1).  The replica is checked through the Nidhogg binary,
;; never through a cargo path between the repos.
(require 'ert)
(require 'cl-lib)
(require 'seq)
(require 'subr-x)
(require 'drgnx-paths)

(ert-deftest drgnx-view-model/chain-matches-vegvisir ()
  "Pattern D: with each shown item selected in turn, the nodes Sjá classes `chain' are exactly that item's chain in
vegvisir (up and down), and the selected node is `selected'."
  (require 'nidhogg-views nil t)        ; the doors are Lisp, not preloaded
  (drgnx-test-require-nidhogg (fboundp 'nidhogg-view-push) "nidhogg-view-push")
  (let* ((golden (with-temp-buffer
                   (insert-file-contents (expand-file-name "test/fixtures/work-space/model-thirty.json" drgnx-dir))
                   (json-parse-buffer :object-type 'hash-table :array-type 'list)))
         (chains (gethash "chains" golden))
         (view "vmc-test-thirty")
         (h nil))
    (setq h (nidhogg-view-open view))   ; Sjá queues a view's model only while an instance shows it
    (unwind-protect
        (let* ((_pushed (should (eq 'reset (nth 2 (nidhogg-view-push
                                                   (concat "{\"event\":\"view-model\",\"data\":{\"view\":\"" view
                                                           "\",\"hub\":1,\"base\":0,\"version\":1,\"reset\":true,\"model\":"
                                                           (gethash "model" golden) "}}"))))))
               (_drained (should (eql 1 (car (nidhogg-view-drain view)))))
               (names (nidhogg-view-get h 'class-names))
               (chain (cl-position "chain" names :test #'equal))
               (selected (cl-position "selected" names :test #'equal))
               (ids (hash-table-keys chains))
               (wrong nil))
          (should (>= (length ids) 30))                   ; the premise: the fixture's thirty agents at least
          (dolist (sel ids)
            (nidhogg-view-set h 'select sel)
            (let ((want (gethash sel chains)))
              (dolist (id ids)
                (let ((class (nidhogg-view-get h 'class id)))
                  (cond ((equal id sel) (unless (eql class selected) (push (list sel id class) wrong)))
                        ((member id want) (unless (eql class chain) (push (list sel id class) wrong)))
                        ((eql class chain) (push (list sel id class) wrong)))))))
          (should (equal nil (seq-take (nreverse wrong) 10))))
      (nidhogg-view-close h))))

;;; view-model-chain-test.el ends here
