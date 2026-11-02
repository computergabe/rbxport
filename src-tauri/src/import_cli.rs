//! One-shot automation using the same import and protection paths as the app:
//! `--import` registers files, and `--find-missing` lists tracks whose file is
//! gone and, with `--relocate`, points them at the file found elsewhere.
use std::{ffi::OsString, fs::OpenOptions, io::Write, path::PathBuf, sync::Arc, time::{Duration, Instant}};
use tauri::Manager;

#[derive(Debug, PartialEq, Eq)]
struct Request {
    paths: Vec<String>,
    report: PathBuf,
    /// Analyse the new tracks, and any already-registered ones never analysed.
    analyze: Option<Analyze>,
}

/// How `--analyze` runs: the BPM range (`--analyze-bpm 90-180`; tempos
/// outside it are halved or doubled into it) and whether already-analysed
/// tracks are analysed again (`--reanalyze`).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
struct Analyze {
    bpm: (u16, u16),
    again: bool,
}

impl Default for Analyze {
    /// The Analysis Setting dialog's default range.
    fn default() -> Self {
        Self { bpm: (70, 180), again: false }
    }
}

fn bpm_range(value: &str) -> Result<(u16, u16), String> {
    let invalid = || "Use --analyze-bpm <min>-<max> between 40 and 300, e.g. 90-180".to_owned();
    let (min, max) = value.split_once('-').ok_or_else(invalid)?;
    let (min, max): (u16, u16) = (min.trim().parse().map_err(|_| invalid())?, max.trim().parse().map_err(|_| invalid())?);
    if min < 40 || max > 300 || min >= max { return Err(invalid()); }
    Ok((min, max))
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
    let (mut analyze, mut range, mut again) = (false, None, false);
    let mut index = 0;
    while index < args.len() {
        let flag = &args[index];
        if (flag == "--analyze" && !analyze) || (flag == "--reanalyze" && !again) {
            if flag == "--analyze" { analyze = true } else { again = true }
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
        } else if flag == "--analyze-bpm" && range.is_none() {
            range = Some(bpm_range(&value.to_string_lossy())?);
        } else {
            return Err("Use --import <path> (repeatable), optional --analyze [--analyze-bpm <min>-<max>] [--reanalyze], and --import-report <new JSON file>".into());
        }
        index += 2;
    }
    if !analyze && (range.is_some() || again) {
        return Err("--analyze-bpm and --reanalyze need --analyze".into());
    }
    let analyze = analyze.then(|| Analyze { bpm: range.unwrap_or(Analyze::default().bpm), again });
    Ok(Some(Request { paths, report: report.ok_or("--import-report is required")?, analyze }))
}

pub fn requested() -> bool {
    std::env::args_os().nth(1).is_some_and(|arg| arg == "--import" || arg == "--find-missing")
}

#[derive(Debug, PartialEq, Eq)]
struct MissingRequest {
    /// Folders searched, recursively, for a missing track's file name.
    search: Vec<PathBuf>,
    /// Point each track with one clear match at it.
    relocate: bool,
    report: PathBuf,
}

fn parse_missing(args: &[OsString]) -> Result<Option<MissingRequest>, String> {
    if args.first().is_none_or(|arg| arg != "--find-missing") {
        return Ok(None);
    }
    let usage = || "Use --find-missing <folder> (repeatable), optional --relocate, and --missing-report <new JSON file>".to_owned();
    let (mut search, mut relocate, mut report) = (Vec::new(), false, None);
    let mut index = 0;
    while index < args.len() {
        let flag = &args[index];
        if flag == "--relocate" && !relocate {
            relocate = true;
            index += 1;
            continue;
        }
        let value = args.get(index + 1).filter(|v| !v.to_string_lossy().starts_with("--")).ok_or_else(usage)?;
        if flag == "--find-missing" {
            search.push(PathBuf::from(value));
        } else if flag == "--missing-report" && report.is_none() {
            report = Some(PathBuf::from(value));
        } else {
            return Err(usage());
        }
        index += 2;
    }
    if search.iter().any(|folder| !folder.is_dir()) {
        return Err("A search folder does not exist.".into());
    }
    Ok(Some(MissingRequest { search, relocate, report: report.ok_or_else(usage)? }))
}

