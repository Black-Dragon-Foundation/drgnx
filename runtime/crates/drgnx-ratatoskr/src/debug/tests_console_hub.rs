//! The debug console in the hub's sessions ([`Debug`]) with a mock adapter: output batched into `debug-output`, the
//! session's end sending what waited, a line the hub says itself.
use super::session::{Op, Proc, Request, Sig, Start};
use super::{BoxFut, Connected, Debug, Launcher, Opened, Sink, Terminals};
use serde_json::{Value, json};
use std::sync::{Arc, Mutex};
use std::time::Duration;
use vor::mock::{Mock, Script};

#[derive(Default)]
struct Events(Mutex<Vec<(String, Value)>>);

impl Sink for Events {
    fn broadcast(&self, event: &str, data: Value, _: Option<u64>) {
        self.0.lock().unwrap().push((event.to_owned(), data));
    }
    fn send(&self, _: u64, event: &str, data: Value) -> bool {
        self.0.lock().unwrap().push((event.to_owned(), data));
        true
    }
}

impl Events {
    fn outputs(&self) -> Vec<Value> {
        self.0
            .lock()
            .unwrap()
            .iter()
            .filter(|e| e.0 == "debug-output")
            .map(|e| e.1.clone())
            .collect()
    }
}

struct NoTerms;

impl Terminals for NoTerms {
    fn open(
        &self,
        _: u64,
        _: String,
        _: Vec<String>,
        _: Vec<(String, String)>,
    ) -> BoxFut<'_, Result<Opened, String>> {
        Box::pin(async { Err("no terminals here".to_owned()) })
    }
}

struct Exits;

impl Proc for Exits {
    fn signal(&mut self, _: Sig) {}
    fn wait(&mut self) -> BoxFut<'_, ()> {
        Box::pin(async {})
    }
}

/// One mock adapter playing STEPS.
struct One(Mutex<Option<Vec<Value>>>, Mutex<Vec<Mock>>);

impl Launcher for One {
    fn connect(&self) -> BoxFut<'_, Result<Connected, String>> {
        Box::pin(async move {
            let steps = self.0.lock().unwrap().take().ok_or("one session only")?;
            let script: Script = serde_json::from_value(Value::Array(steps)).unwrap();
            let (a, b) = tokio::io::duplex(1 << 20);
            let (cr, cw) = tokio::io::split(a);
            let (mr, mw) = tokio::io::split(b);
            self.1.lock().unwrap().push(Mock::start(script, mr, mw));
            let (client, incoming) = vor::Client::new(cr, cw);
            Ok(Connected {
                client,
                incoming,
                proc: Box::new(Exits),
            })
        })
    }
}

async fn until(mut cond: impl FnMut() -> bool) {
    for _ in 0..10_000 {
        if cond() {
            return;
        }
        crate::clock::sleep(Duration::from_millis(1)).await;
    }
    panic!("never happened");
}

fn out(cat: &str, text: &str) -> Value {
    json!({"event": "output", "body": {"category": cat, "output": text}})
}

/// A program's output reaches every editor as `debug-output`: the lines of one burst in one batch, sent once the
/// batch's 50 ms are up; the line still waiting for its newline goes when the session ends.
#[tokio::test(start_paused = true)]
async fn output_goes_in_batches_and_the_rest_at_the_end() {
    let steps = vec![
        json!({"expect": "initialize", "ok": {"supportsConfigurationDoneRequest": true}}),
        json!({"expect": "launch", "ok": {}}),
        json!({"event": "initialized"}),
        json!({"expect": "configurationDone"}),
        out("stdout", "one\n"),
        out("stderr", "two\n"),
        out("stdout", "thr"),
        json!({"expect": "disconnect", "ok": {}}),
        json!({"die": true}),
    ];
    let ev = Arc::new(Events::default());
    let d = Debug::new(ev.clone(), Arc::new(NoTerms));
    let m = Arc::new(One(Mutex::new(Some(steps)), Mutex::default()));
    let start = Start {
        name: "Node: app".into(),
        adapter_id: "pwa-node".into(),
        request: Request::Launch,
        arguments: json!({"program": "/p/app.js"}),
        breakpoints: vec![],
        functions: vec![],
        exception_filters: None,
    };
    let id = d.start(7, "/p", start, m.clone()).await.unwrap();
    let t0 = crate::clock::now();
    until(|| !ev.outputs().is_empty()).await;
    assert!(crate::clock::now() - t0 >= Duration::from_millis(50) - Duration::from_millis(5));
    let first = ev.outputs()[0].clone();
    assert_eq!(first["session"], json!(id));
    let texts: Vec<&str> = first["lines"]
        .as_array()
        .unwrap()
        .iter()
        .map(|l| l["text"].as_str().unwrap())
        .collect();
    assert_eq!(texts, ["one", "two"]);
    assert_eq!(first["lines"][1]["category"], "stderr");
    d.control(
        &id,
        Op::Stop {
            kill_debuggee: None,
        },
    )
    .await
    .unwrap();
    until(|| ev.outputs().len() == 2).await;
    assert_eq!(ev.outputs()[1]["lines"][0]["text"], "thr");
    let ms: Vec<Mock> = std::mem::take(&mut *m.1.lock().unwrap());
    for mock in ms {
        mock.finish().await.unwrap();
    }
}

/// A line the hub says itself (a `postDebugTask` that failed) goes at once, in its category.
#[tokio::test(start_paused = true)]
async fn a_line_the_hub_says_goes_at_once() {
    let ev = Arc::new(Events::default());
    let d = Debug::new(ev.clone(), Arc::new(NoTerms));
    d.console_say("s9", "postDebugTask failed: exit 2", "important");
    let o = ev.outputs();
    assert_eq!(o.len(), 1);
    assert_eq!(o[0]["session"], "s9");
    let mut line = o[0]["lines"][0].clone();
    // stamped with the hub's time of day
    assert!(line["time"].as_u64().is_some_and(|t| t > 0));
    line.as_object_mut().unwrap().remove("time");
    assert_eq!(
        line,
        json!({"text": "postDebugTask failed: exit 2", "category": "important", "count": 1})
    );
}
