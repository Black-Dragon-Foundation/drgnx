//! The C API of libghostty-vt 1.0.x (`ghostty/vt.h`) as Rust declarations: the part the crates use so far. It follows the
//! headers of the pinned tarball (pin.toml); a new function is added from there, with its enum values. The C ABI is stable
//! across 1.x, so no value here changes. Every function is unsafe, as any foreign call.
#![allow(
    non_camel_case_types,
    non_snake_case,
    non_upper_case_globals,
    missing_docs
)]

use core::ffi::{c_char, c_void};

/// `GhosttyResult`: `GHOSTTY_SUCCESS` or a negative code.
pub type GhosttyResult = i32;
pub const GHOSTTY_SUCCESS: GhosttyResult = 0;
pub const GHOSTTY_OUT_OF_MEMORY: GhosttyResult = -1;
pub const GHOSTTY_INVALID_VALUE: GhosttyResult = -2;
pub const GHOSTTY_OUT_OF_SPACE: GhosttyResult = -3;
pub const GHOSTTY_UNSUPPORTED: GhosttyResult = -8;

/// `GhosttyTerminal`: an opaque handle (`struct GhosttyTerminalImpl *`).
pub type GhosttyTerminal = *mut c_void;
/// `GhosttyFormatter`: an opaque handle (`struct GhosttyFormatterImpl *`).
pub type GhosttyFormatter = *mut c_void;
/// `GhosttyAllocator`: only ever passed as NULL (the default allocator).
#[repr(C)]
pub struct GhosttyAllocator {
    _private: [u8; 0],
}

/// `GhosttyString`: a borrowed byte string.
#[repr(C)]
#[derive(Clone, Copy)]
pub struct GhosttyString {
    pub ptr: *const u8,
    pub len: usize,
}

/// `GhosttyBuildInfo` keys (`ghostty_build_info`); the output type of each is in `ghostty/vt/build_info.h`.
pub const GHOSTTY_BUILD_INFO_SIMD: i32 = 1; // bool
pub const GHOSTTY_BUILD_INFO_OPTIMIZE: i32 = 4; // GhosttyOptimizeMode (an int)
pub const GHOSTTY_BUILD_INFO_VERSION_STRING: i32 = 5; // GhosttyString
pub const GHOSTTY_BUILD_INFO_VERSION_MAJOR: i32 = 6; // size_t
pub const GHOSTTY_BUILD_INFO_VERSION_MINOR: i32 = 7; // size_t
pub const GHOSTTY_BUILD_INFO_VERSION_PATCH: i32 = 8; // size_t
pub const GHOSTTY_BUILD_INFO_FEATURE_FORMATTER: i32 = 12; // bool

unsafe extern "C" {
    pub fn ghostty_build_info(data: i32, out: *mut c_void) -> GhosttyResult;
    pub fn ghostty_version() -> *const c_char;

    pub fn ghostty_terminal_new(
        allocator: *const GhosttyAllocator,
        terminal: *mut GhosttyTerminal,
        cols: u16,
        rows: u16,
    ) -> GhosttyResult;
    pub fn ghostty_terminal_free(terminal: GhosttyTerminal);
    pub fn ghostty_terminal_vt_write(terminal: GhosttyTerminal, data: *const u8, len: usize);

    pub fn ghostty_formatter_terminal_new(
        allocator: *const GhosttyAllocator,
        formatter: *mut GhosttyFormatter,
        terminal: GhosttyTerminal,
    ) -> GhosttyResult;
    pub fn ghostty_formatter_format_buf(
        formatter: GhosttyFormatter,
        buf: *mut u8,
        buf_len: usize,
        out_written: *mut usize,
    ) -> GhosttyResult;
    pub fn ghostty_formatter_free(formatter: GhosttyFormatter);
}

// ---- The terminal worker's part (drgnx-term): render state, styles, modes, effects and the input encoders. ----

pub const GHOSTTY_NO_VALUE: GhosttyResult = -4;

