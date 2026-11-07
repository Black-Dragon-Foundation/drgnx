//! libghostty-vt behind a safe face: one `Terminal`, its `RenderState`, the row and cell iterators and the key and
//! mouse encoders, all owned by the worker's one thread (none of them is thread-safe). The engine's effects (pty
//! replies, bell, title, pwd, clipboard, notifications, progress, prompts, the synchronized-output hold) land in a
//! [`Sink`] the worker drains after each write.

use crate::style::{Cell, Wide, colour_of};
use drgnx_rows::{CursorShape, Style};
use ghostty_vt_sys::bindings::*;
use std::ffi::c_void;
use std::ptr::{null, null_mut};

pub use crate::rows::RowId;

/// One effect of the program's output, in order.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Effect {
    Bell,
    Title,
    Pwd,
    /// OSC 52 and kin: the program wrote the clipboard (allowed by the setting; else denied and not reported).
    Clipboard {
        primary: bool,
        mime: String,
        data: String,
    },
    Notify {
        title: String,
        body: String,
    },
    /// OSC 9;4: STATE 0 remove, 1 set, 2 error, 3 indeterminate, 4 pause; VALUE 0–100 or -1.
    Progress {
        state: i32,
        value: i32,
    },
    /// OSC 133: a prompt starts (A), input starts (B), output starts (C), the command ended (D, with its exit code).
    Prompt {
        kind: i32,
        exit: Option<i32>,
    },
    /// Mode 2026: the program holds (true) or releases its output.
    Hold(bool),
}

/// Where the engine's callbacks write. Boxed, so its address is stable for the callbacks' userdata.
#[derive(Debug, Default)]
pub struct Sink {
    /// Bytes the terminal answers the program with (device reports, DECRQM, ...), for the PTY.
    pub pty: Vec<u8>,
    pub effects: Vec<Effect>,
    /// Whether programs may write the clipboard (`drgnx-term-clipboard-write`).
    pub clipboard_write: bool,
    pub size: GhosttySizeReportSize,
}

/// The cursor as the frame sees it.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Cursor {
    /// `(x, y)` in the viewport, when it is in it.
    pub at: Option<(u16, u16)>,
    pub visible: bool,
    pub shape: CursorShape,
}

pub struct Engine {
    term: GhosttyTerminal,
    rs: GhosttyRenderState,
    rows: GhosttyRenderStateRowIterator,
    cells: GhosttyRenderStateRowCells,
    kenc: GhosttyKeyEncoder,
    kev: GhosttyKeyEvent,
    menc: GhosttyMouseEncoder,
    mev: GhosttyMouseEvent,
    sink: Box<Sink>,
    palette: [[u8; 3]; 256],
    cols: u16,
    rows_n: u16,
    cell: (u32, u32),
}

fn ok(rc: GhosttyResult, what: &str) -> Result<(), String> {
    if rc == GHOSTTY_SUCCESS {
        Ok(())
    } else {
        Err(format!("{what}: libghostty-vt error {rc}"))
    }
}

fn string(s: GhosttyString) -> String {
    if s.ptr.is_null() || s.len == 0 {
        return String::new();
    }
    // SAFETY: the library hands a borrowed (ptr, len) byte string valid for the call.
    String::from_utf8_lossy(unsafe { std::slice::from_raw_parts(s.ptr, s.len) }).into_owned()
}

/// SAFETY (all callbacks): USERDATA is the `Sink` the engine was given (`GHOSTTY_TERMINAL_OPT_USERDATA`), alive as
/// long as the terminal, and only this thread calls into the terminal.
unsafe fn sink<'a>(userdata: *mut c_void) -> &'a mut Sink {
    unsafe { &mut *(userdata as *mut Sink) }
}

