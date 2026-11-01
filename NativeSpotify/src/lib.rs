mod audio;
mod diagnostics;

use std::{collections::HashMap, ffi::{CStr, CString, c_char}, path::Path,
    sync::{Arc, Mutex, OnceLock, atomic::{AtomicU64, Ordering}}, time::Duration};
use anyhow::Result;
use librespot_core::{authentication::Credentials, cache::Cache, config::SessionConfig, session::Session};
use serde::Serialize;
use tokio::runtime::Runtime;
use tokio_util::sync::CancellationToken;

const CLIENT_ID: &str = "65b708073fc0480ea92a077233ca87bd";
static RUNTIME: OnceLock<Runtime> = OnceLock::new();
static JOBS: OnceLock<Mutex<HashMap<u64, Arc<Job>>>> = OnceLock::new();
static CREDENTIALS: OnceLock<Mutex<Option<Credentials>>> = OnceLock::new();
static NEXT_ID: AtomicU64 = AtomicU64::new(1);
static ACCOUNT_EPOCH: AtomicU64 = AtomicU64::new(0);

#[derive(Clone, Serialize)]
struct Status { status: String, error: Option<String>, samples: u64 }

struct Job {
    status: Mutex<Status>,
    cancellation: CancellationToken,
    samples: AtomicU64,
    diagnostic: Mutex<Option<String>>,
}

fn jobs() -> &'static Mutex<HashMap<u64, Arc<Job>>> { JOBS.get_or_init(|| Mutex::new(HashMap::new())) }
fn credentials() -> &'static Mutex<Option<Credentials>> { CREDENTIALS.get_or_init(|| Mutex::new(None)) }
fn runtime() -> &'static Runtime {
    RUNTIME.get_or_init(|| {
        diagnostics::initialize();
        tokio::runtime::Builder::new_multi_thread().worker_threads(2).enable_all().build().expect("Cannot start Spotify runtime")
    })
}

fn begin() -> (u64, Arc<Job>) {
    let id = NEXT_ID.fetch_add(1, Ordering::Relaxed);
    let job = Arc::new(Job {
        status: Mutex::new(Status { status: "loading".into(), error: None, samples: 0 }),
        cancellation: CancellationToken::new(), samples: AtomicU64::new(0),
        diagnostic: Mutex::new(None),
    });
    jobs().lock().unwrap().insert(id, job.clone());
    (id, job)
}

fn finish(job: &Job, result: Result<()>) {
    let mut status = job.status.lock().unwrap();
    if job.cancellation.is_cancelled() {
        status.status = "cancelled".into();
    } else if let Err(error) = result {
        status.status = "failed".into();
        status.error = Some(format!("{error:#}"));
    } else {
        status.status = "ready".into();
    }
}

async fn session(access_token: &str, fresh: bool, temporary_directory: Option<&Path>) -> Result<Session> {
    let epoch = ACCOUNT_EPOCH.load(Ordering::Relaxed);
    let cached = if fresh { None } else { credentials().lock().unwrap().clone() };
    let credential = cached.unwrap_or_else(|| Credentials::with_access_token(access_token));
    let cache = Cache::new(None::<&Path>, None, None, None)?.with_memory_credentials();
    let mut config = SessionConfig { client_id: CLIENT_ID.into(), ap_port: Some(443), ..Default::default() };
    if let Some(directory) = temporary_directory {
        config.tmp_dir = directory.to_path_buf();
    }
    let session = Session::new(config, Some(cache.clone()));
    let result = tokio::time::timeout(Duration::from_secs(30), session.connect(credential, true)).await;
    match result {
        Ok(Ok(())) => {
            let mut saved = credentials().lock().unwrap();
            if ACCOUNT_EPOCH.load(Ordering::Relaxed) != epoch {
                session.shutdown();
                anyhow::bail!("Spotify sign-in was cancelled.");
            }
            *saved = cache.credentials();
            Ok(session)
        }
        Ok(Err(error)) => {
            session.shutdown();
            Err(anyhow::anyhow!("Spotify could not open an audio session: {}", error.error))
        }
        Err(_) => { session.shutdown(); anyhow::bail!("Spotify audio connection timed out.") }
    }
}

