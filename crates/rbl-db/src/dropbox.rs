//! This machine's Dropbox folder, found the way rekordbox finds it.
//!
//! [OBS rekordbox 7.2.19 macOS arm64, static] `DropBox::localPublicPath`
//! @0x10102cdc0 returns a cached folder, or `checklocalPublicPath`
//! @0x10102ce14 (to 0x10102d14c), which:
//!
//! 1. reads the `DropboxSharingPath` setting from `rekordbox3.settings`;
//! 2. if it is empty or names nothing that exists (`juce::File::exists`),
//!    takes `localPersonalPath`, else `localBusinessPath`;
//! 3. if it exists but `rb::FileHelper::isSymlink` @0x10240e79c holds (the
//!    real path, `juce_getRealPath`, is absolute and is not the same file
//!    name), takes `localBusinessPath`, else `localPersonalPath`, else
//!    nothing;
//! 4. keeps the result only if it is an absolute path, then caches it and
//!    writes it back to `DropboxSharingPath` (`setStringValue` @0x10102d0cc).
//!
//! `localPersonalPath` / `localBusinessPath` (@0x10102d478 / @0x10102d2b8)
//! call `get_local_public_path` @0x10102d654, which parses
//! `<home>/.dropbox/info.json` (`getSpecialLocation(userHomeDirectory)`) and
//! returns `personal.path` / `business.path` when it is an absolute path.
//! That file is the Dropbox desktop app's own record of its folders.
//!
//! rbxport finds the same folder but never writes it back: rekordbox's
//! settings stay rekordbox's. [ASSUME] Step 4 also replaces the result with
//! the path the file system reports for its file id when the two name the
//! same file under different letter case (`getFileIdentifier`,
//! `getFilePathFromID`); that is not modelled, as every comparison made
//! with the folder ignores case. [UNKNOWN] What the Windows build reads:
//! only the macOS binary was read, and the same `<home>/.dropbox/info.json`
//! is used on every platform here.

use std::path::{Path, PathBuf};

/// The Dropbox desktop app's folders as `~/.dropbox/info.json` records
/// them: absolute paths only, as `get_local_public_path` keeps them.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct DropboxInfo {
    pub personal: Option<String>,
    pub business: Option<String>,
}

impl DropboxInfo {
    /// Parses the text of `info.json`. Anything unreadable is "no folder".
    #[must_use]
    pub fn parse(text: &str) -> Self {
        let Ok(json) = serde_json::from_str::<serde_json::Value>(text) else {
            return Self::default();
        };
        let path = |account: &str| {
            json.get(account)
                .and_then(|a| a.get("path"))
                .and_then(serde_json::Value::as_str)
                .filter(|p| Path::new(p).is_absolute())
                .map(str::to_owned)
        };
        Self { personal: path("personal"), business: path("business") }
    }

    /// Reads `<home>/.dropbox/info.json`; no file is no folder.
    #[must_use]
    pub fn read(home: &Path) -> Self {
        std::fs::read_to_string(info_json(home)).map(|t| Self::parse(&t)).unwrap_or_default()
    }
}

/// `<home>/.dropbox/info.json`.
#[must_use]
pub fn info_json(home: &Path) -> PathBuf {
    home.join(".dropbox").join("info.json")
}

/// `DropBox::checklocalPublicPath` without the write-back: the folder
/// rekordbox uses for Dropbox given the `DropboxSharingPath` setting and
/// Dropbox's own record. `None` when there is none.
#[must_use]
pub fn check_local_public_path(setting: &str, info: &DropboxInfo) -> Option<String> {
    let personal = info.personal.as_deref().filter(|p| !p.is_empty());
    let business = info.business.as_deref().filter(|p| !p.is_empty());
    let chosen = if setting.is_empty() || !Path::new(setting).exists() {
        personal.or(business)
    } else if is_symlink(Path::new(setting)) {
        business.or(personal)
    } else {
        Some(setting)
    };
    chosen.filter(|p| Path::new(p).is_absolute()).map(str::to_owned)
}