unsafe extern "C" fn on_write_pty(_: GhosttyTerminal, u: *mut c_void, data: *const u8, len: usize) {
    if !data.is_null() {
        unsafe {
            sink(u)
                .pty
                .extend_from_slice(std::slice::from_raw_parts(data, len))
        };
    }
}
unsafe extern "C" fn on_bell(_: GhosttyTerminal, u: *mut c_void) {
    unsafe { sink(u).effects.push(Effect::Bell) };
}
unsafe extern "C" fn on_title(_: GhosttyTerminal, u: *mut c_void) {
    unsafe { sink(u).effects.push(Effect::Title) };
}
unsafe extern "C" fn on_pwd(_: GhosttyTerminal, u: *mut c_void) {
    unsafe { sink(u).effects.push(Effect::Pwd) };
}
unsafe extern "C" fn on_hold(_: GhosttyTerminal, u: *mut c_void, held: bool) {
    unsafe { sink(u).effects.push(Effect::Hold(held)) };
}
unsafe extern "C" fn on_size(
    _: GhosttyTerminal,
    u: *mut c_void,
    out: *mut GhosttySizeReportSize,
) -> bool {
    if out.is_null() {
        return false;
    }
    unsafe { *out = sink(u).size };
    true
}
unsafe extern "C" fn on_clipboard(
    _: GhosttyTerminal,
    u: *mut c_void,
    w: *const GhosttyClipboardWrite,
) {
    let s = unsafe { sink(u) };
    let Some(w) = (unsafe { w.as_ref() }) else {
        return;
    };
    let result = if s.clipboard_write {
        let contents = if w.contents.is_null() {
            &[][..]
        } else {
            unsafe { std::slice::from_raw_parts(w.contents, w.contents_len) }
        };
        // every entry is the same value: the plain text one (or the first) is reported
        let pick = contents
            .iter()
            .find(|c| string(c.mime).starts_with("text/plain"))
            .or(contents.first());
        s.effects.push(Effect::Clipboard {
            primary: w.location != 0,
            mime: pick.map(|c| string(c.mime)).unwrap_or_default(),
            data: pick.map(|c| string(c.data)).unwrap_or_default(),
        });
        GHOSTTY_CLIPBOARD_WRITE_RESULT_SUCCESS
    } else {
        GHOSTTY_CLIPBOARD_WRITE_RESULT_DENIED
    };
    if let Some(reply) = w.reply {
        let r = GhosttyClipboardWriteReply {
            size: size_of::<GhosttyClipboardWriteReply>(),
            result,
            remember: false,
        };
        unsafe { reply(w, &r) };
    }
}
unsafe extern "C" fn on_notify(
    _: GhosttyTerminal,
    u: *mut c_void,
    n: *const GhosttyTerminalDesktopNotification,
) {
    if let Some(n) = unsafe { n.as_ref() } {
        unsafe { sink(u) }.effects.push(Effect::Notify {
            title: string(n.title),
            body: string(n.body),
        });
    }
}
unsafe extern "C" fn on_progress(
    _: GhosttyTerminal,
    u: *mut c_void,
    p: *const GhosttyTerminalProgressReport,
) {
    if let Some(p) = unsafe { p.as_ref() } {
        unsafe { sink(u) }.effects.push(Effect::Progress {
            state: p.state,
            value: p.progress as i32,
        });
    }
}
unsafe extern "C" fn on_prompt(
    _: GhosttyTerminal,
    u: *mut c_void,
    e: *const GhosttyTerminalSemanticPrompt,
) {
    if let Some(e) = unsafe { e.as_ref() } {
        unsafe { sink(u) }.effects.push(Effect::Prompt {
            kind: e.kind,
            exit: e.has_exit_code.then_some(e.exit_code),
        });
    }
}

