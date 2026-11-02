//! One-shot automation using the same import and protection paths as the app.
use std::{ffi::OsString, fs::OpenOptions, io::Write, path::PathBuf, sync::Arc, time::{Duration, Instant}};
use tauri::Manager;

#[derive(Debug, PartialEq, Eq)]
struct Request {
    paths: Vec<String>,
    report: PathBuf,
    /// Analyse the new tracks, and any already-registered ones never analysed.
    analyze: bool,
}

/// One track's analysis, for the report. A failure leaves the track imported
/// but unanalysed; it does not fail the import.
#[derive(Debug, serde::Serialize)]
#[serde(rename_all = "camelCase")]
struct Analysed {
    track_id: String,
    title: String,
    ok: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    error: Option<String>,
}

struct ImportLock(PathBuf);

impl Drop for ImportLock {
    fn drop(&mut self) {
        let _ = std::fs::remove_file(&self.0);
    }
}

fn acquire_lock(cache: &std::path::Path) -> Result<ImportLock, String> {
    std::fs::create_dir_all(cache).map_err(|e| e.to_string())?;
    let path = cache.join("automation-import.lock");
    let file = OpenOptions::new().write(true).create_new(true).open(&path)
        .map_err(|e| format!("Cannot acquire import lock (another import or an interrupted run): {e}"))?;
    drop(file);
    Ok(ImportLock(path))
}

fn parse(args: &[OsString]) -> Result<Option<Request>, String> {
    if args.first().is_none_or(|arg| arg != "--import") {
        return Ok(None);
    }
    let mut paths = Vec::new();
    let mut report = None;
    let mut analyze = false;
    let mut index = 0;
    while index < args.len() {
        let flag = &args[index];
        if flag == "--analyze" && !analyze {
            analyze = true;
            index += 1;
            continue;
        }
        let value = args.get(index + 1).ok_or("Each option needs a value")?;
        if value.to_string_lossy().starts_with("--") {
            return Err("Each option needs a path value".into());
        }
        if flag == "--import" {
            paths.push(value.to_str().ok_or("Import path is not valid Unicode")?.to_owned());
        } else if flag == "--import-report" && report.is_none() {
            report = Some(PathBuf::from(value));
        } else {
            return Err("Use --import <path> (repeatable), optional --analyze, and --import-report <new JSON file>".into());
        }
        index += 2;
    }
    Ok(Some(Request { paths, report: report.ok_or("--import-report is required")?, analyze }))
}

pub fn requested() -> bool {
    std::env::args_os().nth(1).is_some_and(|arg| arg == "--import")
}

/// Reserve the report before any write; an old result is never overwritten.
pub fn start(app: &tauri::AppHandle) -> Result<(), String> {
    let args: Vec<_> = std::env::args_os().skip(1).collect();
    let Some(request) = parse(&args)? else { return Ok(()) };
    let mut output = OpenOptions::new().write(true).create_new(true)
        .open(&request.report).map_err(|e| format!("Cannot create import report: {e}"))?;
    let app = app.clone();
    tauri::async_runtime::spawn_blocking(move || {
        let outcome = execute(&app, request.paths, request.analyze);
        let (value, code) = match outcome {
            Ok((report, analysis)) => {
                let complete = report.skipped.is_empty();
                (serde_json::json!({ "ok": complete, "report": report, "analysis": analysis }), i32::from(!complete))
            }
            Err(message) => (serde_json::json!({ "ok": false, "error": message }), 1),
        };
        let result = serde_json::to_writer_pretty(&mut output, &value)
            .map_err(|e| e.to_string())
            .and_then(|()| output.flush().map_err(|e| e.to_string()))
            .and_then(|()| output.sync_all().map_err(|e| e.to_string()));
        if let Err(error) = result {
            tracing::error!(%error, "could not publish import report");
            app.exit(1);
        } else {
            app.exit(code);
        }
    });
    Ok(())
}

fn execute(app: &tauri::AppHandle, paths: Vec<String>, analyze: bool) -> Result<(crate::dto::ImportReportDto, Vec<Analysed>), String> {
    let cache = app.path().app_cache_dir().map_err(|e| e.to_string())?;
    let _lock = acquire_lock(&cache)?;
    // Another GUI process has its own edit gate. Refuse rather than writing
    // concurrently through two unrelated application states.
    let processes = sysinfo::System::new_all();
    if processes.processes().iter().any(|(pid, process)| {
        pid.as_u32() != std::process::id()
            && process.name().to_string_lossy().to_ascii_lowercase().starts_with("rbxport")
    }) {
        return Err("Close other RBXPORT windows before running an automated import.".into());
    }
    if rbl_db::is_rekordbox_running() {
        return Err("Close rekordbox before importing with RBXPORT.".into());
    }
    if paths.iter().any(|path| !std::path::Path::new(path).exists()) {
        return Err("An import path does not exist. No tracks were imported.".into());
    }
    let state = app.state::<Arc<crate::state::AppState>>();
    let bridge = app.state::<Arc<crate::scripting::Bridge>>();
    let started = Instant::now();
    // Startup only: wait for both the read-only library and the window's
    // preferences mirror. Never assume unknown protection means permission.
    loop {
        if let Some(problem) = state.library_problem() {
            return Err(format!("Library could not load: {problem:?}"));
        }
        if state.library().is_ok() && bridge.preferences().is_some() {
            break;
        }
        if started.elapsed() > Duration::from_secs(120) {
            return Err("Timed out loading the library or its protection settings.".into());
        }
        std::thread::sleep(Duration::from_millis(100));
    }
    protected_import(app, paths, analyze)
}