/// `GhosttyRenderState` and its iterators: opaque handles.
pub type GhosttyRenderState = *mut c_void;
pub type GhosttyRenderStateRowIterator = *mut c_void;
pub type GhosttyRenderStateRowCells = *mut c_void;
pub type GhosttyKeyEvent = *mut c_void;
pub type GhosttyKeyEncoder = *mut c_void;
pub type GhosttyMouseEvent = *mut c_void;
pub type GhosttyMouseEncoder = *mut c_void;
/// `GhosttyCell`: a raw cell value (`ghostty_cell_get`).
pub type GhosttyCell = u64;
/// `GhosttyMode`: the mode number, bit 15 set for an ANSI mode (`ghostty_mode_new`).
pub type GhosttyMode = u16;
pub type GhosttyMods = u16;

/// `ghostty_mode_new` (a static inline in modes.h).
pub const fn ghostty_mode_new(value: u16, ansi: bool) -> GhosttyMode {
    (value & 0x7FFF) | ((ansi as u16) << 15)
}

#[repr(C)]
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct GhosttyColorRgb {
    pub r: u8,
    pub g: u8,
    pub b: u8,
}

/// `GhosttyStyleColor`: TAG (none, palette, rgb) and the union (palette index in `value[0]`, or r, g, b).
#[repr(C)]
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct GhosttyStyleColor {
    pub tag: u8,
    pub value: [u8; 3],
}
pub const GHOSTTY_STYLE_COLOR_NONE: u8 = 0;
pub const GHOSTTY_STYLE_COLOR_PALETTE: u8 = 1;
pub const GHOSTTY_STYLE_COLOR_RGB: u8 = 2;

#[repr(C)]
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct GhosttyStyle {
    pub fg_color: GhosttyStyleColor,
    pub bg_color: GhosttyStyleColor,
    pub underline_color: GhosttyStyleColor,
    pub flags: u16,
    pub reserved: u16,
}
pub const GHOSTTY_STYLE_FLAG_BOLD: u16 = 1 << 0;
pub const GHOSTTY_STYLE_FLAG_ITALIC: u16 = 1 << 1;
pub const GHOSTTY_STYLE_FLAG_FAINT: u16 = 1 << 2;
pub const GHOSTTY_STYLE_FLAG_BLINK: u16 = 1 << 3;
pub const GHOSTTY_STYLE_FLAG_INVERSE: u16 = 1 << 4;
pub const GHOSTTY_STYLE_FLAG_INVISIBLE: u16 = 1 << 5;
pub const GHOSTTY_STYLE_FLAG_STRIKETHROUGH: u16 = 1 << 6;
pub const GHOSTTY_STYLE_UNDERLINE_SHIFT: u16 = 8;
pub const GHOSTTY_STYLE_UNDERLINE_MASK: u16 = 0x7 << GHOSTTY_STYLE_UNDERLINE_SHIFT;

#[repr(C)]
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Hash)]
pub struct GhosttyRenderStateRowId {
    pub bits: [u64; 2],
}

#[repr(C)]
#[derive(Clone, Copy, Debug, Default)]
pub struct GhosttyRenderStateOverscan {
    pub above: u16,
    pub below: u16,
}

/// Sized: `size` must be `size_of::<Self>()`.
#[repr(C)]
#[derive(Clone, Copy, Debug)]
pub struct GhosttyRenderStateCursor {
    pub size: usize,
    pub viewport_has_value: bool,
    pub viewport_x: u16,
    pub viewport_y: u16,
    pub wide_tail: bool,
    pub visible: bool,
    pub blinking: bool,
    pub password_input: bool,
    pub visual_style: i32,
}
pub const GHOSTTY_CURSOR_STYLE_BAR: i32 = 0;
pub const GHOSTTY_CURSOR_STYLE_BLOCK: i32 = 1;
pub const GHOSTTY_CURSOR_STYLE_UNDERLINE: i32 = 2;
pub const GHOSTTY_CURSOR_STYLE_BLOCK_HOLLOW: i32 = 3;

/// Sized: `size` must be `size_of::<Self>()`.
#[repr(C)]
#[derive(Clone, Copy)]
pub struct GhosttyRenderStateColors {
    pub size: usize,
    pub background: GhosttyColorRgb,
    pub foreground: GhosttyColorRgb,
    pub cursor: GhosttyColorRgb,
    pub cursor_has_value: bool,
    pub palette: [GhosttyColorRgb; 256],
}

