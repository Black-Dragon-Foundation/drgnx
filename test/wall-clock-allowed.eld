;;; wall-clock-allowed.eld --- test files that still wait on a real time window  -*- mode: lisp-data -*-
;; (FILE :slice SLICE :why STRING) ...: a test file with a `drgnx-test-pause' (a real "did not happen" window) must be listed;
;; `drgnx-lint/real-pauses-are-registered' fails a file with a pause that is not here, and a row whose file has none (the list
;; only shrinks).  :slice names the slice of docs/plans/drgnx/2026-11-14-virtual-clocks.md that converts the file to the virtual
;; clock; "decided" is an exception that stays: a real process, terminal, daemon or window manager, whose window needs real time.
(
 ("test/unit/platform-test.el" :slice "decided" :why "the fake tool is a real process (swaymsg, hyprctl): its late line, its second call and its log are real time; the timer-only twins run on the clock")
 ("test/unit/wb-explorer-test.el" :slice "decided" :why "real file-notify events (inotify) arrive in real time: the window lets them in")
 ("test/unit/delivery-gate-test.el" :slice "decided" :why "tests that virtual time stands still while real time passes: the pause is its subject")
 ("test/unit/wait-fixture-test.el" :slice "decided" :why "tests the pause itself")
 ("test/tty/clipboard-test.el" :slice "decided" :why "a real terminal (a pty child): the bytes that may not arrive are a real terminal\'s")
 ("test/tty/fallback-test.el" :slice "decided" :why "a real terminal (a pty child): the bytes that may not arrive are a real terminal\'s")
 ("test/tty/frames-test.el" :slice "decided" :why "a real terminal (a pty child): the bytes that may not arrive are a real terminal\'s")
 ("test/tty/kitty-test.el" :slice "decided" :why "a real terminal (a pty child): the bytes that may not arrive are a real terminal\'s")
 ("test/tty/state-test.el" :slice "decided" :why "a real terminal (a pty child): the bytes that may not arrive are a real terminal\'s")
 ("test/tty/tmux-test.el" :slice "decided" :why "a real terminal (a pty child): the bytes that may not arrive are a real terminal\'s")
 ("test/ui/childframe-chrome-test.el" :slice "decided" :why "a real GUI session's draws: the window is a real compositor's")
 ("test/live/drgnx-modal-daemon-test.el" :slice "decided" :why "a real daemon: nothing may happen a moment later")
 ("test/live/drgnx-persist-first-client-test.el" :slice "decided" :why "a real daemon")
 ("test/live/drgnx-session-keep-or-quit-test.el" :slice "decided" :why "a real daemon")
 ("test/live/drgnx-wm-test.el" :slice "decided" :why "a real window manager")
 ("test/live/hub-daemon-start-test.el" :slice "decided" :why "a real daemon and hub")
 ("test/live/observer-test.el" :slice "decided" :why "a real session")
)
