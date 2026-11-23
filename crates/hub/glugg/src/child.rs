//! Whether a program runs in the terminal (the quit question; docs/develop/terminal.md, "Lifetime"): from the shell's
//! OSC 133 marks when it sends them (C: a command's output starts; A, B, D: back at the prompt), else whether the shell
//! has a child process.

/// The OSC 133 state: none until the shell sends a mark.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct Marks {
    running: Option<bool>,
}

impl Marks {
    /// A mark of KIND (1 prompt start, 2 input start, 3 output start, 4 command end).
    pub fn mark(&mut self, kind: i32) {
        self.running = Some(kind == 3);
    }

    /// Whether a program runs, SHELL_PID being the shell.
    pub fn running(&self, shell_pid: u32) -> bool {
        self.running.unwrap_or_else(|| has_children(shell_pid))
    }
}

/// Whether PID has a child process.
#[cfg(target_os = "linux")]
pub fn has_children(pid: u32) -> bool {
    std::fs::read_to_string(format!("/proc/{pid}/task/{pid}/children"))
        .is_ok_and(|s| !s.trim().is_empty())
}

/// Whether PID has a child process.
#[cfg(target_os = "macos")]
pub fn has_children(pid: u32) -> bool {
    let mut pids = [0 as libc::pid_t; 16];
    // SAFETY: the buffer and its size in bytes.
    let n = unsafe {
        libc::proc_listchildpids(
            pid as libc::pid_t,
            pids.as_mut_ptr().cast(),
            std::mem::size_of_val(&pids) as i32,
        )
    };
    n > 0
}

/// Whether PID has a child process (unknown here: no).
#[cfg(not(any(target_os = "linux", target_os = "macos")))]
pub fn has_children(_pid: u32) -> bool {
    false
}
