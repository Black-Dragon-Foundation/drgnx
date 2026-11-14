//! Lucide icons (`etc/icons`, ISC) as the SVG images of rows: the file's shapes in an image of the icon's pixel size,
//! stroked in a palette colour at the look's weight (1.6 in the 24-unit box).

/// The icons a row uses, by name.
const ICONS: &[(&str, &str)] = &[
    (
        "message-square",
        include_str!("../../../../etc/icons/message-square.svg"),
    ),
    (
        "file-text",
        include_str!("../../../../etc/icons/file-text.svg"),
    ),
    (
        "list-checks",
        include_str!("../../../../etc/icons/list-checks.svg"),
    ),
    (
        "git-branch",
        include_str!("../../../../etc/icons/git-branch.svg"),
    ),
    (
        "file-code",
        include_str!("../../../../etc/icons/file-code.svg"),
    ),
    ("monitor", include_str!("../../../../etc/icons/monitor.svg")),
    ("laptop", include_str!("../../../../etc/icons/laptop.svg")),
    ("search", include_str!("../../../../etc/icons/search.svg")),
    ("globe", include_str!("../../../../etc/icons/globe.svg")),
    ("brain", include_str!("../../../../etc/icons/brain.svg")),
    ("pencil", include_str!("../../../../etc/icons/pencil.svg")),
    ("layers", include_str!("../../../../etc/icons/layers.svg")),
    ("flag", include_str!("../../../../etc/icons/flag.svg")),
    (
        "lightbulb",
        include_str!("../../../../etc/icons/lightbulb.svg"),
    ),
    ("clock", include_str!("../../../../etc/icons/clock.svg")),
    ("play", include_str!("../../../../etc/icons/play.svg")),
];

/// The SVG of icon NAME, PX wide and high, stroked in COLOUR (a `#hex` or a colour name the editor sent); none for a
/// name not in the table.
pub(crate) fn svg(name: &str, colour: &str, px: u32) -> Option<String> {
    let raw = ICONS.iter().find(|(n, _)| *n == name)?.1;
    let open = raw.find("<svg")?;
    let inner_start = open + raw[open..].find('>')? + 1;
    let inner_end = raw.rfind("</svg>")?;
    Some(format!(
        r#"<svg xmlns="http://www.w3.org/2000/svg" width="{px}" height="{px}" viewBox="0 0 24 24" fill="none" stroke="{colour}" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round">{}</svg>"#,
        raw[inner_start..inner_end].trim()
    ))
}
