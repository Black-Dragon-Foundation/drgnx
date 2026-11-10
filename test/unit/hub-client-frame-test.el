;;; hub-client-frame-test.el --- the hub client's framed lines give the core the events its filter gives -*- lexical-binding: t -*-
;; test-class: det
;; Pattern D (pure): no process.  Nidhogg's real framer (`nidhogg-workers--test-frame', the reader's own code) cuts
;; recorded hub streams into messages; `drgnx-hub--client-batch' turns them into the core's events, and
;; `drgnx-hub--lines' (the filter's splitter) does the same for the unframed path.  Both must agree.
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

(defun drgnx-hub-client-frame-test--raw (line)
  "(:raw BYTES): LINE as Sjá reads it, its UTF-8 bytes (a unibyte line is already that)."
  (list :raw (if (multibyte-string-p line) (encode-coding-string line 'utf-8 t) line)))

(defun drgnx-hub-client-frame-test--require-raw-prefix ()
  "Skip without Nidhogg's reader; on one older than `:raw-prefix' (it came with Sjá's queue, `nidhogg-view-push': an
older nh-io refuses the keyword, and the client then stays unframed), skip by name, or fail on the line (strict)."
  (unless (fboundp 'nidhogg-workers--test-frame) (ert-skip "no Nidhogg reader (nidhogg-workers--test-frame)"))
  (require 'nidhogg-views nil t)
  (drgnx-test-require-nidhogg (fboundp 'nidhogg-view-push) ":raw-prefix framing (with nidhogg-view-push)"))

(defun drgnx-hub-client-frame-test--framed (chunks eof)
  "The events `drgnx-hub--client-batch' passes on for CHUNKS framed by Nidhogg's reader, as `drgnx-hub--frame' frames
them; a `view-model' line as (:raw LINE)."
  (let (got)
    (cl-letf (((symbol-function 'drgnx-hub--client-line) (lambda (_conn json) (push json got)))
              ((symbol-function 'drgnx-hub--model-line)
               (lambda (line) (push (drgnx-hub-client-frame-test--raw line) got))))
      (drgnx-hub--client-batch
       nil (car (nidhogg-workers--test-frame chunks eof 'lines :parse 'string :object-type 'plist
                                             :array-type 'list :null-object nil :false-object nil
                                             :raw-prefix drgnx-hub--model-prefix))))
    (nreverse got)))

(defun drgnx-hub-client-frame-test--unframed (chunks)
  "The same through the filter's splitter, as the client's filter calls it."
  (let (got (conn (make-symbol "conn")))
    (cl-letf (((symbol-function 'process-live-p) (lambda (_) nil))
              (process-get-table (make-hash-table)))
      (cl-letf (((symbol-function 'process-get) (lambda (_c k) (gethash k process-get-table)))
                ((symbol-function 'process-put) (lambda (_c k v) (puthash k v process-get-table))))
        (dolist (c chunks)
          (drgnx-hub--lines conn c (lambda (j) (push j got)) nil nil
                            (lambda (line) (push (drgnx-hub-client-frame-test--raw line) got))))))
    (nreverse got)))

(defconst drgnx-hub-client-frame-test--model-line
  "{\"event\":\"view-model\",\"data\":{\"base\":0,\"hub\":1,\"model\":{\"ops\":[{\"remove\":[\"é\U0001F409\"]}]},\"reset\":true,\"version\":1,\"view\":\"v\"}}"
  "A hub's `view-model' line, non-ASCII inside.")

(defvar drgnx-hub-client-frame-test--parsed 0 "Calls of `json-parse-string' on a `view-model' line.")

(defun drgnx-hub-client-frame-test--count-parse (fn string &rest args)
  (when (string-prefix-p drgnx-hub--model-prefix string) (cl-incf drgnx-hub-client-frame-test--parsed))
  (apply fn string args))

(ert-deftest drgnx-hub-client-frame/a-view-model-line-goes-whole-and-unparsed-both-ways ()
  "A `view-model' line between other events, cut anywhere (split over many chunks on the unframed path): both paths
hand it whole to the model, in its place among the events, and neither parses it."
  (drgnx-hub-client-frame-test--require-raw-prefix)
  (let ((stream (concat "{\"event\":\"notice\",\"data\":{\"a\":1}}\n" drgnx-hub-client-frame-test--model-line "\n"
                        "{\"id\":3,\"result\":true}\n"))
        (drgnx-hub-client-frame-test--parsed 0))
    (advice-add 'json-parse-string :around #'drgnx-hub-client-frame-test--count-parse)
    (unwind-protect
        (dolist (seed '(1 7 42 1000 31337))
          (let* ((chunks (drgnx-hub-client-frame-test--chunks stream seed))
                 (want (list '(:event "notice" :data (:a 1))
                             (drgnx-hub-client-frame-test--raw drgnx-hub-client-frame-test--model-line)
                             '(:id 3 :result t))))
            (should (> (length chunks) 3))
            (should (equal want (drgnx-hub-client-frame-test--unframed chunks)))
            (should (equal want (drgnx-hub-client-frame-test--framed chunks t)))))
      (advice-remove 'json-parse-string #'drgnx-hub-client-frame-test--count-parse))
    (should (= 0 drgnx-hub-client-frame-test--parsed))))

(ert-deftest drgnx-hub-client-frame/frames-with-the-model-prefix ()
  (let (args (nidhogg-workers-framing t))
    (cl-letf (((symbol-function 'nidhogg-set-process-framing) (lambda (&rest a) (setq args a))))
      (drgnx-hub--frame 'conn))
    (should (equal drgnx-hub--model-prefix (plist-get (cddr args) :raw-prefix)))))

(ert-deftest drgnx-hub-client-frame/same-events-both-ways ()
  (drgnx-hub-client-frame-test--require-raw-prefix)
  (dolist (seed '(1 7 42 1000 31337))
    (let ((chunks (drgnx-hub-client-frame-test--chunks drgnx-hub-client-frame-test--stream seed)))
      (let ((framed (drgnx-hub-client-frame-test--framed chunks t))
            (plain (drgnx-hub-client-frame-test--unframed chunks)))
        (should (= 3 (length plain)))
        (should (equal framed plain))
        (should (equal (plist-get (plist-get (nth 1 framed) :result) :text) "日本 \U0001F409"))))))

(ert-deftest drgnx-hub-client-frame/eof-without-newline ()
  "A last line with no newline when the stream ends: framed, it is a message (the reader flushes it at the end);
the filter drops it, as it always did.  Pinned so a change of either side shows."
  (drgnx-hub-client-frame-test--require-raw-prefix)
  (let ((chunks (list "{\"id\":2,\"result\":{}}")))
    (should (equal (drgnx-hub-client-frame-test--framed chunks t) '((:id 2 :result nil))))
    (should (null (drgnx-hub-client-frame-test--framed chunks nil)))
    (should (null (drgnx-hub-client-frame-test--unframed chunks)))))

(ert-deftest drgnx-hub-client-frame/stops-after-close ()
  (let (got (conn (make-symbol "dead")))
    ;; dead before the batch began: like `drgnx-hub--lines', the batch is still read
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

(ert-deftest drgnx-hub-client-frame/off-without-switch ()
  (let (called (nidhogg-workers-framing nil))
    (cl-letf (((symbol-function 'nidhogg-set-process-framing) (lambda (&rest _) (setq called t))))
      (drgnx-hub--frame 'conn))
    (should-not called)))

(ert-deftest drgnx-hub-client-frame/off-without-feature ()
  (let (called (nidhogg-workers-framing t))
    (cl-letf (((symbol-function 'nidhogg-set-process-framing) nil))
      (should-not (fboundp 'nidhogg-set-process-framing))
      (drgnx-hub--frame 'conn)
      (setq called (fboundp 'nidhogg-set-process-framing)))
    (should-not called)))

(ert-deftest drgnx-hub-client-frame/on-with-switch-and-error-falls-back ()
  (let (args (nidhogg-workers-framing t))
    (cl-letf (((symbol-function 'nidhogg-set-process-framing)
               (lambda (&rest a) (setq args a) (signal 'nidhogg-framing-unsupported nil))))
      (drgnx-hub--frame 'conn))
    (should (eq (nth 1 args) 'lines))
    (should-not (memq :max-message args))))

;;; hub-client-frame-test.el ends here