/// `rb::FileHelper::isSymlink`: the path's real path is absolute and names
/// another file than the path itself. juce compares file names ignoring
/// case on macOS and Windows, and drops a trailing separator.
fn is_symlink(path: &Path) -> bool {
    let Ok(real) = std::fs::canonicalize(path) else {
        return false;
    };
    if !real.is_absolute() {
        return false;
    }
    #[cfg(windows)]
    {
        // Canonical Windows paths can expand short names and add a verbatim
        // prefix. Those spelling changes are not links. Inspect the path and
        // its parents instead; FileType detects symlinks and junctions.
        path.ancestors().any(|part| {
            std::fs::symlink_metadata(part).is_ok_and(|metadata| metadata.file_type().is_symlink())
        })
    }
    #[cfg(not(windows))]
    {
        let trim = |p: &Path| p.to_string_lossy().trim_end_matches(['/', '\\']).to_owned();
        let (real, path) = (trim(&real), trim(path));
        if cfg!(target_os = "macos") {
            real.to_lowercase() != path.to_lowercase()
        } else {
            real != path
        }
    }
}

/// This machine's Dropbox folder as rekordbox would use it: from
/// `rekordbox3.settings` and `~/.dropbox/info.json`. Not cached.
#[must_use]
pub fn local_public_path() -> Option<String> {
    let setting = rbl_core::paths::rekordbox_setting("DropboxSharingPath").unwrap_or_default();
    let info = dirs::home_dir().map(|home| DropboxInfo::read(&home)).unwrap_or_default();
    check_local_public_path(&setting, &info)
}

#[cfg(test)]
#[allow(clippy::unwrap_used)]
mod tests {
    use super::*;

    fn info(personal: Option<&Path>, business: Option<&Path>) -> DropboxInfo {
        let s = |p: Option<&Path>| p.map(|p| p.to_string_lossy().into_owned());
        DropboxInfo { personal: s(personal), business: s(business) }
    }

    fn s(p: &Path) -> String {
        p.to_string_lossy().into_owned()
    }

