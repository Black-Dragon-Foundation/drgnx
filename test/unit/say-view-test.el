;;; say-view-test.el --- the proposal view and the forecast line, pure -*- lexical-binding: t -*-
;; The renderer and the line take plain data (a forecast as the hub's JSON reads, a job summary) and insert text: no hub,
;; no clock, no timer.
;; test-class: det
(require 'ert)
(require 'cl-lib)
(require 'drgnx-say)

(defun drgnx-say-view-test--range (lo hi) (list :p50 lo :p90 hi))

(defun drgnx-say-view-test--task (n &optional cost)
  (list :n n :role "implement" :profile "sonnet"
        :basis (list :level "profile" :n 12 :other_model :false :calibrated :false
                     :label "12 implement tasks on sonnet")
        :tokens (drgnx-say-view-test--range 1000000 3000000)
        :active_secs (drgnx-say-view-test--range 600 1500)
        :cost cost))

(defun drgnx-say-view-test--usd-est (lo hi)
  (list (list :unit "usd-est" :p50 lo :p90 hi :estimate t)))

(defun drgnx-say-view-test--forecast (&rest extra)
  "A priced forecast of one task (12 to 41 USD estimate), with EXTRA keys put over it."
  (let ((f (list :tasks (list (drgnx-say-view-test--task 1 (drgnx-say-view-test--usd-est 12 41)))
                 :tokens (drgnx-say-view-test--range 2000000 6000000)
                 :active_secs (drgnx-say-view-test--range 600 1500)
                 :wall_secs (drgnx-say-view-test--range 1200 3000)
                 :cost (drgnx-say-view-test--usd-est 12 41)
                 :unpriced nil :pace nil :warnings nil :prices_as_of "2026-10-30" :made_at 1.0)))
    (while extra (setq f (plist-put f (pop extra) (pop extra))))
    f))

(defun drgnx-say-view-test--job ()
  (list :id "j1" :title "Settings review" :status "proposed" :budget 20.0
        :tasks (list (list :n 1 :title "Read the settings" :role "review" :profile "sonnet"
                           :status "proposed" :deps nil))))   ; the keys `job/status' really sends

(defun drgnx-say-view-test--text (forecast &optional job)
  (with-temp-buffer
    (drgnx-say--render forecast (or job (drgnx-say-view-test--job)))
    (buffer-string)))

(ert-deftest drgnx-say/view-shows-range-and-basis ()
  (let ((text (drgnx-say-view-test--text (drgnx-say-view-test--forecast))))
    (should (string-search "12–41 USD (estimate)" text))
    (should (string-search "12 implement tasks on sonnet" text))
    (should (string-search "2026-10-30" text))))

(ert-deftest drgnx-say/render-inserts-at-point ()
  (with-temp-buffer
    (insert "BEFORE\n")
    (let ((mid (point)))
      (insert "AFTER\n")
      (goto-char mid)
      (drgnx-say--render (drgnx-say-view-test--forecast) (drgnx-say-view-test--job))
      (should (string-prefix-p "BEFORE\n" (buffer-string)))
      (should (string-suffix-p "AFTER\n" (buffer-string)))
      (should (= (point) (save-excursion (goto-char (point-min)) (search-forward "AFTER") (match-beginning 0))))
      (should (= (count-matches "BEFORE" (point-min) (point-max)) 1)))))

(ert-deftest drgnx-say/forecast-line-is-one-line-and-never-zero ()
  (let ((line (drgnx-forecast-line (drgnx-say-view-test--forecast :cost (drgnx-say-view-test--usd-est 1.2 3.1)))))
    (should (equal line "about 1–3 USD (estimate), 2M–6M tokens, 20–50 min"))
    (should-not (string-search "\n" line)))
  (let ((line (drgnx-forecast-line (drgnx-say-view-test--forecast :cost nil :unpriced '("local")))))
    (should (equal line "about 2M–6M tokens, 20–50 min"))
    (should-not (string-search "0.00" line))))

(ert-deftest drgnx-say/view-unpriced-never-prints-zero ()
  (let ((text (drgnx-say-view-test--text
               (drgnx-say-view-test--forecast
                :cost nil :unpriced '("local")
                :tasks (list (drgnx-say-view-test--task 1 nil))))))
    (should-not (string-search "0.00" text))
    (should (string-search "not priced" text))
    (should (string-search "local" text))))

(ert-deftest drgnx-say/view-shows-the-wake-as-of-which ()
  (let ((text (drgnx-say-view-test--text
               (drgnx-say-view-test--forecast
                :wake (list :cold_wakes (drgnx-say-view-test--range 1 3)
                            :cost (list (list :unit "usd-est" :p50 3.0 :p90 5.0 :estimate :false)))))))
    (should (string-search "of which wakes: 1–3 cold, about 3 USD" text))))

(ert-deftest drgnx-say/view-shows-the-manager-beside-the-total ()
  (let ((text (drgnx-say-view-test--text
               (drgnx-say-view-test--forecast
                :manager (list :n 0 :role "manager" :profile "sonnet"
                               :basis (list :level "role" :n 4 :label "4 manager runs")
                               :tokens (drgnx-say-view-test--range 100000 300000)
                               :active_secs (drgnx-say-view-test--range 60 120)
                               :cost (drgnx-say-view-test--usd-est 2 4))))))
    (should (string-match "[Mm]anager[^\n]*2–4 USD (estimate)[^\n]*beside the total" text))))

(ert-deftest drgnx-say/view-shows-the-pace-effect ()
  (let* ((thu (float-time (encode-time 0 0 12 5 11 2026)))
         (wed (float-time (encode-time 0 0 12 4 11 2026)))
         (text (drgnx-say-view-test--text
                (drgnx-say-view-test--forecast
                 :pace (list (list :provider "claude" :used_share 0.4 :window "week" :estimate t :runs_out_p90 :false
                                   :added_share (drgnx-say-view-test--range 0.05 0.1)
                                   :exhausted_at thu :exhausted_after wed))))))
    (should (string-search "at this pace: Thursday; with this plan: Wednesday (estimate)" text))))

(ert-deftest drgnx-say/view-marks-agent-written-text ()
  (let* ((text (drgnx-say-view-test--text (drgnx-say-view-test--forecast)))
         (label (string-search "Written by the planning agent" text)))
    (should label)
    (dolist (s '("Settings review" "1. Read the settings"))
      (should (> (string-search s text label) label)))
    ;; the hub's facts come before the agent's text
    (should (< (string-search "12–41 USD" text) label))))

(ert-deftest drgnx-say/view-says-no-pace-yet ()
  (let ((text (drgnx-say-view-test--text
               (drgnx-say-view-test--forecast
                :pace (list (list :provider "claude" :used_share 0.2 :window "week" :estimate t :runs_out_p90 :false))))))
    (should (string-search "no pace yet" text))))

(ert-deftest drgnx-say/view-says-a-budget-binds-the-estimate ()
  ;; a plan with a subscription's (estimated) cost: the budget binds the estimate too, and the line says so
  (let ((text (drgnx-say-view-test--text (drgnx-say-view-test--forecast))))
    (should (string-match "^Budget: 20 USD[^\n]*estimate" text)))
  ;; a gateway-only plan's budget is exact
  (let ((text (drgnx-say-view-test--text
               (drgnx-say-view-test--forecast :cost (list (list :unit "usd" :p50 1.0 :p90 2.0 :estimate :false))))))
    (should (string-match "^Budget: 20 USD$" text))))

(ert-deftest drgnx-say/view-without-a-status-does-not-say-proposed ()
  ;; `job/status' failed: the view has no summary, and does not guess the job's status
  (let ((text (with-temp-buffer (drgnx-say--render (drgnx-say-view-test--forecast) nil) (buffer-string))))
    (should-not (string-search "proposed" text))
    (should (string-match "^Status: not known" text))))

(ert-deftest drgnx-say/every-command-is-registered-and-interactive ()
  (let ((drgnx-commands--table (make-hash-table :test #'eq)) (drgnx-commands--order nil))
    (drgnx-say-register-commands)
    (dolist (fn '(drgnx-say drgnx-say-show drgnx-say-approve drgnx-say-revise drgnx-say-reject drgnx-say-answer
                            drgnx-forecast-accuracy))
      (should (commandp fn))
      (should (cl-find fn (drgnx-commands-all) :key #'drgnx-cmd-command)))))

;;; say-view-test.el ends here
