//! Text through the sanitizers of `runstav::text`. The first byte picks `header`, the second the length limit, the rest
//! is the text (lossy UTF-8). `one_line`: no `CONTROL` character and no `\n`, `\r` or `\t` in the result, at most MAX
//! characters, no `]` or `#` with HEADER. `coord_line`: no `CONTROL` character, at most MAX. `cut`: no `CONTROL`
//! character but `\n` and `\t`, at most MAX.
#![no_main]

use libfuzzer_sys::fuzz_target;
use runstav::text::{CONTROL, coord_line, cut, one_line};

fn control(c: char) -> bool {
    CONTROL.iter().any(|r| r.contains(&c))
}

fuzz_target!(|data: &[u8]| {
    let [header, max, rest @ ..] = data else {
        return;
    };
    let (header, max) = (header & 1 == 1, usize::from(*max));
    let text = String::from_utf8_lossy(rest);

    let one = one_line(&text, max, header);
    assert!(one.chars().count() <= max);
    assert!(
        !one.chars()
            .any(|c| control(c) || matches!(c, '\n' | '\r' | '\t'))
    );
    if header {
        assert!(!one.contains([']', '#']));
    }

    let line = coord_line(&text, max);
    assert!(line.chars().count() <= max);
    assert!(!line.chars().any(control));

    let (clean, _) = cut(&text, max);
    assert!(clean.chars().count() <= max);
    assert!(
        !clean
            .chars()
            .any(|c| control(c) && !matches!(c, '\n' | '\t'))
    );
});