/// A track whose file is gone, and where it may have gone.
#[derive(Debug, serde::Serialize)]
#[serde(rename_all = "camelCase")]
struct Missing {
    track_id: String,
    title: String,
    path: String,
    /// Files with the same name in the search folders, same-size ones first.
    candidates: Vec<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    relocated_to: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    error: Option<String>,
}

/// Every file under `folders` whose lower-cased name is in `wanted`. Folders
/// that cannot be read are skipped, as rekordbox's own search does.
fn files_named(folders: &[PathBuf], wanted: &std::collections::HashSet<String>) -> std::collections::HashMap<String, Vec<PathBuf>> {
    let mut found: std::collections::HashMap<String, Vec<PathBuf>> = std::collections::HashMap::new();
    let mut pending: Vec<PathBuf> = folders.to_vec();
    while let Some(folder) = pending.pop() {
        let Ok(entries) = std::fs::read_dir(&folder) else { continue };
        for entry in entries.flatten() {
            let path = entry.path();
            match entry.file_type() {
                Ok(kind) if kind.is_dir() => pending.push(path),
                Ok(kind) if kind.is_file() => {
                    let name = entry.file_name().to_string_lossy().to_lowercase();
                    if wanted.contains(&name) {
                        found.entry(name).or_default().push(path);
                    }
                }
                _ => {}
            }
        }
    }
    found
}

/// Lists tracks whose file does not exist, with same-named files found under
/// `search`, and with `relocate` points each one at its single match: the one
/// file of that name, or the one of them the library's recorded size fits.
fn find_missing<R: tauri::Runtime>(app: &tauri::AppHandle<R>, search: &[PathBuf], relocate: bool) -> Result<Vec<Missing>, String> {
    let state = app.state::<Arc<crate::state::AppState>>();
    if relocate {
        app.state::<Arc<crate::scripting::Bridge>>().refuse_if_protected().map_err(|e| e.message)?;
    }
    let library = state.library().map_err(|e| e.message)?;
    // Only local files can go missing. A streaming track's location is a
    // link such as `spotify:track:…`: a scheme longer than a drive letter.
    let is_link = |path: &str| path.split_once(':').is_some_and(|(scheme, _)| {
        scheme.len() > 1 && scheme.chars().all(|c| c.is_ascii_alphanumeric() || matches!(c, '+' | '-' | '.'))
    });
    let gone: Vec<usize> = (0..library.ids.len())
        .filter(|&row| {
            let path = library.folder_path.get(row);
            !path.is_empty() && !is_link(path) && !std::path::Path::new(path).is_file()
        })
        .collect();
    let name_of = |row: usize| {
        let path = library.folder_path.get(row);
        path.rsplit(['/', '\\']).next().unwrap_or(path).to_lowercase()
    };
    let wanted = gone.iter().map(|&row| name_of(row)).collect();
    let found = files_named(search, &wanted);
    let mut results = Vec::new();
    for row in gone {
        let size = library.file_size.get(row).copied().unwrap_or(0);
        let mut candidates = found.get(&name_of(row)).cloned().unwrap_or_default();
        let same_size = |path: &PathBuf| std::fs::metadata(path).is_ok_and(|m| m.len() == size);
        candidates.sort_by_key(|path| (!same_size(path), path.clone()));
        let sized: Vec<&PathBuf> = candidates.iter().filter(|path| same_size(path)).collect();
        let chosen = match (candidates.as_slice(), sized.as_slice()) {
            ([only], _) => Some(only.clone()),
            (_, [only]) => Some((*only).clone()),
            _ => None,
        };
        let mut missing = Missing {
            track_id: library.ids[row].to_string(),
            title: library.title.get(row).to_owned(),
            path: library.folder_path.get(row).to_owned(),
            candidates: candidates.iter().map(|path| path.to_string_lossy().into_owned()).collect(),
            relocated_to: None,
            error: None,
        };
        if relocate {
            if let Some(target) = chosen {
                match state.write(|writer| writer.relocate(&missing.track_id, &target)) {
                    Ok(_) => missing.relocated_to = Some(target.to_string_lossy().into_owned()),
                    Err(error) => missing.error = Some(crate::commands::write_error(error).message),
                }
            }
        }
        results.push(missing);
    }
    if results.iter().any(|missing| missing.relocated_to.is_some()) {
        tauri::async_runtime::block_on(crate::commands::reload(app.clone(), Arc::clone(&state))).map_err(|e| e.message)?;
    }
    Ok(results)
}