pub const GHOSTTY_RENDER_STATE_DIRTY_FALSE: i32 = 0;
pub const GHOSTTY_RENDER_STATE_DIRTY_PARTIAL: i32 = 1;
pub const GHOSTTY_RENDER_STATE_DIRTY_FULL: i32 = 2;

pub const GHOSTTY_RENDER_STATE_DATA_COLS: i32 = 1;
pub const GHOSTTY_RENDER_STATE_DATA_ROWS: i32 = 2;
pub const GHOSTTY_RENDER_STATE_DATA_DIRTY: i32 = 3;
pub const GHOSTTY_RENDER_STATE_DATA_ROW_ITERATOR: i32 = 4;
pub const GHOSTTY_RENDER_STATE_DATA_CURSOR: i32 = 18;
pub const GHOSTTY_RENDER_STATE_DATA_COLORS: i32 = 19;
pub const GHOSTTY_RENDER_STATE_DATA_OVERSCAN: i32 = 20;
pub const GHOSTTY_RENDER_STATE_OPT_DIRTY: i32 = 1;
pub const GHOSTTY_RENDER_STATE_OPT_OVERSCAN: i32 = 2;

pub const GHOSTTY_RENDER_STATE_ROW_DATA_DIRTY: i32 = 1;
pub const GHOSTTY_RENDER_STATE_ROW_DATA_RAW: i32 = 2;
pub const GHOSTTY_RENDER_STATE_ROW_DATA_CELLS: i32 = 3;
pub const GHOSTTY_RENDER_STATE_ROW_DATA_VIEWPORT_Y: i32 = 6;
pub const GHOSTTY_RENDER_STATE_ROW_DATA_ID: i32 = 7;
pub const GHOSTTY_RENDER_STATE_ROW_OPT_DIRTY: i32 = 1;

/// `GhosttyCodepointBuffer` (types.h): the caller's buffer of CAP codepoints; the library sets LEN to the cell's total.
#[repr(C)]
#[derive(Clone, Copy, Debug)]
pub struct GhosttyCodepointBuffer {
    pub ptr: *mut u32,
    pub cap: usize,
    pub len: usize,
}

pub const GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_RAW: i32 = 1;
pub const GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_STYLE: i32 = 2;
pub const GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_GRAPHEMES_LEN: i32 = 3;
pub const GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_GRAPHEMES_BUF: i32 = 4;
pub const GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_HAS_STYLING: i32 = 8;

pub const GHOSTTY_CELL_DATA_WIDE: i32 = 3;
pub const GHOSTTY_CELL_DATA_HAS_HYPERLINK: i32 = 7;
pub const GHOSTTY_CELL_WIDE_NARROW: i32 = 0;
pub const GHOSTTY_CELL_WIDE_WIDE: i32 = 1;
pub const GHOSTTY_CELL_WIDE_SPACER_TAIL: i32 = 2;
pub const GHOSTTY_CELL_WIDE_SPACER_HEAD: i32 = 3;
/// A cell's place (`GhosttyPoint`): TAG one of the `GHOSTTY_POINT_TAG_*`, the column and row inside that area.
pub const GHOSTTY_POINT_TAG_ACTIVE: i32 = 0;
pub const GHOSTTY_POINT_TAG_VIEWPORT: i32 = 1;

#[repr(C)]
#[derive(Clone, Copy, Debug, Default)]
pub struct GhosttyPointCoordinate {
    pub x: u16,
    pub y: u32,
}

#[repr(C)]
#[derive(Clone, Copy)]
pub union GhosttyPointValue {
    pub coordinate: GhosttyPointCoordinate,
    pub _padding: [u64; 2],
}

#[repr(C)]
#[derive(Clone, Copy)]
pub struct GhosttyPoint {
    pub tag: i32,
    pub value: GhosttyPointValue,
}

