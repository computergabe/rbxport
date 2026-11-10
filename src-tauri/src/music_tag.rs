//! Writes tags an inbox script derived from file and folder names into the
//! library copy of a file, before it is registered. Like `music_inspect`, it
//! runs before Tauri starts and opens no rekordbox library.
use std::{ffi::OsString, fs::OpenOptions, io::Write, path::Path};

use lofty::config::WriteOptions;
use lofty::file::{AudioFile, TaggedFileExt};
use lofty::prelude::{Accessor, ItemKey};
use lofty::probe::Probe;
use lofty::tag::Tag;

/// Fields to set on one file; `None` leaves a field as it is.
#[derive(Debug, Default, serde::Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct Update {
    path: String,
    title: Option<String>,
    artist: Option<String>,
    album: Option<String>,
    album_artist: Option<String>,
    track_number: Option<u32>,
    year: Option<u32>,
}

/// What a new primary tag copies from a file's other tag. A WAV whose only
/// tag is RIFF INFO gets an `ID3v2` tag here, and the reader prefers the
/// primary tag, so anything left behind would stop being read.
const CARRIED: [ItemKey; 10] = [
    ItemKey::TrackTitle, ItemKey::TrackArtist, ItemKey::AlbumArtist, ItemKey::AlbumTitle, ItemKey::Genre,
    ItemKey::Label, ItemKey::Comment, ItemKey::Year, ItemKey::RecordingDate, ItemKey::TrackNumber,
];

fn write(update: &Update) -> Result<(), String> {
    let path = Path::new(&update.path);
    let mut file = Probe::open(path).and_then(Probe::read).map_err(|e| e.to_string())?;
    let primary = file.primary_tag_type();
    if file.tag(primary).is_none() {
        let mut tag = Tag::new(primary);
        if let Some(other) = file.first_tag() {
            for key in &CARRIED {
                if let Some(value) = other.get_string(key) {
                    tag.insert_text(key.clone(), value.to_owned());
                }
            }
        }
        file.insert_tag(tag);
    }
    let tag = file.tag_mut(primary).ok_or("The file cannot hold its primary tag.")?;
    if let Some(value) = &update.title { tag.set_title(value.clone()); }
    if let Some(value) = &update.artist { tag.set_artist(value.clone()); }
    if let Some(value) = &update.album { tag.set_album(value.clone()); }
    if let Some(value) = &update.album_artist { tag.insert_text(ItemKey::AlbumArtist, value.clone()); }
    if let Some(value) = update.track_number { tag.set_track(value); }
    if let Some(value) = update.year { tag.set_year(value); }
    file.save_to_path(path, WriteOptions::default()).map_err(|e| e.to_string())
}

fn execute(args: &[OsString]) -> i32 {
    if args.len() != 4 || args[2] != "--write-tags-report" { return 2; }
    let Ok(mut output) = OpenOptions::new().write(true).create_new(true).open(&args[3]) else { return 1; };
    let outcome = (|| -> Result<serde_json::Value, String> {
        let size = std::fs::metadata(&args[1]).map_err(|e| e.to_string())?.len();
        if size > 8 * 1024 * 1024 { return Err("Tag input list exceeds 8 MiB".into()); }
        let input = std::fs::read(&args[1]).map_err(|e| e.to_string())?;
        let updates: Vec<Update> = serde_json::from_slice(&input).map_err(|e| e.to_string())?;
        if updates.is_empty() || updates.len() > 100_000 { return Err("Supply between 1 and 100000 files".into()); }
        let mut errors = Vec::new();
        for update in &updates {
            if let Err(error) = write(update) {
                errors.push(serde_json::json!({"path": update.path, "error": error}));
            }
        }
        Ok(serde_json::json!({"ok": errors.is_empty(), "written": updates.len() - errors.len(), "errors": errors}))
    })();
    let value = outcome.unwrap_or_else(|error| serde_json::json!({"ok": false, "error": error}));
    let code = i32::from(value["ok"] != true);
    if serde_json::to_writer_pretty(&mut output, &value).is_err()
        || output.flush().is_err() || output.sync_all().is_err() { return 1; }
    code
}

pub fn run_if_requested() -> Option<i32> {
    let args: Vec<_> = std::env::args_os().skip(1).collect();
    if args.first().is_none_or(|arg| arg != "--write-tags") { return None; }
    Some(execute(&args))
}