impl Engine {
    /// A terminal of COLS × ROWS cells of CELL px, keeping at most SCROLLBACK lines and SCROLLBACK_BYTES of them.
    pub fn new(
        cols: u16,
        rows: u16,
        cell: (u32, u32),
        scrollback: usize,
        scrollback_bytes: usize,
    ) -> Result<Engine, String> {
        let mut e = Engine {
            term: null_mut(),
            rs: null_mut(),
            rows: null_mut(),
            cells: null_mut(),
            kenc: null_mut(),
            kev: null_mut(),
            menc: null_mut(),
            mev: null_mut(),
            sink: Box::default(),
            palette: [[0; 3]; 256],
            cols,
            rows_n: rows,
            cell,
        };
        // SAFETY: each constructor writes a fresh handle into its out pointer; Drop frees what was made.
        unsafe {
            ok(
                ghostty_terminal_new(null(), &mut e.term, cols.max(1), rows.max(1)),
                "terminal_new",
            )?;
            ok(
                ghostty_render_state_new(null(), &mut e.rs),
                "render_state_new",
            )?;
            ok(
                ghostty_render_state_row_iterator_new(null(), &mut e.rows),
                "row_iterator_new",
            )?;
            ok(
                ghostty_render_state_row_cells_new(null(), &mut e.cells),
                "row_cells_new",
            )?;
            ok(
                ghostty_key_encoder_new(null(), &mut e.kenc),
                "key_encoder_new",
            )?;
            ok(ghostty_key_event_new(null(), &mut e.kev), "key_event_new")?;
            ok(
                ghostty_mouse_encoder_new(null(), &mut e.menc),
                "mouse_encoder_new",
            )?;
            ok(
                ghostty_mouse_event_new(null(), &mut e.mev),
                "mouse_event_new",
            )?;
            let u: *mut Sink = &mut *e.sink;
            let t = e.term;
            ok(
                ghostty_terminal_set(t, GHOSTTY_TERMINAL_OPT_USERDATA, u as *const c_void),
                "userdata",
            )?;
            let fns: [(i32, *const c_void); 10] = [
                (
                    GHOSTTY_TERMINAL_OPT_WRITE_PTY,
                    on_write_pty as GhosttyTerminalWritePtyFn as *const c_void,
                ),
                (
                    GHOSTTY_TERMINAL_OPT_BELL,
                    on_bell as GhosttyTerminalBellFn as *const c_void,
                ),
                (
                    GHOSTTY_TERMINAL_OPT_TITLE_CHANGED,
                    on_title as GhosttyTerminalTitleChangedFn as *const c_void,
                ),
                (
                    GHOSTTY_TERMINAL_OPT_PWD_CHANGED,
                    on_pwd as GhosttyTerminalPwdChangedFn as *const c_void,
                ),
                (
                    GHOSTTY_TERMINAL_OPT_RENDER_HOLD,
                    on_hold as GhosttyTerminalRenderHoldFn as *const c_void,
                ),
                (
                    GHOSTTY_TERMINAL_OPT_SIZE,
                    on_size as GhosttyTerminalSizeFn as *const c_void,
                ),
                (
                    GHOSTTY_TERMINAL_OPT_CLIPBOARD_WRITE,
                    on_clipboard as GhosttyTerminalClipboardWriteFn as *const c_void,
                ),
                (
                    GHOSTTY_TERMINAL_OPT_DESKTOP_NOTIFICATION,
                    on_notify as GhosttyTerminalDesktopNotificationFn as *const c_void,
                ),
                (
                    GHOSTTY_TERMINAL_OPT_PROGRESS_REPORT,
                    on_progress as GhosttyTerminalProgressReportFn as *const c_void,
                ),
                (
                    GHOSTTY_TERMINAL_OPT_SEMANTIC_PROMPT,
                    on_prompt as GhosttyTerminalSemanticPromptFn as *const c_void,
                ),
            ];
            for (opt, f) in fns {
                ok(ghostty_terminal_set(t, opt, f), "callback")?;
            }
        }
        e.set_scrollback(scrollback, scrollback_bytes);
        e.resize(cols, rows, cell)?;
        Ok(e)
    }