unsafe fn input(value: *const c_char) -> Result<String> {
    if value.is_null() { anyhow::bail!("Missing native client input"); }
    Ok(unsafe { CStr::from_ptr(value) }.to_str()?.to_owned())
}

fn valid_track(value: &str) -> bool {
    value.len() == 22 && value.bytes().all(|byte| byte.is_ascii_alphanumeric())
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn sr_spotify_connect(access_token: *const c_char) -> u64 {
    let (id, job) = begin();
    let token = unsafe { input(access_token) };
    runtime().spawn(async move {
        let result = async {
            let token = token?;
            let session = session(&token, true, None).await?;
            session.shutdown();
            Ok(())
        }.await;
        finish(&job, result);
    });
    id
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn sr_spotify_prepare(access_token: *const c_char, track_id: *const c_char, output_path: *const c_char) -> u64 {
    let (id, job) = begin();
    let token = unsafe { input(access_token) };
    let track = unsafe { input(track_id) };
    let output = unsafe { input(output_path) };
    runtime().spawn(async move {
        let result = async {
            let token = token?;
            let track = track?;
            let output = output?;
            if !valid_track(&track) { anyhow::bail!("Use a Spotify song link."); }
            let path = Path::new(&output);
            let result = audio::prepare(&token, &track, path, job.clone()).await;
            if result.is_err() || job.cancellation.is_cancelled() { let _ = std::fs::remove_file(path); }
            result
        }.await;
        finish(&job, result);
    });
    id
}

#[unsafe(no_mangle)]
pub extern "C" fn sr_spotify_status(id: u64) -> *mut c_char {
    let job = jobs().lock().unwrap().get(&id).cloned();
    let status = if let Some(job) = job {
        let mut status = job.status.lock().unwrap().clone();
        status.samples = job.samples.load(Ordering::Relaxed);
        status
    } else { Status { status: "failed".into(), error: Some("This operation has ended.".into()), samples: 0 } };
    CString::new(serde_json::to_string(&status).unwrap()).unwrap().into_raw()
}

#[unsafe(no_mangle)]
pub extern "C" fn sr_spotify_cancel(id: u64) {
    if let Some(job) = jobs().lock().unwrap().get(&id) { job.cancellation.cancel(); }
}

#[unsafe(no_mangle)]
pub extern "C" fn sr_spotify_release(id: u64) {
    if let Some(job) = jobs().lock().unwrap().remove(&id) { job.cancellation.cancel(); }
}

#[unsafe(no_mangle)]
pub extern "C" fn sr_spotify_forget() {
    ACCOUNT_EPOCH.fetch_add(1, Ordering::Relaxed);
    *credentials().lock().unwrap() = None;
    for job in jobs().lock().unwrap().values() { job.cancellation.cancel(); }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn sr_spotify_string_free(value: *mut c_char) {
    if !value.is_null() { drop(unsafe { CString::from_raw(value) }); }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn validates_track_ids() {
        assert!(valid_track("20I6sIOMTCkB6w7ryavxtO"));
        assert!(!valid_track("../../private/file.wav"));
    }

    #[test]
    fn ffi_status_is_owned_and_released() {
        let (id, job) = begin();
        finish(&job, Ok(()));
        let pointer = sr_spotify_status(id);
        let data = unsafe { CStr::from_ptr(pointer) }.to_str().unwrap();
        assert!(data.contains("ready"));
        unsafe { sr_spotify_string_free(pointer); }
        sr_spotify_release(id);
        assert!(job.cancellation.is_cancelled());
        assert!(!jobs().lock().unwrap().contains_key(&id));
    }
}
