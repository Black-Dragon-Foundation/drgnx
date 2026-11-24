pub const HEX: &str = "#ff8800";
pub const NOT_A_COLOUR: &str = "#hashtag";

pub fn made() {
    let _c = rgb(1, 2, 3);
}

pub const PANEL_COLOUR: u32 = 0x1e1f25;
pub const MASK: u32 = 0x00ff00ff;

pub fn hexes() {
    paint(0xff8800aa);
    let _bg = Rgba::new(1, 2, 3, 4);
    let _fine = 0x0f0f;
    let _s = Style { color: 0x336699 };
}

pub const TINT_COLOUR: u32 = 0xff8800aa;

// a palette index is no colour literal; not flagged
pub fn indexed() {
    let _i = Colour::Ansi(1);
}
