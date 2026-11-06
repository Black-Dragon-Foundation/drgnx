//! What a document holds: the file's text as UTF-8 with LF line ends, decoded with its line-end convention.  A file
//! that is binary, is not UTF-8 or does not round-trip through its convention is not text: it takes the snapshot
//! class (whole-file versions, kept outside the history).

/// How a file's bytes are decoded: its line-end convention.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Coding {
    /// LF line ends; a carriage return is a character of the text.
    Utf8Unix,
    /// CRLF line ends: each becomes LF in the document and LF again on save.
    Utf8Dos,
}

impl Coding {
    /// The convention a file's BYTES use: DOS when every LF follows a CR (and there is one), else Unix.
    pub fn detect(bytes: &[u8]) -> Coding {
        let mut crlf = false;
        for (i, b) in bytes.iter().enumerate() {
            if *b == b'\n' {
                if i == 0 || bytes[i - 1] != b'\r' {
                    return Coding::Utf8Unix;
                }
                crlf = true;
            }
        }
        if crlf {
            Coding::Utf8Dos
        } else {
            Coding::Utf8Unix
        }
    }
}

/// Why a file is not text.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum NotText {
    /// A NUL byte: a binary file.
    Binary,
    /// Not valid UTF-8.
    NotUtf8,
    /// Decoding and encoding again would not give the same bytes (a bare LF in a DOS file).
    NoRoundTrip,
}

/// BYTES as a document's text under CODING.
pub fn canonical(bytes: &[u8], coding: Coding) -> Result<String, NotText> {
    if bytes.contains(&0) {
        return Err(NotText::Binary);
    }
    let s = std::str::from_utf8(bytes).map_err(|_| NotText::NotUtf8)?;
    match coding {
        Coding::Utf8Unix => Ok(s.to_owned()),
        Coding::Utf8Dos => {
            let t = s.replace("\r\n", "\n");
            if encode(&t, coding) == bytes {
                Ok(t)
            } else {
                Err(NotText::NoRoundTrip)
            }
        }
    }
}

/// TEXT as the bytes a save under CODING writes.
pub fn encode(text: &str, coding: Coding) -> Vec<u8> {
    match coding {
        Coding::Utf8Unix => text.as_bytes().to_vec(),
        Coding::Utf8Dos => text.replace('\n', "\r\n").into_bytes(),
    }
}
