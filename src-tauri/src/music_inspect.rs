//! Read-only file metadata for configurable inbox organization, without Tauri
//! startup or any library discovery or database access.
use std::{ffi::OsString, fs::OpenOptions, io::Write, path::Path};

fn inspect(paths: &[String]) -> serde_json::Value {
    let mut files = Vec::new();
    let mut errors = Vec::new();
    for path in paths {
        match rbl_db::import::read_tags(Path::new(path)) {
            Ok(tags) => files.push(serde_json::json!({
                "path": path, "artist": tags.artist, "albumArtist": tags.album_artist, "album": tags.album,
                "title": tags.title, "trackNumber": tags.track_no,
            })),
            Err(error) => errors.push(serde_json::json!({"path": path, "error": error.to_string()})),
        }
    }
    serde_json::json!({"ok": errors.is_empty(), "files": files, "errors": errors})
}

fn execute(args: &[OsString]) -> i32 {
    if args.len() != 4 || args[2] != "--inspect-report" { return 2; }
    let Ok(mut output) = OpenOptions::new().write(true).create_new(true).open(&args[3]) else { return 1; };
    let outcome = (|| -> Result<serde_json::Value, String> {
        let size = std::fs::metadata(&args[1]).map_err(|e| e.to_string())?.len();
        if size > 8 * 1024 * 1024 { return Err("Metadata input list exceeds 8 MiB".into()); }
        let input = std::fs::read(&args[1]).map_err(|e| e.to_string())?;
        let paths: Vec<String> = serde_json::from_slice(&input).map_err(|e| e.to_string())?;
        if paths.is_empty() || paths.len() > 100_000 { return Err("Supply between 1 and 100000 file paths".into()); }
        Ok(inspect(&paths))
    })();
    let value = outcome.unwrap_or_else(|error| serde_json::json!({"ok": false, "error": error}));
    let code = i32::from(value["ok"] != true);
    if serde_json::to_writer_pretty(&mut output, &value).is_err()
        || output.flush().is_err() || output.sync_all().is_err() { return 1; }
    code
}

pub fn run_if_requested() -> Option<i32> {
    let args: Vec<_> = std::env::args_os().skip(1).collect();
    if args.first().is_none_or(|arg| arg != "--inspect-list") { return None; }
    Some(execute(&args))
}

#[cfg(test)]
#[allow(clippy::unwrap_used, clippy::expect_used, clippy::panic)]
mod tests {
    use super::*;

    fn wav(path: &Path) {
        let mut data = Vec::new();
        data.extend_from_slice(b"RIFF"); data.extend_from_slice(&292_u32.to_le_bytes());
        data.extend_from_slice(b"WAVEfmt "); data.extend_from_slice(&16_u32.to_le_bytes());
        data.extend_from_slice(&1_u16.to_le_bytes()); data.extend_from_slice(&1_u16.to_le_bytes());
        data.extend_from_slice(&44100_u32.to_le_bytes()); data.extend_from_slice(&88200_u32.to_le_bytes());
        data.extend_from_slice(&2_u16.to_le_bytes()); data.extend_from_slice(&16_u16.to_le_bytes());
        data.extend_from_slice(b"data"); data.extend_from_slice(&256_u32.to_le_bytes());
        data.extend_from_slice(&[0; 256]); std::fs::write(path, data).unwrap();
    }

    #[test]
    fn reports_untagged_unicode_audio_without_guessing_artist() {
        let dir = tempfile::tempdir().unwrap();
        let file = dir.path().join("A song — 新.wav"); wav(&file);
        let result = inspect(&[file.to_str().unwrap().into()]);
        assert_eq!(result["ok"], true);
        assert_eq!(result["files"][0]["artist"], "");
        assert_eq!(result["files"][0]["album"], "");
        assert_eq!(result["files"][0]["title"], "A song — 新");
    }

    #[test]
    fn missing_and_unsupported_files_are_errors() {
        let dir = tempfile::tempdir().unwrap();
        let text = dir.path().join("notes.txt"); std::fs::write(&text, "notes").unwrap();
        let result = inspect(&[text.to_str().unwrap().into(), dir.path().join("absent.mp3").to_str().unwrap().into()]);
        assert_eq!(result["ok"], false);
        assert_eq!(result["errors"].as_array().unwrap().len(), 2);
    }

    #[test]
    fn reads_artist_and_album_tags() {
        let dir = tempfile::tempdir().unwrap();
        let file = dir.path().join("tagged.wav"); wav(&file);
        let mut bytes = std::fs::read(&file).unwrap();
        let mut info = b"INFO".to_vec();
        for (id, text) in [(b"IART", "Fixture Artist"), (b"IPRD", "Fixture Album")] {
            let mut value = text.as_bytes().to_vec(); value.push(0);
            info.extend_from_slice(id); info.extend_from_slice(&u32::try_from(value.len()).unwrap().to_le_bytes());
            info.extend_from_slice(&value); if value.len() % 2 != 0 { info.push(0); }
        }
        bytes.extend_from_slice(b"LIST"); bytes.extend_from_slice(&u32::try_from(info.len()).unwrap().to_le_bytes());
        bytes.extend_from_slice(&info);
        let size = u32::try_from(bytes.len() - 8).unwrap(); bytes[4..8].copy_from_slice(&size.to_le_bytes());
        std::fs::write(&file, bytes).unwrap();
        let result = inspect(&[file.to_str().unwrap().into()]);
        assert_eq!(result["files"][0]["artist"], "Fixture Artist");
        assert_eq!(result["files"][0]["album"], "Fixture Album");
    }

    #[test]
    fn exclusive_report_and_bad_input_are_safe() {
        let dir = tempfile::tempdir().unwrap();
        let input = dir.path().join("files.json"); std::fs::write(&input, "not JSON").unwrap();
        let report = dir.path().join("report.json");
        let args = vec!["--inspect-list".into(), input.as_os_str().into(), "--inspect-report".into(), report.as_os_str().into()];
        assert_eq!(execute(&args), 1);
        let first = std::fs::read(&report).unwrap();
        assert_eq!(execute(&args), 1);
        assert_eq!(std::fs::read(report).unwrap(), first);
    }
}