fn protected_import<R: tauri::Runtime>(app: &tauri::AppHandle<R>, paths: Vec<String>, analyze: bool) -> Result<(crate::dto::ImportReportDto, Vec<Analysed>), String> {
    app.state::<Arc<crate::scripting::Bridge>>().refuse_if_protected().map_err(|e| e.message)?;
    let report = tauri::async_runtime::block_on(crate::commands::import_files(app.clone(), app.state::<Arc<crate::state::AppState>>(), paths))
        .map_err(|e| e.message)?;
    let analysis = if analyze { analyse(app, &report)? } else { Vec::new() };
    Ok((report, analysis))
}

/// Analyses what the import added, plus files it found already registered
/// but never analysed, so a retry finishes an interrupted run, and ones whose
/// analysis files still carry the full-path `PPTH` releases before the
/// share-tree fix wrote, which rekordbox reads as having no beat grid.
fn analyse<R: tauri::Runtime>(app: &tauri::AppHandle<R>, report: &crate::dto::ImportReportDto) -> Result<Vec<Analysed>, String> {
    let state = app.state::<Arc<crate::state::AppState>>();
    let editor = app.state::<Arc<crate::grid::GridEditor>>();
    let library = state.library().map_err(|e| e.message)?;
    let share = state.share_root();
    let needs_analysis = |id: &str| library.row_of(id).is_some_and(|row| {
        let row = row as usize;
        if library.analysed.get(row).copied().unwrap_or(0) == 0 {
            return true;
        }
        let relative = library.analysis_path.get(row);
        !relative.is_empty() && rbl_anlz::Anlz::read(&rbl_anlz::resolve(&share, relative))
            .ok()
            .and_then(|dat| dat.path())
            .is_some_and(|ppth| !ppth.starts_with("?/"))
    });
    let mut results = Vec::new();
    for track in report.tracks.iter().chain(report.existing.iter().filter(|track| needs_analysis(&track.id))) {
        let outcome = crate::analysis::analyse_imported(&state, &library, &track.id, &editor);
        if let Err(error) = &outcome {
            tracing::warn!(track = %track.id, error = %error.message, "automated analysis failed");
        }
        results.push(Analysed { track_id: track.id.clone(), title: track.title.clone(), ok: outcome.is_ok(), error: outcome.err().map(|e| e.message) });
    }
    if results.iter().any(|result| result.ok) {
        tauri::async_runtime::block_on(crate::commands::reload(app.clone(), Arc::clone(&state))).map_err(|e| e.message)?;
    }
    Ok(results)
}

#[cfg(test)]
#[allow(clippy::unwrap_used, clippy::expect_used, clippy::panic)]
mod tests {
    use super::*;

    fn arguments(values: &[&str]) -> Vec<OsString> {
        values.iter().map(OsString::from).collect()
    }

    #[test]
    fn ordinary_launch_is_unchanged() {
        assert_eq!(parse(&[]).unwrap(), None);
    }

    #[test]
    fn accepts_multiple_unicode_paths_and_spaces() {
        let request = parse(&arguments(&["--import", "C:/Music/新 album", "--import", "C:/Music/b.wav", "--import-report", "C:/reports/new.json"])).unwrap().unwrap();
        assert_eq!(request.paths, ["C:/Music/新 album", "C:/Music/b.wav"]);
        assert_eq!(request.report, PathBuf::from("C:/reports/new.json"));
        assert!(!request.analyze);
        let analysed = parse(&arguments(&["--import", "a.wav", "--analyze", "--import-report", "r.json"])).unwrap().unwrap();
        assert!(analysed.analyze);
        assert_eq!(analysed.paths, ["a.wav"]);
    }

    #[test]
    fn rejects_missing_report_and_ambiguous_options() {
        for values in [vec!["--import"], vec!["--import", "album"], vec!["--import", "--import-report"], vec!["--import", "album", "--watch", "yes"], vec!["--import", "album", "--import-report", "one", "--import-report", "two"], vec!["--import", "a", "--analyze", "--analyze", "--import-report", "r"]] {
            assert!(parse(&arguments(&values)).is_err());
        }
    }