/// A reference to one cell (`ghostty_terminal_grid_ref`), valid until the terminal changes.
#[repr(C)]
#[derive(Clone, Copy, Debug)]
pub struct GhosttyGridRef {
    pub node: *mut c_void,
    pub x: u16,
    pub y: u16,
}

impl Default for GhosttyGridRef {
    fn default() -> Self {
        GhosttyGridRef {
            node: std::ptr::null_mut(),
            x: 0,
            y: 0,
        }
    }
}

/// `GhosttyRow` (raw row) and its data: whether the row soft-wraps into the next.
pub type GhosttyRow = u64;
pub const GHOSTTY_ROW_DATA_WRAP: i32 = 1;

/// Terminal options (`ghostty_terminal_set`); a callback option's value is the function pointer itself.
pub const GHOSTTY_TERMINAL_OPT_USERDATA: i32 = 1;
pub const GHOSTTY_TERMINAL_OPT_WRITE_PTY: i32 = 2;
pub const GHOSTTY_TERMINAL_OPT_BELL: i32 = 3;
pub const GHOSTTY_TERMINAL_OPT_TITLE_CHANGED: i32 = 6;
pub const GHOSTTY_TERMINAL_OPT_SIZE: i32 = 7;
pub const GHOSTTY_TERMINAL_OPT_COLOR_FOREGROUND: i32 = 12;
pub const GHOSTTY_TERMINAL_OPT_COLOR_BACKGROUND: i32 = 13;
pub const GHOSTTY_TERMINAL_OPT_COLOR_CURSOR: i32 = 14;
pub const GHOSTTY_TERMINAL_OPT_COLOR_PALETTE: i32 = 15;
pub const GHOSTTY_TERMINAL_OPT_PWD_CHANGED: i32 = 26;
pub const GHOSTTY_TERMINAL_OPT_CLIPBOARD_WRITE: i32 = 27;
pub const GHOSTTY_TERMINAL_OPT_SCROLLBACK_MAX_BYTES: i32 = 28;
pub const GHOSTTY_TERMINAL_OPT_SCROLLBACK_MAX_LINES: i32 = 29;
pub const GHOSTTY_TERMINAL_OPT_DESKTOP_NOTIFICATION: i32 = 30;
pub const GHOSTTY_TERMINAL_OPT_PROGRESS_REPORT: i32 = 31;
pub const GHOSTTY_TERMINAL_OPT_TERMINFO_NAME: i32 = 38;
pub const GHOSTTY_TERMINAL_OPT_RENDER_HOLD: i32 = 42;
pub const GHOSTTY_TERMINAL_OPT_SEMANTIC_PROMPT: i32 = 43;

/// Terminal data (`ghostty_terminal_get`).
pub const GHOSTTY_TERMINAL_DATA_COLS: i32 = 1;
pub const GHOSTTY_TERMINAL_DATA_ROWS: i32 = 2;
pub const GHOSTTY_TERMINAL_DATA_ACTIVE_SCREEN: i32 = 6; // GhosttyTerminalScreen (int)
pub const GHOSTTY_TERMINAL_DATA_KITTY_KEYBOARD_FLAGS: i32 = 8; // u8
pub const GHOSTTY_TERMINAL_DATA_MOUSE_TRACKING: i32 = 11; // bool
pub const GHOSTTY_TERMINAL_DATA_TITLE: i32 = 12; // GhosttyString
pub const GHOSTTY_TERMINAL_DATA_PWD: i32 = 13; // GhosttyString
pub const GHOSTTY_TERMINAL_DATA_TOTAL_ROWS: i32 = 14; // size_t
pub const GHOSTTY_TERMINAL_DATA_SCROLLBACK_ROWS: i32 = 15; // size_t
pub const GHOSTTY_TERMINAL_DATA_MODE: i32 = 37; // GhosttyTerminalModeConfig (in/out)
pub const GHOSTTY_TERMINAL_SCREEN_PRIMARY: i32 = 0;
pub const GHOSTTY_TERMINAL_SCREEN_ALTERNATE: i32 = 1;

#[repr(C)]
#[derive(Clone, Copy, Debug)]
pub struct GhosttyTerminalModeConfig {
    pub mode: GhosttyMode,
    pub value: bool,
}