fn start_missing(app: &tauri::AppHandle, request: MissingRequest) -> Result<(), String> {
    let mut output = OpenOptions::new().write(true).create_new(true)
        .open(&request.report).map_err(|e| format!("Cannot create missing-file report: {e}"))?;
    let app = app.clone();
    tauri::async_runtime::spawn_blocking(move || {
        let outcome = prepare(&app, request.relocate).and_then(|_lock| find_missing(&app, &request.search, request.relocate));
        let (value, code) = match outcome {
            Ok(missing) => {
                let relocated = missing.iter().filter(|m| m.relocated_to.is_some()).count();
                (serde_json::json!({ "ok": true, "missing": missing.len(), "relocated": relocated, "tracks": missing }), 0)
            }
            Err(message) => (serde_json::json!({ "ok": false, "error": message }), 1),
        };
        let result = serde_json::to_writer_pretty(&mut output, &value)
            .map_err(|e| e.to_string())
            .and_then(|()| output.flush().map_err(|e| e.to_string()))
            .and_then(|()| output.sync_all().map_err(|e| e.to_string()));
        if let Err(error) = result {
            tracing::error!(%error, "could not publish missing-file report");
            app.exit(1);
        } else {
            app.exit(code);
        }
    });
    Ok(())
}

/// Reserve the report before any write; an old result is never overwritten.
pub fn start(app: &tauri::AppHandle) -> Result<(), String> {
    let args: Vec<_> = std::env::args_os().skip(1).collect();
    if let Some(request) = parse_missing(&args)? {
        return start_missing(app, request);
    }
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

fn execute(app: &tauri::AppHandle, paths: Vec<String>, analyze: Option<Analyze>) -> Result<(crate::dto::ImportReportDto, Vec<Analysed>), String> {
    if paths.iter().any(|path| !std::path::Path::new(path).exists()) {
        return Err("An import path does not exist. No tracks were imported.".into());
    }
    let _lock = prepare(app, true)?;
    protected_import(app, paths, analyze)
}

/// The checks every run makes before touching the library, and the wait for
/// it to load. `writes` adds the rekordbox check: a report alone may be read
/// while rekordbox runs.
fn prepare(app: &tauri::AppHandle, writes: bool) -> Result<ImportLock, String> {
    let cache = app.path().app_cache_dir().map_err(|e| e.to_string())?;
    let lock = acquire_lock(&cache)?;
    // Another GUI process has its own edit gate. Refuse rather than writing
    // concurrently through two unrelated application states.
    let processes = sysinfo::System::new_all();
    if processes.processes().iter().any(|(pid, process)| {
        pid.as_u32() != std::process::id()
            && process.name().to_string_lossy().to_ascii_lowercase().starts_with("rbxport")
    }) {
        return Err("Close other RBXPORT windows before running an automated import.".into());
    }
    if writes && rbl_db::is_rekordbox_running() {
        return Err("Close rekordbox before importing with RBXPORT.".into());
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
    Ok(lock)
}

fn protected_import<R: tauri::Runtime>(app: &tauri::AppHandle<R>, paths: Vec<String>, analyze: Option<Analyze>) -> Result<(crate::dto::ImportReportDto, Vec<Analysed>), String> {
    app.state::<Arc<crate::scripting::Bridge>>().refuse_if_protected().map_err(|e| e.message)?;
    let report = tauri::async_runtime::block_on(crate::commands::import_files(app.clone(), app.state::<Arc<crate::state::AppState>>(), paths))
        .map_err(|e| e.message)?;
    let analysis = match analyze { Some(options) => analyse(app, &report, options)?, None => Vec::new() };
    Ok((report, analysis))
}

/// Analyses what the import added, plus files it found already registered
/// but never analysed, so a retry finishes an interrupted run, and ones whose
/// analysis files still carry the full-path `PPTH` releases before the
/// share-tree fix wrote, which rekordbox reads as having no beat grid.
/// With `--reanalyze`, every registered track given is analysed again.
fn analyse<R: tauri::Runtime>(app: &tauri::AppHandle<R>, report: &crate::dto::ImportReportDto, options: Analyze) -> Result<Vec<Analysed>, String> {
    let state = app.state::<Arc<crate::state::AppState>>();
    let editor = app.state::<Arc<crate::grid::GridEditor>>();
    let library = state.library().map_err(|e| e.message)?;
    let share = state.share_root();
    let needs_analysis = |id: &str| library.row_of(id).is_some_and(|row| {
        let row = row as usize;
        if options.again {
            return true;
        }
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
        let outcome = crate::analysis::analyse_imported(&state, &library, &track.id, &editor, options.bpm);
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
        assert_eq!(request.analyze, None);
        let analysed = parse(&arguments(&["--import", "a.wav", "--analyze", "--import-report", "r.json"])).unwrap().unwrap();
        assert_eq!(analysed.analyze, Some(Analyze::default()));
        assert_eq!(analysed.paths, ["a.wav"]);
        let ranged = parse(&arguments(&["--import", "a.wav", "--analyze", "--analyze-bpm", "90-180", "--reanalyze", "--import-report", "r.json"])).unwrap().unwrap();
        assert_eq!(ranged.analyze, Some(Analyze { bpm: (90, 180), again: true }));
    }

    #[test]
    fn rejects_missing_report_and_ambiguous_options() {
        for values in [vec!["--import"], vec!["--import", "album"], vec!["--import", "--import-report"], vec!["--import", "album", "--watch", "yes"], vec!["--import", "album", "--import-report", "one", "--import-report", "two"], vec!["--import", "a", "--analyze", "--analyze", "--import-report", "r"], vec!["--import", "a", "--analyze-bpm", "90-180", "--import-report", "r"], vec!["--import", "a", "--analyze", "--analyze-bpm", "180-90", "--import-report", "r"], vec!["--import", "a", "--analyze", "--analyze-bpm", "20-400", "--import-report", "r"]] {
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
        assert!(protected_import(app.handle(), paths.clone(), None).is_err());
        for protected in [true, false] {
            tauri::async_runtime::block_on(crate::scripting::script_preferences(
                app.state(), serde_json::json!({"advanced": {"protectLibrary": protected}}),
            )).unwrap();
            let result = protected_import(app.handle(), paths.clone(), None);
            if protected {
                assert!(result.is_err());
            } else {
                assert_eq!(result.unwrap().0.imported, 1);
            }
        }
        let (retry, _) = protected_import(app.handle(), paths, None).unwrap();
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
        let (report, analysis) = protected_import(app.handle(), paths.clone(), Some(Analyze::default())).unwrap();
        assert_eq!(report.imported, 1);
        assert_eq!(analysis.len(), 1);
        assert!(analysis[0].ok, "{:?}", analysis[0].error);
        let library = app.state::<Arc<crate::state::AppState>>().library().unwrap();
        let row = library.row_of(&report.tracks[0].id).unwrap() as usize;
        assert_eq!(library.analysed[row], 1, "the index marks analysed rows with 1");
        // Already registered and analysed: a retry analyses nothing again.
        let (retry, again) = protected_import(app.handle(), paths.clone(), Some(Analyze::default())).unwrap();
        assert_eq!(retry.existing.len(), 1);
        assert!(again.is_empty());
        // --reanalyze analyses it again, here in a range that excludes its
        // 120 BPM, so the tempo is halved into it.
        let (_, redone) = protected_import(app.handle(), paths, Some(Analyze { bpm: (40, 100), again: true })).unwrap();
        assert_eq!(redone.len(), 1);
        assert!(redone[0].ok, "{:?}", redone[0].error);
        let library = app.state::<Arc<crate::state::AppState>>().library().unwrap();
        let row = library.row_of(&report.tracks[0].id).unwrap() as usize;
        assert_eq!(library.bpm_x100[row], 6000);
    }

    #[test]
    fn find_missing_options_parse_and_reject_ambiguity() {
        let dir = tempfile::tempdir().unwrap();
        let folder = dir.path().to_str().unwrap();
        let request = parse_missing(&arguments(&["--find-missing", folder, "--relocate", "--missing-report", "r.json"])).unwrap().unwrap();
        assert_eq!(request, MissingRequest { search: vec![PathBuf::from(folder)], relocate: true, report: PathBuf::from("r.json") });
        assert_eq!(parse_missing(&arguments(&["--import", "a"])).unwrap(), None);
        for values in [vec!["--find-missing", folder], vec!["--find-missing", folder, "--missing-report", "a", "--missing-report", "b"],
            vec!["--find-missing", "Z:/no/such/folder", "--missing-report", "r"], vec!["--find-missing", folder, "--relocate", "--relocate", "--missing-report", "r"]] {
            assert!(parse_missing(&arguments(&values)).is_err(), "{values:?}");
        }
    }

    #[test]
    fn missing_tracks_are_found_by_name_and_relocated_once_clear() {
        let dir = tempfile::tempdir().unwrap();
        let location = rbl_db::fixture::build(dir.path(), rbl_db::fixture::Shape::default()).unwrap();
        // A streaming track has a link, not a path, and is never missing.
        rbl_db::Library::open(location.clone(), rbl_db::OpenMode::ReadWrite).unwrap().connection()
            .execute("UPDATE djmdContent SET FolderPath = 'spotify:track:0hCsE7a9y1zPrbDT0m59Mz' WHERE ID = ?1", [rbl_db::fixture::track_id(2)])
            .unwrap();
        let db = rbl_db::Library::open(location.clone(), rbl_db::OpenMode::ReadOnly).unwrap();
        let (library, _) = rbl_index::load(&db).unwrap();
        let state = crate::state::AppState::with_backups(dir.path().join("backups"));
        state.set_library(library, false, db.schema().db_version, 0, location);
        let app = tauri::test::mock_app();
        app.manage(Arc::new(state));
        app.manage(Arc::new(crate::scripting::Bridge::default()));
        tauri::async_runtime::block_on(crate::scripting::script_preferences(
            app.state(), serde_json::json!({"advanced": {"protectLibrary": false}}),
        )).unwrap();
        // No other fixture track's file exists. Put track 0's file, by name, under
        // a search folder, and two copies of track 1's.
        let library = app.state::<Arc<crate::state::AppState>>().library().unwrap();
        let name = |row: usize| { let p = library.folder_path.get(row); p.rsplit(['/', '\\']).next().unwrap().to_owned() };
        let found = dir.path().join("moved");
        std::fs::create_dir_all(found.join("a")).unwrap();
        std::fs::create_dir_all(found.join("b")).unwrap();
        std::fs::write(found.join("a").join(name(0)), b"zero").unwrap();
        std::fs::write(found.join("a").join(name(1)), b"one").unwrap();
        std::fs::write(found.join("b").join(name(1)), b"one again").unwrap();
        let listed = find_missing(app.handle(), &[found.clone()], false).unwrap();
        assert_eq!(listed.len(), library.ids.len() - 1);
        assert!(listed.iter().all(|m| !m.path.starts_with("spotify:")));
        assert!(listed.iter().all(|m| m.relocated_to.is_none()));
        let first = listed.iter().find(|m| m.track_id == library.ids[0].to_string()).unwrap();
        assert_eq!(first.candidates.len(), 1);
        let relocated = find_missing(app.handle(), &[found.clone()], true).unwrap();
        let moved: Vec<&Missing> = relocated.iter().filter(|m| m.relocated_to.is_some()).collect();
        // Track 0 has one match; track 1 has two of the wrong size and stays.
        assert_eq!(moved.len(), 1);
        assert_eq!(moved[0].track_id, library.ids[0].to_string());
        let after = app.state::<Arc<crate::state::AppState>>().library().unwrap();
        let row = after.row_of(&library.ids[0].to_string()).unwrap() as usize;
        assert_eq!(std::path::Path::new(after.folder_path.get(row)), found.join("a").join(name(0)));
        assert_eq!(find_missing(app.handle(), &[found], false).unwrap().len(), library.ids.len() - 2);
    }
}
