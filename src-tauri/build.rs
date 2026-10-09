// Cargo build scripts communicate linker settings through stdout.
#![allow(clippy::print_stdout)]

fn main() -> Result<(), Box<dyn std::error::Error>> {
    if std::env::var("CARGO_CFG_TARGET_OS")? == "windows"
        && std::env::var("CARGO_CFG_TARGET_ENV")? == "msvc"
    {
        // Tauri's default resource manifest covers the app but not its test
        // executables. Embed the same Common Controls dependency through the
        // linker for both, as Tauri's own API example does (issue #13419).
        tauri_build::try_build(tauri_build::Attributes::new().windows_attributes(
            tauri_build::WindowsAttributes::new_without_app_manifest(),
        ))?;
        let manifest = std::path::PathBuf::from(std::env::var("CARGO_MANIFEST_DIR")?)
            .join("windows-tests.manifest");
        println!("cargo:rerun-if-changed={}", manifest.display());
        println!("cargo:rustc-link-arg=/MANIFEST:EMBED");
        println!("cargo:rustc-link-arg=/MANIFESTINPUT:{}", manifest.display());
    } else {
        tauri_build::build();
    }
    Ok(())
}