#[cfg(test)]
#[allow(clippy::unwrap_used, clippy::expect_used, clippy::panic)]
mod tests {
    use super::*;

    fn wav(path: &Path, riff_artist: Option<&str>) {
        let mut data = Vec::new();
        data.extend_from_slice(b"RIFF"); data.extend_from_slice(&0_u32.to_le_bytes());
        data.extend_from_slice(b"WAVEfmt "); data.extend_from_slice(&16_u32.to_le_bytes());
        data.extend_from_slice(&1_u16.to_le_bytes()); data.extend_from_slice(&1_u16.to_le_bytes());
        data.extend_from_slice(&44100_u32.to_le_bytes()); data.extend_from_slice(&88200_u32.to_le_bytes());
        data.extend_from_slice(&2_u16.to_le_bytes()); data.extend_from_slice(&16_u16.to_le_bytes());
        data.extend_from_slice(b"data"); data.extend_from_slice(&256_u32.to_le_bytes());
        data.extend_from_slice(&[0; 256]);
        if let Some(artist) = riff_artist {
            let mut value = artist.as_bytes().to_vec(); value.push(0);
            if value.len() % 2 != 0 { value.push(0); }
            let mut info = b"INFO".to_vec();
            info.extend_from_slice(b"IART"); info.extend_from_slice(&u32::try_from(value.len()).unwrap().to_le_bytes());
            info.extend_from_slice(&value);
            data.extend_from_slice(b"LIST"); data.extend_from_slice(&u32::try_from(info.len()).unwrap().to_le_bytes());
            data.extend_from_slice(&info);
        }
        let size = u32::try_from(data.len() - 8).unwrap(); data[4..8].copy_from_slice(&size.to_le_bytes());
        std::fs::write(path, data).unwrap();
    }

    #[test]
    fn writes_tags_the_importer_reads_back() {
        let dir = tempfile::tempdir().unwrap();
        let file = dir.path().join("01. Blosso - Radio — 新.wav"); wav(&file, None);
        write(&Update {
            path: file.to_str().unwrap().into(), title: Some("Radio — 新".into()), artist: Some("Blosso".into()),
            album: Some("Blosso".into()), album_artist: Some("Blosso".into()), track_number: Some(1), year: Some(2026),
        }).unwrap();
        let tags = rbl_db::import::read_tags(&file).unwrap();
        assert_eq!((tags.title.as_str(), tags.artist.as_str(), tags.album.as_str(), tags.album_artist.as_str()), ("Radio — 新", "Blosso", "Blosso", "Blosso"));
        assert_eq!((tags.track_no, tags.year), (1, 2026));
    }

    #[test]
    fn a_new_primary_tag_keeps_what_the_other_tag_said() {
        let dir = tempfile::tempdir().unwrap();
        let file = dir.path().join("Champion Dub FINAL.wav"); wav(&file, Some("AND2"));
        assert_eq!(rbl_db::import::read_tags(&file).unwrap().artist, "AND2");
        write(&Update { path: file.to_str().unwrap().into(), album: Some("Dub Plates".into()), ..Update::default() }).unwrap();
        let tags = rbl_db::import::read_tags(&file).unwrap();
        assert_eq!(tags.artist, "AND2");
        assert_eq!(tags.album, "Dub Plates");
    }

    #[test]
    fn rejects_bad_arguments_and_reports_unreadable_files() {
        let dir = tempfile::tempdir().unwrap();
        assert_eq!(execute(&[OsString::from("--write-tags")]), 2);
        let list = dir.path().join("list.json");
        std::fs::write(&list, serde_json::to_vec(&serde_json::json!([{"path": dir.path().join("absent.wav")}])).unwrap()).unwrap();
        let report = dir.path().join("report.json");
        let args = [OsString::from("--write-tags"), list.into(), OsString::from("--write-tags-report"), report.clone().into()];
        assert_eq!(execute(&args), 1);
        let value: serde_json::Value = serde_json::from_slice(&std::fs::read(&report).unwrap()).unwrap();
        assert_eq!(value["ok"], false);
        assert_eq!(value["errors"].as_array().unwrap().len(), 1);
        // The report is never overwritten.
        assert_eq!(execute(&args), 1);
    }
}