    pub fn sink(&mut self) -> &mut Sink {
        &mut self.sink
    }

    /// The program's output.
    pub fn write(&mut self, bytes: &[u8]) {
        // SAFETY: a live terminal and a valid slice.
        unsafe { ghostty_terminal_vt_write(self.term, bytes.as_ptr(), bytes.len()) };
    }

    /// Keep at most LINES lines of scrollback, and at most BYTES of it (the engine's default is one page, about
    /// 400 kB: always set both).
    pub fn set_scrollback(&mut self, lines: usize, bytes: usize) {
        // SAFETY: both options' values are a size_t*.
        unsafe {
            ghostty_terminal_set(
                self.term,
                GHOSTTY_TERMINAL_OPT_SCROLLBACK_MAX_LINES,
                (&raw const lines).cast(),
            );
            ghostty_terminal_set(
                self.term,
                GHOSTTY_TERMINAL_OPT_SCROLLBACK_MAX_BYTES,
                (&raw const bytes).cast(),
            );
        }
    }

    /// The kitty keyboard flags the program set (0: none).
    pub fn kitty_flags(&self) -> u8 {
        self.get::<u8>(GHOSTTY_TERMINAL_DATA_KITTY_KEYBOARD_FLAGS)
            .unwrap_or(0)
    }

    pub fn resize(&mut self, cols: u16, rows: u16, cell: (u32, u32)) -> Result<(), String> {
        let (cols, rows) = (cols.max(1), rows.max(1));
        // SAFETY: a live terminal.
        ok(
            unsafe { ghostty_terminal_resize(self.term, cols, rows, cell.0, cell.1) },
            "resize",
        )?;
        self.cols = cols;
        self.rows_n = rows;
        self.cell = cell;
        self.sink.size = GhosttySizeReportSize {
            rows,
            columns: cols,
            cell_width: cell.0,
            cell_height: cell.1,
        };
        let size = GhosttyMouseEncoderSize {
            size: size_of::<GhosttyMouseEncoderSize>(),
            screen_width: cell.0 * cols as u32,
            screen_height: cell.1 * rows as u32,
            cell_width: cell.0.max(1),
            cell_height: cell.1.max(1),
            ..Default::default()
        };
        // SAFETY: the option's value is a GhosttyMouseEncoderSize*.
        unsafe {
            ghostty_mouse_encoder_set(
                self.menc,
                GHOSTTY_MOUSE_ENCODER_OPT_SIZE,
                (&raw const size).cast(),
            )
        };
        Ok(())
    }

    pub fn size(&self) -> (u16, u16, (u32, u32)) {
        (self.cols, self.rows_n, self.cell)
    }

    fn get<T: Default>(&self, key: i32) -> Option<T> {
        let mut v = T::default();
        // SAFETY: callers pass the output type the key documents.
        (unsafe { ghostty_terminal_get(self.term, key, (&raw mut v).cast()) } == GHOSTTY_SUCCESS)
            .then_some(v)
    }

    /// Whether mode N (a DEC private mode; ANSI: an ANSI mode) is set.
    pub fn mode(&self, n: u16, ansi: bool) -> bool {
        let mut m = GhosttyTerminalModeConfig {
            mode: ghostty_mode_new(n, ansi),
            value: false,
        };
        // SAFETY: DATA_MODE takes a GhosttyTerminalModeConfig* in and out.
        let rc = unsafe {
            ghostty_terminal_get(self.term, GHOSTTY_TERMINAL_DATA_MODE, (&raw mut m).cast())
        };
        rc == GHOSTTY_SUCCESS && m.value
    }

    pub fn alt_screen(&self) -> bool {
        self.get::<i32>(GHOSTTY_TERMINAL_DATA_ACTIVE_SCREEN)
            == Some(GHOSTTY_TERMINAL_SCREEN_ALTERNATE)
    }

