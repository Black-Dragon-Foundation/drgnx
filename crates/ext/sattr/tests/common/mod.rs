//! The editor's side in the tests: one model that implements the generated `Api` once, for both hosts.

use sattr::generated::drgnx_api_v0_1_0 as api;

use api::types::ErrorKind;

#[derive(Default)]
pub struct Model {
    pub log: Vec<String>,
    pub panic_on_register: bool,
    pub next_id: u64,
}

impl api::types::Api for Model {}
impl api::buffers::Api for Model {}
impl api::views::Api for Model {}

impl api::commands::Api for Model {
    fn register(&mut self, id: String, _title: String, _doc: String) -> Result<(), ErrorKind> {
        assert!(!self.panic_on_register, "a bug in the model");
        self.log.push(format!("register {id}"));
        Ok(())
    }

    fn run(&mut self, id: String, args: String) -> Result<String, ErrorKind> {
        Ok(format!("ran {id} {args}"))
    }

    fn find_source(&mut self, id: String) -> Result<String, ErrorKind> {
        if id == "known" {
            Ok("a.rs:1".into())
        } else {
            Err(ErrorKind::NotFound)
        }
    }
}

impl api::keys::Api for Model {
    fn bind(&mut self, chord: String, command: String, _context: String) -> Result<(), ErrorKind> {
        self.log.push(format!("bind {chord} {command}"));
        Ok(())
    }

    fn resolve(&mut self, _chord: String, _context: String) -> Result<String, ErrorKind> {
        Ok("prefix".into())
    }
}

impl api::settings::Api for Model {
    fn get(&mut self, _key: String) -> Result<String, ErrorKind> {
        Err(ErrorKind::NotFound)
    }

    fn set(
        &mut self,
        key: String,
        _value: String,
        at: api::settings::Level,
    ) -> Result<(), ErrorKind> {
        self.log.push(format!("set {key} at {}", at.as_str()));
        Ok(())
    }

    fn provenance(&mut self, _key: String) -> Result<String, ErrorKind> {
        Ok("built-in".into())
    }
}

impl api::ask::Api for Model {
    fn choose(
        &mut self,
        _title: String,
        _body: String,
        _choices: String,
        default_choice: String,
        timeout_ms: u32,
    ) -> Result<String, ErrorKind> {
        Ok(format!("{default_choice}:{timeout_ms}"))
    }
}

impl api::notices::Api for Model {
    fn post(
        &mut self,
        _at: api::notices::Level,
        _title: String,
        _body: String,
        _key: String,
    ) -> Result<u64, ErrorKind> {
        Ok(self.next_id)
    }

    fn dismiss(&mut self, id: u64) -> Result<(), ErrorKind> {
        self.log.push(format!("dismiss {id}"));
        Ok(())
    }
}