#[repr(C)]
#[derive(Clone, Copy, Debug, Default)]
pub struct GhosttySizeReportSize {
    pub rows: u16,
    pub columns: u16,
    pub cell_width: u32,
    pub cell_height: u32,
}

#[repr(C)]
#[derive(Clone, Copy)]
pub struct GhosttyClipboardContent {
    pub mime: GhosttyString,
    pub data: GhosttyString,
}

#[repr(C)]
#[derive(Clone, Copy)]
pub struct GhosttyClipboardWriteReply {
    pub size: usize,
    pub result: i32,
    pub remember: bool,
}
pub const GHOSTTY_CLIPBOARD_WRITE_RESULT_SUCCESS: i32 = 0;
pub const GHOSTTY_CLIPBOARD_WRITE_RESULT_DENIED: i32 = 1;

pub type GhosttyClipboardWriteReplyFn = Option<
    unsafe extern "C" fn(
        write: *const GhosttyClipboardWrite,
        reply: *const GhosttyClipboardWriteReply,
    ),
>;

#[repr(C)]
pub struct GhosttyClipboardWrite {
    pub location: i32,
    pub contents: *const GhosttyClipboardContent,
    pub contents_len: usize,
    pub name: GhosttyString,
    pub granted: bool,
    pub can_remember: bool,
    pub ctx: *const c_void,
    pub reply: GhosttyClipboardWriteReplyFn,
}

#[repr(C)]
#[derive(Clone, Copy)]
pub struct GhosttyTerminalDesktopNotification {
    pub title: GhosttyString,
    pub body: GhosttyString,
}

#[repr(C)]
#[derive(Clone, Copy)]
pub struct GhosttyTerminalProgressReport {
    pub state: i32,
    pub progress: i8,
}

#[repr(C)]
#[derive(Clone, Copy)]
pub struct GhosttyTerminalSemanticPrompt {
    pub kind: i32,
    pub prompt_kind: i32,
    pub has_exit_code: bool,
    pub exit_code: i32,
    pub command: GhosttyString,
    pub error: GhosttyString,
}
pub const GHOSTTY_SEMANTIC_PROMPT_PROMPT_START: i32 = 1;
pub const GHOSTTY_SEMANTIC_PROMPT_INPUT_START: i32 = 2;
pub const GHOSTTY_SEMANTIC_PROMPT_OUTPUT_START: i32 = 3;
pub const GHOSTTY_SEMANTIC_PROMPT_COMMAND_END: i32 = 4;

pub type GhosttyTerminalWritePtyFn = unsafe extern "C" fn(
    terminal: GhosttyTerminal,
    userdata: *mut c_void,
    data: *const u8,
    len: usize,
);
pub type GhosttyTerminalBellFn =
    unsafe extern "C" fn(terminal: GhosttyTerminal, userdata: *mut c_void);
pub type GhosttyTerminalTitleChangedFn =
    unsafe extern "C" fn(terminal: GhosttyTerminal, userdata: *mut c_void);
pub type GhosttyTerminalPwdChangedFn =
    unsafe extern "C" fn(terminal: GhosttyTerminal, userdata: *mut c_void);
pub type GhosttyTerminalRenderHoldFn =
    unsafe extern "C" fn(terminal: GhosttyTerminal, userdata: *mut c_void, held: bool);
pub type GhosttyTerminalSizeFn = unsafe extern "C" fn(
    terminal: GhosttyTerminal,
    userdata: *mut c_void,
    out: *mut GhosttySizeReportSize,
) -> bool;
pub type GhosttyTerminalClipboardWriteFn = unsafe extern "C" fn(
    terminal: GhosttyTerminal,
    userdata: *mut c_void,
    write: *const GhosttyClipboardWrite,
);
pub type GhosttyTerminalDesktopNotificationFn = unsafe extern "C" fn(
    terminal: GhosttyTerminal,
    userdata: *mut c_void,
    notification: *const GhosttyTerminalDesktopNotification,
);
pub type GhosttyTerminalProgressReportFn = unsafe extern "C" fn(
    terminal: GhosttyTerminal,
    userdata: *mut c_void,
    report: *const GhosttyTerminalProgressReport,
);
pub type GhosttyTerminalSemanticPromptFn = unsafe extern "C" fn(
    terminal: GhosttyTerminal,
    userdata: *mut c_void,
    event: *const GhosttyTerminalSemanticPrompt,
);

