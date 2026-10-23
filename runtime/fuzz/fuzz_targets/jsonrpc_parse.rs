//! A line through `runstav::jsonrpc::parse` and mimir's `lenient_id`: an error is `-32700` (only for text that is not
//! JSON) or `-32600`; a request or result that parses has the id `lenient_id` reads from the same line.
#![no_main]

use libfuzzer_sys::fuzz_target;
use mimir::jsonrpc_glue::lenient_id;
use runstav::jsonrpc::{INVALID_REQUEST, Message, PARSE_ERROR, parse};

fuzz_target!(|data: &[u8]| {
    let Ok(line) = std::str::from_utf8(data) else {
        return;
    };
    let lenient = lenient_id(line);
    match parse(line) {
        Ok(Message::Request { id, .. } | Message::Result { id, .. }) => {
            assert_eq!(lenient, Some(id));
        }
        Ok(_) => {}
        Err(e) => {
            assert!(e.code == PARSE_ERROR || e.code == INVALID_REQUEST);
            if e.code == PARSE_ERROR {
                assert!(serde_json::from_str::<serde_json::Value>(line).is_err());
                assert!(lenient.is_none());
            }
        }
    }
});
