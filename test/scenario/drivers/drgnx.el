;;; drgnx.el --- Scenario driver for drgnx -*- lexical-binding: t -*-
;; SPDX-License-Identifier: GPL-3.0-or-later
;; The workbench (Explorer, Buffers panel, docks) is built in M3; until then every scenario
;; that needs it is skipped.

(defun drgnx-driver-reset ()
  (ert-skip "the drgnx workbench (Explorer, Buffers panel) arrives in M3"))