/// Keys (`GhosttyKey`, W3C codes) the worker maps to; the full list is in key/event.h.
pub type GhosttyKey = i32;
pub const GHOSTTY_KEY_UNIDENTIFIED: GhosttyKey = 0;
pub const GHOSTTY_KEY_BACKQUOTE: GhosttyKey = 1;
pub const GHOSTTY_KEY_BACKSLASH: GhosttyKey = 2;
pub const GHOSTTY_KEY_BRACKET_LEFT: GhosttyKey = 3;
pub const GHOSTTY_KEY_BRACKET_RIGHT: GhosttyKey = 4;
pub const GHOSTTY_KEY_COMMA: GhosttyKey = 5;
pub const GHOSTTY_KEY_DIGIT_0: GhosttyKey = 6;
pub const GHOSTTY_KEY_EQUAL: GhosttyKey = 16;
pub const GHOSTTY_KEY_A: GhosttyKey = 20;
pub const GHOSTTY_KEY_MINUS: GhosttyKey = 46;
pub const GHOSTTY_KEY_PERIOD: GhosttyKey = 47;
pub const GHOSTTY_KEY_QUOTE: GhosttyKey = 48;
pub const GHOSTTY_KEY_SEMICOLON: GhosttyKey = 49;
pub const GHOSTTY_KEY_SLASH: GhosttyKey = 50;
pub const GHOSTTY_KEY_BACKSPACE: GhosttyKey = 53;
pub const GHOSTTY_KEY_ENTER: GhosttyKey = 58;
pub const GHOSTTY_KEY_SPACE: GhosttyKey = 63;
pub const GHOSTTY_KEY_TAB: GhosttyKey = 64;
pub const GHOSTTY_KEY_DELETE: GhosttyKey = 68;
pub const GHOSTTY_KEY_END: GhosttyKey = 69;
pub const GHOSTTY_KEY_HOME: GhosttyKey = 71;
pub const GHOSTTY_KEY_INSERT: GhosttyKey = 72;
pub const GHOSTTY_KEY_PAGE_DOWN: GhosttyKey = 73;
pub const GHOSTTY_KEY_PAGE_UP: GhosttyKey = 74;
pub const GHOSTTY_KEY_ARROW_DOWN: GhosttyKey = 75;
pub const GHOSTTY_KEY_ARROW_LEFT: GhosttyKey = 76;
pub const GHOSTTY_KEY_ARROW_RIGHT: GhosttyKey = 77;
pub const GHOSTTY_KEY_ARROW_UP: GhosttyKey = 78;
pub const GHOSTTY_KEY_ESCAPE: GhosttyKey = 120;
pub const GHOSTTY_KEY_F1: GhosttyKey = 121;
pub const GHOSTTY_KEY_ACTION_PRESS: i32 = 1;
pub const GHOSTTY_MODS_SHIFT: GhosttyMods = 1 << 0;
pub const GHOSTTY_MODS_CTRL: GhosttyMods = 1 << 1;
pub const GHOSTTY_MODS_ALT: GhosttyMods = 1 << 2;
pub const GHOSTTY_MODS_SUPER: GhosttyMods = 1 << 3;

pub const GHOSTTY_MOUSE_ACTION_PRESS: i32 = 0;
pub const GHOSTTY_MOUSE_ACTION_RELEASE: i32 = 1;
pub const GHOSTTY_MOUSE_ACTION_MOTION: i32 = 2;
pub const GHOSTTY_MOUSE_ENCODER_OPT_SIZE: i32 = 3;
pub const GHOSTTY_MOUSE_ENCODER_OPT_ANY_BUTTON_PRESSED: i32 = 4;

#[repr(C)]
#[derive(Clone, Copy, Debug, Default)]
pub struct GhosttyMousePosition {
    pub x: f32,
    pub y: f32,
}