    #[test]
    fn overlapping_imports_are_refused_and_lock_is_released() {
        let dir = tempfile::tempdir().unwrap();
        let first = acquire_lock(dir.path()).unwrap();
        assert!(acquire_lock(dir.path()).is_err());
        drop(first);
        assert!(acquire_lock(dir.path()).is_ok());
    }

    #[test]
    fn interrupted_run_requires_explicit_recovery() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("automation-import.lock");
        std::fs::write(&path, "").unwrap();
        assert!(acquire_lock(dir.path()).is_err());
        assert!(path.exists());
    }

    #[test]
    fn fixture_import_honours_protection_and_retry_skips_existing_tracks() {
        let dir = tempfile::tempdir().unwrap();
        let location = rbl_db::fixture::build(dir.path(), rbl_db::fixture::Shape::default()).unwrap();
        let db = rbl_db::Library::open(location.clone(), rbl_db::OpenMode::ReadOnly).unwrap();
        let (library, _) = rbl_index::load(&db).unwrap();
        let state = crate::state::AppState::with_backups(dir.path().join("backups"));
        state.set_library(library, false, db.schema().db_version, 0, location);
        let app = tauri::test::mock_app();
        app.manage(Arc::new(state));
        app.manage(Arc::new(crate::scripting::Bridge::default()));
        let path = dir.path().join("new track.wav");
        let mut wav = Vec::new();
        let size = 44100_u32 * 4;
        wav.extend_from_slice(b"RIFF");
        wav.extend_from_slice(&(36 + size).to_le_bytes());
        wav.extend_from_slice(b"WAVEfmt ");
        wav.extend_from_slice(&16_u32.to_le_bytes());
        wav.extend_from_slice(&1_u16.to_le_bytes());
        wav.extend_from_slice(&2_u16.to_le_bytes());
        wav.extend_from_slice(&44100_u32.to_le_bytes());
        wav.extend_from_slice(&(44100_u32 * 4).to_le_bytes());
        wav.extend_from_slice(&4_u16.to_le_bytes());
        wav.extend_from_slice(&16_u16.to_le_bytes());
        wav.extend_from_slice(b"data");
        wav.extend_from_slice(&size.to_le_bytes());
        wav.resize(44 + size as usize, 0);
        std::fs::write(&path, wav).unwrap();
        let paths = vec![path.to_str().unwrap().to_owned()];
        // Unknown protection must refuse before opening a writer.
        assert!(protected_import(app.handle(), paths.clone(), false).is_err());
        for protected in [true, false] {
            tauri::async_runtime::block_on(crate::scripting::script_preferences(
                app.state(), serde_json::json!({"advanced": {"protectLibrary": protected}}),
            )).unwrap();
            let result = protected_import(app.handle(), paths.clone(), false);
            if protected {
                assert!(result.is_err());
            } else {
                assert_eq!(result.unwrap().0.imported, 1);
            }
        }
        let (retry, _) = protected_import(app.handle(), paths, false).unwrap();
        assert_eq!(retry.imported, 0);
        assert_eq!(retry.existing.len(), 1);
        assert_eq!(retry.skipped, [] as [String; 0]);
    }

    #[test]
    fn analyze_flag_analyses_new_tracks_once() {
        let dir = tempfile::tempdir().unwrap();
        let location = rbl_db::fixture::build(dir.path(), rbl_db::fixture::Shape::default()).unwrap();
        let db = rbl_db::Library::open(location.clone(), rbl_db::OpenMode::ReadOnly).unwrap();
        let (library, _) = rbl_index::load(&db).unwrap();
        let state = crate::state::AppState::with_backups(dir.path().join("backups"));
        state.set_library(library, false, db.schema().db_version, 0, location);
        let app = tauri::test::mock_app();
        app.manage(Arc::new(state));
        app.manage(Arc::new(crate::scripting::Bridge::default()));
        app.manage(Arc::new(crate::grid::GridEditor::at(&dir.path().join("editor"))));
        tauri::async_runtime::block_on(crate::scripting::script_preferences(
            app.state(), serde_json::json!({"advanced": {"protectLibrary": false}}),
        )).unwrap();
        let path = dir.path().join("click track.wav");
        crate::analysis::tests::write_click_wav(&path, 20, 0.5);
        let paths = vec![path.to_str().unwrap().to_owned()];
        let (report, analysis) = protected_import(app.handle(), paths.clone(), true).unwrap();
        assert_eq!(report.imported, 1);
        assert_eq!(analysis.len(), 1);
        assert!(analysis[0].ok, "{:?}", analysis[0].error);
        let library = app.state::<Arc<crate::state::AppState>>().library().unwrap();
        let row = library.row_of(&report.tracks[0].id).unwrap() as usize;
        assert_eq!(library.analysed[row], 1, "the index marks analysed rows with 1");
        // Already registered and analysed: a retry analyses nothing again.
        let (retry, again) = protected_import(app.handle(), paths, true).unwrap();
        assert_eq!(retry.existing.len(), 1);
        assert!(again.is_empty());
    }
}
