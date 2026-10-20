;; Card `data' as the code that raises each kind of card builds it (drgnx-job.el, drgnx-job-clash.el,
;; drgnx-coord-mcp.el).
((:agent "agent-3" :rate 30)
 (:sid "agent-2" :request 5)
 (:sid "agent-2" :request 6 :message 11)
 (:review t)
 (:gate t :agent "agent-2")
 (:profile "claude" :message 12)
 (:key "overlap:1:2" :files ("a.el" "b.el"))
 (:key "against-decision:3" :rule "against-decision" :subject "the xml export" :size "long" :lines 240
  :sides ((:label "A" :text "#3 wont-build: the xml export" :decision 3 :agent "user" :task "t1" :reason "the plan says so")
          (:label "B" :text "keep the work"))
  :recommendation (:side "A" :why "it was first") :message 13)
 (:key "proposed:4" :rule "proposed" :subject "cache" :size "short"
  :sides ((:label "A" :text "record it" :decision 4) (:label "B" :text "leave it out" :decision 4))
  :recommendation (:side nil :why "neither") :no-recommendation t))
