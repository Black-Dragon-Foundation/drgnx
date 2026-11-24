pub fn on_key(rx: &std::sync::mpsc::Receiver<u32>) -> u32 {
    rx.recv().unwrap_or(0)
}

pub async fn fine(rx: &mut tokio::sync::mpsc::Receiver<u32>) -> Option<u32> {
    rx.recv().await
}

pub fn also_fine(rx: &std::sync::mpsc::Receiver<u32>) -> Option<u32> {
    rx.try_recv().ok()
}

mod scale;