/// Sized: `size` must be `size_of::<Self>()`.
#[repr(C)]
#[derive(Clone, Copy, Debug, Default)]
pub struct GhosttyMouseEncoderSize {
    pub size: usize,
    pub screen_width: u32,
    pub screen_height: u32,
    pub cell_width: u32,
    pub cell_height: u32,
    pub padding_top: u32,
    pub padding_bottom: u32,
    pub padding_right: u32,
    pub padding_left: u32,
}

pub const GHOSTTY_FOCUS_GAINED: i32 = 0;
pub const GHOSTTY_FOCUS_LOST: i32 = 1;

unsafe extern "C" {
    pub fn ghostty_terminal_resize(
        terminal: GhosttyTerminal,
        cols: u16,
        rows: u16,
        cell_width_px: u32,
        cell_height_px: u32,
    ) -> GhosttyResult;
    pub fn ghostty_terminal_set(
        terminal: GhosttyTerminal,
        option: i32,
        value: *const c_void,
    ) -> GhosttyResult;
    pub fn ghostty_terminal_get(
        terminal: GhosttyTerminal,
        data: i32,
        out: *mut c_void,
    ) -> GhosttyResult;

    pub fn ghostty_render_state_new(
        allocator: *const GhosttyAllocator,
        state: *mut GhosttyRenderState,
    ) -> GhosttyResult;
    pub fn ghostty_render_state_free(state: GhosttyRenderState);
    pub fn ghostty_render_state_update(
        state: GhosttyRenderState,
        terminal: GhosttyTerminal,
    ) -> GhosttyResult;
    pub fn ghostty_render_state_clean(state: GhosttyRenderState) -> GhosttyResult;
    pub fn ghostty_render_state_get(
        state: GhosttyRenderState,
        data: i32,
        out: *mut c_void,
    ) -> GhosttyResult;
    pub fn ghostty_render_state_set(
        state: GhosttyRenderState,
        option: i32,
        value: *const c_void,
    ) -> GhosttyResult;
    pub fn ghostty_render_state_row_iterator_new(
        allocator: *const GhosttyAllocator,
        out: *mut GhosttyRenderStateRowIterator,
    ) -> GhosttyResult;
    pub fn ghostty_render_state_row_iterator_free(iterator: GhosttyRenderStateRowIterator);
    pub fn ghostty_render_state_row_iterator_next(iterator: GhosttyRenderStateRowIterator) -> bool;
    pub fn ghostty_render_state_row_get(
        iterator: GhosttyRenderStateRowIterator,
        data: i32,
        out: *mut c_void,
    ) -> GhosttyResult;
    pub fn ghostty_render_state_row_set(
        iterator: GhosttyRenderStateRowIterator,
        option: i32,
        value: *const c_void,
    ) -> GhosttyResult;
    pub fn ghostty_render_state_row_cells_new(
        allocator: *const GhosttyAllocator,
        out: *mut GhosttyRenderStateRowCells,
    ) -> GhosttyResult;
    pub fn ghostty_render_state_row_cells_next(cells: GhosttyRenderStateRowCells) -> bool;
    pub fn ghostty_render_state_row_cells_get(
        cells: GhosttyRenderStateRowCells,
        data: i32,
        out: *mut c_void,
    ) -> GhosttyResult;
    pub fn ghostty_render_state_row_cells_free(cells: GhosttyRenderStateRowCells);
    pub fn ghostty_cell_get(cell: GhosttyCell, data: i32, out: *mut c_void) -> GhosttyResult;
    pub fn ghostty_row_get(row: GhosttyRow, data: i32, out: *mut c_void) -> GhosttyResult;
    pub fn ghostty_terminal_grid_ref(
        terminal: GhosttyTerminal,
        point: GhosttyPoint,
        out_ref: *mut GhosttyGridRef,
    ) -> GhosttyResult;
    pub fn ghostty_grid_ref_hyperlink_uri(
        r#ref: *const GhosttyGridRef,
        buf: *mut u8,
        buf_len: usize,
        out_written: *mut usize,
    ) -> GhosttyResult;

    pub fn ghostty_key_event_new(
        allocator: *const GhosttyAllocator,
        event: *mut GhosttyKeyEvent,
    ) -> GhosttyResult;
    pub fn ghostty_key_event_free(event: GhosttyKeyEvent);
    pub fn ghostty_key_event_set_action(event: GhosttyKeyEvent, action: i32) -> GhosttyResult;
    pub fn ghostty_key_event_set_key(event: GhosttyKeyEvent, key: GhosttyKey) -> GhosttyResult;
    pub fn ghostty_key_event_set_mods(event: GhosttyKeyEvent, mods: GhosttyMods) -> GhosttyResult;
    pub fn ghostty_key_event_set_consumed_mods(
        event: GhosttyKeyEvent,
        mods: GhosttyMods,
    ) -> GhosttyResult;
    pub fn ghostty_key_event_set_utf8(event: GhosttyKeyEvent, utf8: GhosttyString)
    -> GhosttyResult;
    pub fn ghostty_key_event_set_unshifted_codepoint(
        event: GhosttyKeyEvent,
        codepoint: u32,
    ) -> GhosttyResult;
    pub fn ghostty_key_encoder_new(
        allocator: *const GhosttyAllocator,
        encoder: *mut GhosttyKeyEncoder,
    ) -> GhosttyResult;
    pub fn ghostty_key_encoder_free(encoder: GhosttyKeyEncoder);
    pub fn ghostty_key_encoder_set_from_terminal(
        encoder: GhosttyKeyEncoder,
        terminal: GhosttyTerminal,
    ) -> GhosttyResult;
    pub fn ghostty_key_encoder_encode(
        encoder: GhosttyKeyEncoder,
        event: GhosttyKeyEvent,
        buf: *mut u8,
        buf_len: usize,
        out_written: *mut usize,
    ) -> GhosttyResult;

    pub fn ghostty_mouse_event_new(
        allocator: *const GhosttyAllocator,
        event: *mut GhosttyMouseEvent,
    ) -> GhosttyResult;
    pub fn ghostty_mouse_event_free(event: GhosttyMouseEvent);
    pub fn ghostty_mouse_event_set_action(event: GhosttyMouseEvent, action: i32) -> GhosttyResult;
    pub fn ghostty_mouse_event_set_button(event: GhosttyMouseEvent, button: i32) -> GhosttyResult;
    pub fn ghostty_mouse_event_clear_button(event: GhosttyMouseEvent) -> GhosttyResult;
    pub fn ghostty_mouse_event_set_mods(
        event: GhosttyMouseEvent,
        mods: GhosttyMods,
    ) -> GhosttyResult;
    pub fn ghostty_mouse_event_set_position(
        event: GhosttyMouseEvent,
        position: GhosttyMousePosition,
    ) -> GhosttyResult;
    pub fn ghostty_mouse_encoder_new(
        allocator: *const GhosttyAllocator,
        encoder: *mut GhosttyMouseEncoder,
    ) -> GhosttyResult;
    pub fn ghostty_mouse_encoder_free(encoder: GhosttyMouseEncoder);
    pub fn ghostty_mouse_encoder_set(
        encoder: GhosttyMouseEncoder,
        option: i32,
        value: *const c_void,
    ) -> GhosttyResult;
    pub fn ghostty_mouse_encoder_set_from_terminal(
        encoder: GhosttyMouseEncoder,
        terminal: GhosttyTerminal,
    ) -> GhosttyResult;
    pub fn ghostty_mouse_encoder_encode(
        encoder: GhosttyMouseEncoder,
        event: GhosttyMouseEvent,
        buf: *mut u8,
        buf_len: usize,
        out_written: *mut usize,
    ) -> GhosttyResult;

    pub fn ghostty_paste_encode(
        data: *mut c_char,
        data_len: usize,
        bracketed: bool,
        buf: *mut u8,
        buf_len: usize,
        out_written: *mut usize,
    ) -> GhosttyResult;
    pub fn ghostty_focus_encode(
        event: i32,
        buf: *mut u8,
        buf_len: usize,
        out_written: *mut usize,
    ) -> GhosttyResult;
}
