//! One-shot automation using the same import and protection paths as the app.
use std::{ffi::OsString, fs::OpenOptions, io::Write, path::PathBuf, sync::Arc, time::{Duration, Instant}};
use tauri::Manager;

#[derive(Debug, PartialEq, Eq)]
struct Request {
    paths: Vec<String>,
    report: PathBuf,
}

struct ImportLock(PathBuf);

impl Drop for ImportLock {
    fn drop(&mut self) {
        let _ = std::fs::remove_file(&self.0);
    }
}

fn parse(args: &[OsString]) -> Result<Option<Request>, String> {
    if args.first().is_none_or(|arg| arg != "--import") {
        return Ok(None);
    }
    let mut paths = Vec::new();
    let mut report = None;
    let mut index = 0;
    while index < args.len() {
        let flag = &args[index];
        let value = args.get(index + 1).ok_or("Each option needs a value")?;
        if value.to_string_lossy().starts_with("--") {
            return Err("Each option needs a path value".into());
        }
        if flag == "--import" {
            paths.push(value.to_str().ok_or("Import path is not valid Unicode")?.to_owned());
        } else if flag == "--import-report" && report.is_none() {
            report = Some(PathBuf::from(value));
        } else {
            return Err("Use --import <path> (repeatable) and --import-report <new JSON file>".into());
        }
        index += 2;
    }
    Ok(Some(Request { paths, report: report.ok_or("--import-report is required")? }))
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
        let outcome = execute(&app, request.paths);
        let (value, code) = match outcome {
            Ok(report) => {
                let complete = report.skipped.is_empty();
                (serde_json::json!({ "ok": complete, "report": report }), i32::from(!complete))
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

fn execute(app: &tauri::AppHandle, paths: Vec<String>) -> Result<crate::dto::ImportReportDto, String> {
    let cache = app.path().app_cache_dir().map_err(|e| e.to_string())?;
    std::fs::create_dir_all(&cache).map_err(|e| e.to_string())?;
    let lock_path = cache.join("automation-import.lock");
    let _file = OpenOptions::new().write(true).create_new(true).open(&lock_path)
        .map_err(|e| format!("Cannot acquire import lock (another import or an interrupted run): {e}"))?;
    let _lock = ImportLock(lock_path);
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
    bridge.refuse_if_protected().map_err(|e| e.message)?;
    tauri::async_runtime::block_on(crate::commands::import_files(app.clone(), state, paths))
        .map_err(|e| e.message)
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
    }

    #[test]
    fn rejects_missing_report_and_ambiguous_options() {
        for values in [vec!["--import"], vec!["--import", "album"], vec!["--import", "--import-report"], vec!["--import", "album", "--watch", "yes"], vec!["--import", "album", "--import-report", "one", "--import-report", "two"]] {
            assert!(parse(&arguments(&values)).is_err());
        }
    }
}