    pub fn mouse_tracking(&self) -> bool {
        self.get::<bool>(GHOSTTY_TERMINAL_DATA_MOUSE_TRACKING)
            .unwrap_or(false)
    }

    pub fn scrollback_rows(&self) -> usize {
        self.get::<usize>(GHOSTTY_TERMINAL_DATA_SCROLLBACK_ROWS)
            .unwrap_or(0)
    }

    fn get_string(&self, key: i32) -> String {
        let mut s = GhosttyString {
            ptr: null(),
            len: 0,
        };
        // SAFETY: TITLE and PWD write a GhosttyString borrowed from the terminal, read at once.
        if unsafe { ghostty_terminal_get(self.term, key, (&raw mut s).cast()) } == GHOSTTY_SUCCESS {
            string(s)
        } else {
            String::new()
        }
    }

    pub fn title(&self) -> String {
        self.get_string(GHOSTTY_TERMINAL_DATA_TITLE)
    }

    pub fn pwd(&self) -> String {
        self.get_string(GHOSTTY_TERMINAL_DATA_PWD)
    }

    /// Capture the screen (and OVERSCAN rows above it) into the render state.
    pub fn update(&mut self, overscan: u16) {
        let o = GhosttyRenderStateOverscan {
            above: overscan,
            below: 0,
        };
        // SAFETY: a live render state and terminal; OPT_OVERSCAN takes a GhosttyRenderStateOverscan*.
        unsafe {
            ghostty_render_state_set(
                self.rs,
                GHOSTTY_RENDER_STATE_OPT_OVERSCAN,
                (&raw const o).cast(),
            );
            ghostty_render_state_update(self.rs, self.term);
            let mut colors: GhosttyRenderStateColors = std::mem::zeroed();
            colors.size = size_of::<GhosttyRenderStateColors>();
            if ghostty_render_state_get(
                self.rs,
                GHOSTTY_RENDER_STATE_DATA_COLORS,
                (&raw mut colors).cast(),
            ) == GHOSTTY_SUCCESS
            {
                for (i, c) in colors.palette.iter().enumerate() {
                    self.palette[i] = [c.r, c.g, c.b];
                }
            }
        }
    }

    /// Everything captured is drawn.
    pub fn clean(&mut self) {
        // SAFETY: a live render state.
        unsafe { ghostty_render_state_clean(self.rs) };
    }

    pub fn cursor(&self) -> Cursor {
        // SAFETY: DATA_CURSOR fills a sized GhosttyRenderStateCursor.
        unsafe {
            let mut c: GhosttyRenderStateCursor = std::mem::zeroed();
            c.size = size_of::<GhosttyRenderStateCursor>();
            ghostty_render_state_get(
                self.rs,
                GHOSTTY_RENDER_STATE_DATA_CURSOR,
                (&raw mut c).cast(),
            );
            Cursor {
                at: c.viewport_has_value.then_some((c.viewport_x, c.viewport_y)),
                visible: c.visible,
                shape: match c.visual_style {
                    GHOSTTY_CURSOR_STYLE_BAR => CursorShape::Bar,
                    GHOSTTY_CURSOR_STYLE_UNDERLINE => CursorShape::Underline,
                    GHOSTTY_CURSOR_STYLE_BLOCK_HOLLOW => CursorShape::BlockHollow,
                    _ => CursorShape::Block,
                },
            }
        }
    }

