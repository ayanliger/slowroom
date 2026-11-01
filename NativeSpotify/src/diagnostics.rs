use std::sync::{Arc, Mutex, Weak};
use crate::Job;

static LOGGER: AudioDiagnostics = AudioDiagnostics;
static ACTIVE_JOB: Mutex<Weak<Job>> = Mutex::new(Weak::new());

struct AudioDiagnostics;

impl log::Log for AudioDiagnostics {
    fn enabled(&self, metadata: &log::Metadata) -> bool {
        metadata.level() <= log::Level::Warn && metadata.target() == "librespot_playback::player"
    }

    fn log(&self, record: &log::Record) {
        if !self.enabled(record.metadata()) { return; }
        let message = record.args().to_string();
        if !(message.starts_with("Unable to load") || message.contains("not available")) { return; }
        let Some(job) = ACTIVE_JOB.lock().unwrap().upgrade() else { return; };
        *job.diagnostic.lock().unwrap() = Some(redact(&message));
    }

    fn flush(&self) {}
}

fn redact(message: &str) -> String {
    let lower = message.to_ascii_lowercase();
    if ["access_token", "refresh_token", "auth_data", "bearer "].iter().any(|word| lower.contains(word)) {
        return "Spotify rejected the playback authorization.".into();
    }
    message.split_whitespace().map(|word| {
        if word.contains("https://") || word.contains("http://") { "[URL]" } else { word }
    }).collect::<Vec<_>>().join(" ").chars().take(500).collect()
}

pub fn initialize() {
    if log::set_logger(&LOGGER).is_ok() { log::set_max_level(log::LevelFilter::Warn); }
}

pub struct Capture(Weak<Job>);

pub fn capture(job: &Arc<Job>) -> Capture {
    let weak = Arc::downgrade(job);
    *ACTIVE_JOB.lock().unwrap() = weak.clone();
    Capture(weak)
}

impl Drop for Capture {
    fn drop(&mut self) {
        let mut active = ACTIVE_JOB.lock().unwrap();
        if active.ptr_eq(&self.0) { *active = Weak::new(); }
    }
}

#[cfg(test)]
mod tests {
    use super::redact;

    #[test]
    fn removes_signed_urls_and_authorization_values() {
        assert_eq!(redact("Could not open https://cdn.example/audio?signature=secret now"), "Could not open [URL] now");
        assert!(!redact("access_token: secret").contains("secret"));
        assert!(!redact("Authorization: Bearer secret").contains("secret"));
    }
}
