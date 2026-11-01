use std::{fs::File, io::BufWriter, path::Path, sync::{Arc, Mutex}, time::Duration};
use anyhow::{Context, Result, bail};
use librespot_core::{SpotifyUri, spotify_id::SpotifyId};
use librespot_playback::{
    audio_backend::{Sink, SinkError, SinkResult},
    config::{Bitrate, PlayerConfig}, convert::Converter, decoder::AudioPacket,
    mixer::NoOpVolume, player::{Player, PlayerEvent},
};
use crate::Job;
use std::sync::atomic::Ordering;

type Writer = Arc<Mutex<Option<hound::WavWriter<BufWriter<File>>>>>;

struct FileSink { writer: Writer, job: Arc<Job> }

impl Sink for FileSink {
    fn write(&mut self, packet: AudioPacket, _converter: &mut Converter) -> SinkResult<()> {
        let AudioPacket::Samples(samples) = packet else {
            return Err(SinkError::OnWrite("Expected decoded PCM".into()));
        };
        let mut guard = self.writer.lock().map_err(|_| SinkError::OnWrite("Writer lock failed".into()))?;
        let writer = guard.as_mut().ok_or_else(|| SinkError::OnWrite("Writer closed".into()))?;
        if u64::from(writer.len()) * 4 + samples.len() as u64 * 4 > 500_000_000 {
            return Err(SinkError::OnWrite("Audio exceeds 500 MB".into()));
        }
        self.job.samples.fetch_add(samples.len() as u64, Ordering::Relaxed);
        for sample in samples {
            writer.write_sample(sample as f32).map_err(|_| SinkError::OnWrite("Audio write failed".into()))?;
        }
        Ok(())
    }
}

pub async fn prepare(access_token: &str, track_id: &str, output: &Path, job: Arc<Job>) -> Result<()> {
    let _diagnostics = crate::diagnostics::capture(&job);
    let temporary_directory = output.parent().context("Missing audio cache directory")?;
    let session = crate::session(access_token, false, Some(temporary_directory)).await?;
    let cancellation = job.cancellation.clone();
    if cancellation.is_cancelled() {
        session.shutdown();
        bail!("Loading cancelled.");
    }
    let spec = hound::WavSpec { channels: 2, sample_rate: 44_100, bits_per_sample: 32, sample_format: hound::SampleFormat::Float };
    let writer: Writer = Arc::new(Mutex::new(Some(hound::WavWriter::create(output, spec)?)));
    let sink_writer = writer.clone();
    let config = PlayerConfig { bitrate: Bitrate::Bitrate320, ditherer: None, ..Default::default() };
    let sink_job = job.clone();
    let player = Player::new(config, session.clone(), Box::new(NoOpVolume), move || {
        Box::new(FileSink { writer: sink_writer.clone(), job: sink_job.clone() })
    });
    let mut events = player.get_player_event_channel();
    let track = SpotifyUri::Track { id: SpotifyId::from_base62(track_id)? };
    player.load(track, true, 0);
    let playback = async {
        while let Some(event) = events.recv().await {
            match event {
                PlayerEvent::EndOfTrack { .. } => return Ok(()),
                PlayerEvent::Unavailable { .. } => {
                    let detail = job.diagnostic.lock().unwrap().clone()
                        .unwrap_or_else(|| "No audio is available for this track and account.".into());
                    if detail.contains("Spotify refused the audio key") {
                        let plan = session.get_user_attribute("type").unwrap_or_else(|| "unknown".into());
                        let code = detail.split("(code ").nth(1).and_then(|value| value.split(')').next()).unwrap_or("unknown");
                        bail!("Spotify refused audio playback for your {plan} account after retries (code {code}). Your login is still saved. Try another track or try again later.");
                    }
                    bail!("Spotify could not load this track: {detail}");
                }
                _ => {}
            }
        }
        bail!("Spotify playback ended before the track was ready.")
    };
    let result = tokio::select! {
        _ = cancellation.cancelled() => Err(anyhow::anyhow!("Loading cancelled.")),
        outcome = tokio::time::timeout(Duration::from_secs(180), playback) =>
            outcome.context("Spotify audio preparation timed out.").and_then(|result| result),
    };
    player.stop();
    session.shutdown();
    drop(player);
    let final_writer = writer.lock().map_err(|_| anyhow::anyhow!("Writer lock failed"))?.take()
        .context("Audio writer closed unexpectedly")?;
    let count = final_writer.len();
    final_writer.finalize()?;
    result?;
    if count < 88_200 { bail!("Spotify returned less than one second of audio."); }
    Ok(())
}