    /// Walk the captured rows top first: F gets each row's id, whether it is dirty (every row is after a full
    /// redraw), its viewport y (negative above the screen) and a reader for its cells. `clean` marks them drawn.
    pub fn rows(&mut self, mut f: impl FnMut(RowId, bool, i32, &mut CellReader<'_>)) {
        // SAFETY: the iterator is (re)bound to the render state, then read row by row on this thread.
        unsafe {
            let mut full: i32 = GHOSTTY_RENDER_STATE_DIRTY_FALSE;
            ghostty_render_state_get(
                self.rs,
                GHOSTTY_RENDER_STATE_DATA_DIRTY,
                (&raw mut full).cast(),
            );
            let full = full == GHOSTTY_RENDER_STATE_DIRTY_FULL;
            let mut it = self.rows;
            if ghostty_render_state_get(
                self.rs,
                GHOSTTY_RENDER_STATE_DATA_ROW_ITERATOR,
                (&raw mut it).cast(),
            ) != GHOSTTY_SUCCESS
            {
                return;
            }
            while ghostty_render_state_row_iterator_next(self.rows) {
                let mut id = GhosttyRenderStateRowId::default();
                ghostty_render_state_row_get(
                    self.rows,
                    GHOSTTY_RENDER_STATE_ROW_DATA_ID,
                    (&raw mut id).cast(),
                );
                let mut dirty = false;
                ghostty_render_state_row_get(
                    self.rows,
                    GHOSTTY_RENDER_STATE_ROW_DATA_DIRTY,
                    (&raw mut dirty).cast(),
                );
                let mut y: i32 = 0;
                ghostty_render_state_row_get(
                    self.rows,
                    GHOSTTY_RENDER_STATE_ROW_DATA_VIEWPORT_Y,
                    (&raw mut y).cast(),
                );
                let mut r = CellReader {
                    rows: self.rows,
                    cells: self.cells,
                    palette: &self.palette,
                };
                f(id.bits, dirty || full, y, &mut r);
            }
        }
    }

    /// The bytes KEY (a `GhosttyKey`) with MODS and its TEXT (UNSHIFTED: the key's codepoint without shift, 0 when
    /// unknown) encodes to under the terminal's current modes (kitty flags, modifyOtherKeys, DECCKM, ...).
    pub fn encode_key(
        &mut self,
        key: GhosttyKey,
        mods: GhosttyMods,
        text: &str,
        unshifted: u32,
    ) -> Vec<u8> {
        let mut buf = [0u8; 128];
        let mut n = 0usize;
        // SAFETY: the event and encoder are live; TEXT outlives the encode call that reads it.
        unsafe {
            ghostty_key_encoder_set_from_terminal(self.kenc, self.term);
            ghostty_key_event_set_action(self.kev, GHOSTTY_KEY_ACTION_PRESS);
            ghostty_key_event_set_key(self.kev, key);
            ghostty_key_event_set_mods(self.kev, mods);
            let consumed = if !text.is_empty() && mods & GHOSTTY_MODS_SHIFT != 0 {
                GHOSTTY_MODS_SHIFT
            } else {
                0
            };
            ghostty_key_event_set_consumed_mods(self.kev, consumed);
            ghostty_key_event_set_utf8(
                self.kev,
                GhosttyString {
                    ptr: text.as_ptr(),
                    len: text.len(),
                },
            );
            ghostty_key_event_set_unshifted_codepoint(self.kev, unshifted);
            if ghostty_key_encoder_encode(self.kenc, self.kev, buf.as_mut_ptr(), buf.len(), &mut n)
                != GHOSTTY_SUCCESS
            {
                n = 0;
            }
            // the event is reused: clear the borrowed text
            ghostty_key_event_set_utf8(
                self.kev,
                GhosttyString {
                    ptr: null(),
                    len: 0,
                },
            );
        }
        buf[..n].to_vec()
    }

    /// A mouse event at cell (COL, ROW): ACTION press/release/motion, BUTTON 1–11 (0: none). Empty unless the program
    /// tracks the mouse.
    pub fn encode_mouse(
        &mut self,
        action: i32,
        button: i32,
        col: u32,
        row: u32,
        mods: GhosttyMods,
    ) -> Vec<u8> {
        let mut buf = [0u8; 64];
        let mut n = 0usize;
        let (cw, ch) = (self.cell.0.max(1) as f32, self.cell.1.max(1) as f32);
        // SAFETY: the event and encoder are live.
        unsafe {
            ghostty_mouse_encoder_set_from_terminal(self.menc, self.term);
            ghostty_mouse_event_set_action(self.mev, action);
            if button > 0 {
                ghostty_mouse_event_set_button(self.mev, button);
            } else {
                ghostty_mouse_event_clear_button(self.mev);
            }
            ghostty_mouse_event_set_mods(self.mev, mods);
            ghostty_mouse_event_set_position(
                self.mev,
                GhosttyMousePosition {
                    x: (col as f32 + 0.5) * cw,
                    y: (row as f32 + 0.5) * ch,
                },
            );
            if ghostty_mouse_encoder_encode(
                self.menc,
                self.mev,
                buf.as_mut_ptr(),
                buf.len(),
                &mut n,
            ) != GHOSTTY_SUCCESS
            {
                n = 0;
            }
        }
        buf[..n].to_vec()
    }

    /// TEXT pasted: bracketed when the program asked (mode 2004).
    pub fn encode_paste(&mut self, text: &str) -> Vec<u8> {
        let bracketed = self.mode(2004, false);
        let mut data = text.as_bytes().to_vec();
        let mut out = vec![0u8; data.len() + 16];
        let mut n = 0usize;
        // SAFETY: DATA is a private mutable copy; OUT has room for the text and both brackets.
        let rc = unsafe {
            ghostty_paste_encode(
                data.as_mut_ptr().cast(),
                data.len(),
                bracketed,
                out.as_mut_ptr(),
                out.len(),
                &mut n,
            )
        };
        if rc != GHOSTTY_SUCCESS {
            return Vec::new();
        }
        out.truncate(n);
        out
    }

    /// Focus gained (IN) or lost: the report, when the program asked for focus events (mode 1004).
    pub fn encode_focus(&mut self, gained: bool) -> Vec<u8> {
        if !self.mode(1004, false) {
            return Vec::new();
        }
        let mut buf = [0u8; 8];
        let mut n = 0usize;
        let ev = if gained {
            GHOSTTY_FOCUS_GAINED
        } else {
            GHOSTTY_FOCUS_LOST
        };
        // SAFETY: a fixed buffer.
        if unsafe { ghostty_focus_encode(ev, buf.as_mut_ptr(), buf.len(), &mut n) }
            != GHOSTTY_SUCCESS
        {
            return Vec::new();
        }
        buf[..n].to_vec()
    }
}

impl Drop for Engine {
    fn drop(&mut self) {
        // SAFETY: each handle was made by its constructor (or is null, which the free functions accept).
        unsafe {
            if !self.mev.is_null() {
                ghostty_mouse_event_free(self.mev);
            }
            if !self.menc.is_null() {
                ghostty_mouse_encoder_free(self.menc);
            }
            if !self.kev.is_null() {
                ghostty_key_event_free(self.kev);
            }
            if !self.kenc.is_null() {
                ghostty_key_encoder_free(self.kenc);
            }
            if !self.cells.is_null() {
                ghostty_render_state_row_cells_free(self.cells);
            }
            if !self.rows.is_null() {
                ghostty_render_state_row_iterator_free(self.rows);
            }
            if !self.rs.is_null() {
                ghostty_render_state_free(self.rs);
            }
            if !self.term.is_null() {
                ghostty_terminal_free(self.term);
            }
        }
    }
}

/// Reads the cells of the row the walk is on.
pub struct CellReader<'a> {
    rows: GhosttyRenderStateRowIterator,
    cells: GhosttyRenderStateRowCells,
    palette: &'a [[u8; 3]; 256],
}

