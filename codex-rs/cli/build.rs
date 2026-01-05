use std::process::Command;

fn main() {
    let manifest_dir = std::env::var("CARGO_MANIFEST_DIR").unwrap_or_else(|_| ".".to_string());
    let output = Command::new("git")
        .args(["describe", "--tags", "--always", "--dirty"])
        .current_dir(manifest_dir)
        .output();

    let Ok(output) = output else {
        return;
    };

    if !output.status.success() {
        return;
    }

    let version = String::from_utf8_lossy(&output.stdout);
    let version = version.trim();
    if version.is_empty() {
        return;
    }

    println!("cargo:rustc-env=CODEX_CLI_BUILD_VERSION={version}");
}
