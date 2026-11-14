;;; hub-client-frame-test.el --- the hub client's framed lines give the core the events the hub wrote -*- lexical-binding: t -*-
;; test-class: det
;; Pattern D (pure): no process.  Nidhogg's real framer (`nidhogg-workers--test-frame', the reader's own code) cuts
;; recorded hub streams into messages; `drgnx-hub--client-batch' turns them into the core's events.  Every hub connection
;; is framed: there is no filter that reads a line in Lisp.
(require 'ert)
(require 'cl-lib)
(require 'drgnx-paths)
(require 'drgnx-hub-client)

(defconst drgnx-hub-client-frame-test--stream
  (concat "{\"event\":\"challenge\",\"data\":{\"nonce\":\"né\"}}\n"
          "\n"
          "not json at all\n"
          "null\n"
          "{\"id\":1,\"result\":{\"text\":\"日本 \U0001F409\"}}\r\n"
          "{\"event\":\"notice\",\"data\":{\"a\":[1,2,3]}}\n")
  "A hub stream: non-ASCII, an empty line, a non-JSON line, a null line, CRLF.")

(defun drgnx-hub-client-frame-test--chunks (string seed)
  "STRING's UTF-8 bytes cut into chunks at positions from SEED (any byte, also inside a character)."
  (let* ((bytes (encode-coding-string string 'utf-8 t)) (n (length bytes)) (i 0) out)
    (while (< i n)
      (setq seed (mod (+ (* seed 1103515245) 12345) 2147483648))
      (let ((len (1+ (mod (ash seed -8) 17))))
        (push (substring bytes i (min n (+ i len))) out)
        (setq i (+ i len))))
    (nreverse out)))

(defun drgnx-hub-client-frame-test--require-raw-prefix ()
  "Skip without Nidhogg's reader; on one older than `:raw-to-sja' (the reader's push to Sjá, `nidhogg-view--pushed':
an older nh-io refuses the keyword, and the client then stays unframed), skip by name, or fail on the line (strict)."
  (unless (fboundp 'nidhogg-workers--test-frame) (ert-skip "no Nidhogg reader (nidhogg-workers--test-frame)"))
  (require 'nidhogg-views nil t)
  (drgnx-test-require-nidhogg (fboundp 'nidhogg-view--pushed) ":raw-to-sja framing (nidhogg-view--pushed)"))

(defun drgnx-hub-client-frame-test--framed (chunks eof)
  "The events `drgnx-hub--client-batch' passes on for CHUNKS framed by Nidhogg's reader, as `drgnx-hub--frame' frames
them; a `view-model' line, which the reader pushes to Sjá, as (:pushed . SJÁ'S-ANSWER)."
  (let (got)
    (cl-letf (((symbol-function 'drgnx-hub--client-line) (lambda (_conn json) (push json got)))
              ((symbol-function 'drgnx-view-model--pushed) (lambda (r) (push (cons :pushed r) got))))
      (drgnx-hub--client-batch
       nil (car (nidhogg-workers--test-frame chunks eof 'lines :parse 'string :object-type 'plist
                                             :array-type 'list :null-object nil :false-object nil
                                             :raw-prefix drgnx-hub--model-prefix :raw-to-sja t))))
    (nreverse got)))

(defconst drgnx-hub-client-frame-test--model-line
  "{\"event\":\"view-model\",\"data\":{\"base\":0,\"hub\":1,\"model\":{\"ops\":[{\"remove\":[\"é\U0001F409\"]}]},\"reset\":true,\"version\":1,\"view\":\"v\"}}"
  "A hub's `view-model' line, non-ASCII inside.")

(defvar drgnx-hub-client-frame-test--parsed 0 "Calls of `json-parse-string' on a `view-model' line.")

(defun drgnx-hub-client-frame-test--count-parse (fn string &rest args)
  (when (string-prefix-p drgnx-hub--model-prefix string) (cl-incf drgnx-hub-client-frame-test--parsed))
  (apply fn string args))

(ert-deftest drgnx-hub-client-frame/a-view-model-line-goes-unparsed-to-sja ()
  "A `view-model' line between other events, cut anywhere (split over many chunks): the reader pushes it to Sjá itself
\(its answer comes, never the line as a string), in its place among the events, and nothing parses it in Lisp."
  (drgnx-hub-client-frame-test--require-raw-prefix)
  (let ((stream (concat "{\"event\":\"notice\",\"data\":{\"a\":1}}\n" drgnx-hub-client-frame-test--model-line "\n"
                        "{\"id\":3,\"result\":true}\n"))
        (drgnx-hub-client-frame-test--parsed 0))
    (advice-add 'json-parse-string :around #'drgnx-hub-client-frame-test--count-parse)
    (unwind-protect
        (dolist (seed '(1 7 42 1000 31337))
          (let ((chunks (drgnx-hub-client-frame-test--chunks stream seed))
                (want (lambda (model) (list '(:event "notice" :data (:a 1)) model '(:id 3 :result t)))))
            (should (> (length chunks) 3))
            ;; no instance of view "v" is open: Sjá answers `none' for it
            (should (equal (funcall want '(:pushed "v" 1 none)) (drgnx-hub-client-frame-test--framed chunks t)))))
      (advice-remove 'json-parse-string #'drgnx-hub-client-frame-test--count-parse))
    (should (= 0 drgnx-hub-client-frame-test--parsed))))

(ert-deftest drgnx-hub-client-frame/frames-with-the-model-prefix-pushed-to-sja ()
  "The reader is asked to push a `view-model' line to Sjá itself: there is no framing that hands it to Lisp."
  (let (args)
    (cl-letf (((symbol-function 'nidhogg-set-process-framing) (lambda (&rest a) (setq args a))))
      (drgnx-hub--frame 'conn))
    (should (equal drgnx-hub--model-prefix (plist-get (cddr args) :raw-prefix)))
    (should (eq t (plist-get (cddr args) :raw-to-sja)))))

(ert-deftest drgnx-hub-client-frame/a-pushed-model-line-reaches-its-view-in-order ()
  "An entry the reader pushed to Sjá, (ANSWER sja nil), goes to `drgnx-view-model--pushed' with the decision as a
symbol, in its place among the events."
  (let (got)
    (cl-letf (((symbol-function 'drgnx-hub--client-line) (lambda (_c j) (push j got)))
              ((symbol-function 'nidhogg-view--pushed) (lambda (r) (list (nth 0 r) (nth 1 r) 'queue)))
              ((symbol-function 'drgnx-view-model--pushed) (lambda (r) (push (cons 'pushed r) got))))
      (drgnx-hub--client-batch nil '(((:id 1) "" nil) (("v" 3 0) sja nil) ((:id 2) "" nil))))
    (should (equal (nreverse got) '((:id 1) (pushed "v" 3 queue) (:id 2))))))

(ert-deftest drgnx-hub-client-frame/a-refused-push-is-reported ()
  "Sjá refused a line the reader pushed, (nil sja ERROR): the error is reported as a failed `nidhogg-view-push' is,
through the connection's guard, and the batch goes on."
  (let (got recorded)
    (cl-letf (((symbol-function 'drgnx-hub--client-line) (lambda (_c j) (push j got)))
              ((symbol-function 'drgnx-view-model--pushed) (lambda (r) (push (cons 'pushed r) got)))
              ((symbol-function 'drgnx-guard--record) (lambda (label err) (push (cons label err) recorded))))
      (drgnx-hub--client-batch nil '((nil sja (error "Sjá refused a model line (-1)")) ((:id 2) "" nil))))
    (should (equal got '((:id 2))))
    (should (equal recorded '(("hub connection" error "Sjá refused a model line (-1)"))))))

(ert-deftest drgnx-hub-client-frame/the-events-the-hub-wrote ()
  (drgnx-hub-client-frame-test--require-raw-prefix)
  (dolist (seed '(1 7 42 1000 31337))
    (let* ((chunks (drgnx-hub-client-frame-test--chunks drgnx-hub-client-frame-test--stream seed))
           (framed (drgnx-hub-client-frame-test--framed chunks t)))
      (should (= 3 (length framed)))
      (should (equal (plist-get (plist-get (nth 1 framed) :result) :text) "日本 \U0001F409")))))

(ert-deftest drgnx-hub-client-frame/eof-without-newline ()
  "A last line with no newline when the stream ends is a message (the reader flushes it at the end)."
  (drgnx-hub-client-frame-test--require-raw-prefix)
  (let ((chunks (list "{\"id\":2,\"result\":{}}")))
    (should (equal (drgnx-hub-client-frame-test--framed chunks t) '((:id 2 :result nil))))
    (should (null (drgnx-hub-client-frame-test--framed chunks nil)))
    ))

(ert-deftest drgnx-hub-client-frame/stops-after-close ()
  (let (got (conn (make-symbol "dead")))
    ;; dead before the batch began: the batch is still read
    (cl-letf (((symbol-function 'process-live-p) (lambda (_) nil))
              ((symbol-function 'drgnx-hub--client-line) (lambda (_c j) (push j got))))
      (drgnx-hub--client-batch conn '(((:id 1) "" nil))))
    (should (equal got '((:id 1))))
    ;; live at the start, deleted by the first message: the second reaches nothing
    (setq got nil)
    (let ((live (make-symbol "live")))
      (cl-letf (((symbol-function 'process-live-p) (lambda (c) (and (eq c live) (null got))))
                ((symbol-function 'drgnx-hub--client-line) (lambda (_c j) (push j got))))
        (drgnx-hub--client-batch live '(((:id 1) "" nil) ((:id 2) "" nil)))))
    (should (equal got '((:id 1))))))

(ert-deftest drgnx-hub-client-frame/one-bad-message-keeps-the-rest ()
  (let (got)
    (cl-letf (((symbol-function 'drgnx-hub--client-line)
               (lambda (_c j) (if (eql (plist-get j :id) 1) (error "boom") (push j got)))))
      (drgnx-hub--client-batch nil '(((:id 1) "" nil) ((:id 2) "" nil))))
    (should (equal got '((:id 2))))))

(ert-deftest drgnx-hub-client-frame/every-connection-is-framed ()
  "`drgnx-hub--frame' frames whatever `nidhogg-workers-framing' says: it is the only way a hub's lines are read."
  (dolist (switch '(nil t))
    (let (args (nidhogg-workers-framing switch))
      (cl-letf (((symbol-function 'nidhogg-set-process-framing) (lambda (&rest a) (setq args a))))
        (drgnx-hub--frame 'conn))
      (should (eq (nth 1 args) 'lines))
      (should-not (memq :max-message args)))))

(ert-deftest drgnx-hub-client-frame/a-framing-that-fails-is-signalled ()
  "There is no unframed fallback: a connection nothing reads is an error."
  (cl-letf (((symbol-function 'nidhogg-set-process-framing) (lambda (&rest _) (error "no framing"))))
    (should-error (drgnx-hub--frame 'conn))))

(ert-deftest drgnx-hub-client-frame/no-line-is-parsed-by-a-filter ()
  "The unframed reader is gone: no splitter and no client filter, so no `json-parse-string' on the main thread for a hub
line."
  (should-not (fboundp 'drgnx-hub--lines))
  (should-not (fboundp 'drgnx-hub--client-filter))
  (should-not (fboundp 'drgnx-hub--model-line-p)))

;;; hub-client-frame-test.el ends here