impl CellReader<'_> {
    /// The row's cells, left to right.
    pub fn cells(&mut self) -> Vec<Cell> {
        let mut out = Vec::new();
        // SAFETY: the cells handle is bound to the current row of the live iterator, then read cell by cell.
        unsafe {
            let mut c = self.cells;
            if ghostty_render_state_row_get(
                self.rows,
                GHOSTTY_RENDER_STATE_ROW_DATA_CELLS,
                (&raw mut c).cast(),
            ) != GHOSTTY_SUCCESS
            {
                return out;
            }
            let mut cps = [0u32; 16];
            while ghostty_render_state_row_cells_next(self.cells) {
                let mut text = String::new();
                let mut cb = GhosttyCodepointBuffer {
                    ptr: cps.as_mut_ptr(),
                    cap: cps.len(),
                    len: 0,
                };
                let rc = ghostty_render_state_row_cells_get(
                    self.cells,
                    GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_GRAPHEMES_BUF,
                    (&raw mut cb).cast(),
                );
                if rc == GHOSTTY_OUT_OF_SPACE {
                    // a long cluster: read it again into a buffer that fits
                    let mut big = vec![0u32; cb.len];
                    cb = GhosttyCodepointBuffer {
                        ptr: big.as_mut_ptr(),
                        cap: big.len(),
                        len: 0,
                    };
                    ghostty_render_state_row_cells_get(
                        self.cells,
                        GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_GRAPHEMES_BUF,
                        (&raw mut cb).cast(),
                    );
                    text.extend(
                        big[..cb.len.min(big.len())]
                            .iter()
                            .filter_map(|c| char::from_u32(*c)),
                    );
                } else {
                    text.extend(
                        cps[..cb.len.min(cps.len())]
                            .iter()
                            .filter_map(|c| char::from_u32(*c)),
                    );
                }
                let mut raw: GhosttyCell = 0;
                ghostty_render_state_row_cells_get(
                    self.cells,
                    GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_RAW,
                    (&raw mut raw).cast(),
                );
                let mut wide: i32 = 0;
                ghostty_cell_get(raw, GHOSTTY_CELL_DATA_WIDE, (&raw mut wide).cast());
                let mut styled = false;
                ghostty_render_state_row_cells_get(
                    self.cells,
                    GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_HAS_STYLING,
                    (&raw mut styled).cast(),
                );
                let style = if styled {
                    let mut s = GhosttyStyle::default();
                    ghostty_render_state_row_cells_get(
                        self.cells,
                        GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_STYLE,
                        (&raw mut s).cast(),
                    );
                    style_of(&s, self.palette)
                } else {
                    Style::default()
                };
                out.push(Cell {
                    text,
                    style,
                    wide: match wide {
                        GHOSTTY_CELL_WIDE_WIDE => Wide::Wide,
                        GHOSTTY_CELL_WIDE_SPACER_TAIL => Wide::Tail,
                        GHOSTTY_CELL_WIDE_SPACER_HEAD => Wide::Head,
                        _ => Wide::Narrow,
                    },
                });
            }
        }
        out
    }
}

/// The engine's style as the wire's (blink kept, invisible drawn as the background's colour by the editor: faint).
pub fn style_of(s: &GhosttyStyle, palette: &[[u8; 3]; 256]) -> Style {
    let f = s.flags;
    Style {
        fg: colour_of(s.fg_color.tag, s.fg_color.value, palette),
        bg: colour_of(s.bg_color.tag, s.bg_color.value, palette),
        ul_color: colour_of(s.underline_color.tag, s.underline_color.value, palette),
        bold: f & GHOSTTY_STYLE_FLAG_BOLD != 0,
        faint: f & (GHOSTTY_STYLE_FLAG_FAINT | GHOSTTY_STYLE_FLAG_INVISIBLE) != 0,
        italic: f & GHOSTTY_STYLE_FLAG_ITALIC != 0,
        underline: f & GHOSTTY_STYLE_UNDERLINE_MASK != 0,
        strike: f & GHOSTTY_STYLE_FLAG_STRIKETHROUGH != 0,
        inverse: f & GHOSTTY_STYLE_FLAG_INVERSE != 0,
        blink: f & GHOSTTY_STYLE_FLAG_BLINK != 0,
    }
}