    #[test]
    fn info_json_gives_absolute_personal_and_business_paths() {
        let home = tempfile::tempdir().unwrap();
        let personal = home.path().join("Library/CloudStorage/Dropbox");
        let text = serde_json::json!({"personal": {"path": personal, "host": 1}, "business": {"path": "relative/Team"}}).to_string();
        let parsed = DropboxInfo::parse(&text);
        assert_eq!(parsed.personal.as_deref(), personal.to_str());
        assert_eq!(parsed.business, None, "a relative path is not a folder");
        assert_eq!(DropboxInfo::parse("not json"), DropboxInfo::default());
        assert_eq!(DropboxInfo::parse(r#"{"personal": {}}"#), DropboxInfo::default());
    }

    #[test]
    fn info_json_is_read_from_the_home_folder() {
        let home = tempfile::tempdir().unwrap();
        assert_eq!(DropboxInfo::read(home.path()), DropboxInfo::default());
        std::fs::create_dir_all(home.path().join(".dropbox")).unwrap();
        let business = home.path().join("Team Dropbox");
        std::fs::write(info_json(home.path()), serde_json::json!({"business": {"path": business}}).to_string()).unwrap();
        assert_eq!(DropboxInfo::read(home.path()).business.as_deref(), business.to_str());
    }

    #[test]
    fn an_existing_plain_setting_wins() {
        let dir = tempfile::tempdir().unwrap();
        let setting = dir.path().canonicalize().unwrap();
        let other = info(Some(Path::new("/elsewhere/personal")), Some(Path::new("/elsewhere/business")));
        assert_eq!(check_local_public_path(&s(&setting), &other), Some(s(&setting)));
    }

    #[test]
    fn an_empty_or_missing_setting_falls_back_to_personal_then_business() {
        let root = tempfile::tempdir().unwrap();
        let personal = root.path().join("p/Dropbox");
        let business = root.path().join("b/Dropbox (Team)");
        let both = info(Some(&personal), Some(&business));
        let business_only = info(None, Some(&business));
        // The reporter's likely case: rekordbox never stored a folder.
        assert_eq!(check_local_public_path("", &both), Some(s(&personal)));
        assert_eq!(check_local_public_path("", &business_only), Some(s(&business)));
        // A stale setting is treated like none.
        let missing = root.path().join("missing/Dropbox");
        let gone = missing.to_str().unwrap();
        assert_eq!(check_local_public_path(gone, &both), Some(s(&personal)));
        // No setting and no Dropbox app: no folder.
        assert_eq!(check_local_public_path("", &DropboxInfo::default()), None);
        assert_eq!(check_local_public_path(gone, &DropboxInfo::default()), None);
    }

    #[cfg(windows)]
    #[test]
    fn ordinary_windows_setting_is_not_a_symlink() {
        let root = tempfile::tempdir().unwrap();
        let setting = root.path().join("My Dropbox");
        std::fs::create_dir(&setting).unwrap();
        let fallback = root.path().join("Other Dropbox");
        let other = info(Some(&fallback), Some(&fallback));
        for spelling in [s(&setting), s(&setting).replace('\\', "/")] {
            assert!(!is_symlink(Path::new(&spelling)));
            assert_eq!(check_local_public_path(&spelling, &other), Some(spelling));
        }
    }

    #[cfg(windows)]
    #[test]
    fn a_windows_junction_and_its_children_use_the_business_fallback() {
        let root = tempfile::tempdir().unwrap();
        let real = root.path().join("Real Dropbox");
        let link = root.path().join("Linked Dropbox");
        let business = root.path().join("Business Dropbox");
        std::fs::create_dir(&real).unwrap();
        std::fs::create_dir(real.join("rekordbox")).unwrap();
        let status = std::process::Command::new("cmd")
            .args(["/C", "mklink", "/J"]).arg(&link).arg(&real).output().unwrap();
        assert!(status.status.success(), "{}", String::from_utf8_lossy(&status.stderr));
        assert!(!is_symlink(&real));
        assert!(is_symlink(&link));
        assert!(is_symlink(&link.join("rekordbox")));
        assert_eq!(check_local_public_path(&s(&link), &info(Some(&real), Some(&business))), Some(s(&business)));
        assert_eq!(check_local_public_path(&s(&link), &info(Some(&real), None)), Some(s(&real)));
        assert_eq!(check_local_public_path(&s(&link), &DropboxInfo::default()), None);
    }

    #[cfg(unix)]
    #[test]
    fn a_symlinked_setting_is_detected_again_business_first() {
        let dir = tempfile::tempdir().unwrap();
        let root = dir.path().canonicalize().unwrap();
        let real = root.join("CloudStorage/Dropbox");
        std::fs::create_dir_all(&real).unwrap();
        let link = root.join("Dropbox");
        std::os::unix::fs::symlink(&real, &link).unwrap();
        let both = info(Some(&real), Some(Path::new("/b/Team")));
        assert_eq!(check_local_public_path(&s(&link), &both).as_deref(), Some("/b/Team"));
        assert_eq!(check_local_public_path(&s(&link), &info(Some(&real), None)), Some(s(&real)));
        // A symlink and no Dropbox record: rekordbox clears the folder.
        assert_eq!(check_local_public_path(&s(&link), &DropboxInfo::default()), None);
        // A folder under a symlinked parent counts too: its real path differs.
        let inner = link.join("rekordbox");
        std::fs::create_dir_all(&inner).unwrap();
        assert!(is_symlink(&inner));
        assert!(!is_symlink(&real));
    }
}
