//! Portable policy and launcher regressions, with Windows identity coverage.

use std::path::Path;
use std::path::PathBuf;

use anyhow::Result;
use codex_protocol::models::PermissionProfile;
use codex_protocol::protocol::FileSystemAccessMode;
use codex_protocol::protocol::FileSystemPath;
use codex_protocol::protocol::FileSystemSandboxEntry;
use codex_protocol::protocol::FileSystemSandboxPolicy;
use codex_protocol::protocol::NetworkSandboxPolicy;
use codex_utils_absolute_path::AbsolutePathBuf;
use codex_utils_path_uri::PathUri;
use pretty_assertions::assert_eq;

use crate::MxcCommand;
use crate::policy::build_request;

fn canonical_root(temp: &tempfile::TempDir) -> Result<PathBuf> {
    Ok(
        PathUri::from_host_native_path(std::fs::canonicalize(temp.path())?)?
            .to_abs_path()?
            .into_path_buf(),
    )
}

fn entry(path: &Path, access: FileSystemAccessMode) -> Result<FileSystemSandboxEntry> {
    Ok(FileSystemSandboxEntry::new(
        AbsolutePathBuf::from_absolute_path(path)?.into(),
        access,
    ))
}

fn command(permissions: &PermissionProfile, cwd: &Path) -> MxcCommand {
    MxcCommand {
        permissions: permissions.clone(),
        sandbox_policy_cwd: cwd.to_owned(),
        command: vec!["program.exe".to_owned(), "--arg".to_owned()],
    }
}

#[test]
fn native_grants_preserve_denies_and_read_only_carveouts() -> Result<()> {
    let temp = tempfile::tempdir()?;
    let canonical = canonical_root(&temp)?;
    let root = canonical.as_path();
    let gitdir = tempfile::tempdir()?;
    std::fs::write(
        root.join(".git"),
        format!("gitdir: {}", gitdir.path().display()),
    )?;
    let readonly = root.join("readonly");
    let writable_child = readonly.join("writable");
    let denied = root.join("secret");
    let fs = FileSystemSandboxPolicy::restricted(vec![
        entry(root, FileSystemAccessMode::Write)?,
        entry(&readonly, FileSystemAccessMode::Read)?,
        entry(&writable_child, FileSystemAccessMode::Write)?,
        entry(&denied, FileSystemAccessMode::Deny)?,
    ]);
    let profile =
        PermissionProfile::from_runtime_permissions(&fs, NetworkSandboxPolicy::Restricted);
    let request = build_request(&command(&profile, root), root, Vec::new(), &[], &[])?;
    let mut expected_read = [
        root.join(".agents"),
        root.join(".codex"),
        root.join(".git"),
        readonly,
        writable_child.join(".agents"),
        writable_child.join(".codex"),
        writable_child.join(".git"),
    ];
    expected_read.sort();
    assert_eq!(
        (
            request.policy.readwrite_paths,
            request.policy.readonly_paths,
            request.policy.denied_paths
        ),
        (
            vec![
                root.to_str().unwrap().to_owned(),
                writable_child.to_str().unwrap().to_owned()
            ],
            expected_read
                .iter()
                .map(|path| path.to_str().unwrap().to_owned())
                .collect::<Vec<_>>(),
            vec![denied.to_str().unwrap().to_owned()],
        )
    );
    assert!(!request.policy.fallback.allow_dacl_mutation);
    Ok(())
}

#[test]
fn volume_expansion_does_not_turn_read_only_child_writable() -> Result<()> {
    let temp = tempfile::tempdir()?;
    let canonical = canonical_root(&temp)?;
    let root = canonical.as_path();
    let readonly = root.join("protected");
    let writable = root.join("work");
    std::fs::create_dir(&readonly)?;
    std::fs::create_dir(&writable)?;
    let fs = FileSystemSandboxPolicy::restricted(vec![
        entry(root, FileSystemAccessMode::Write)?,
        entry(&readonly, FileSystemAccessMode::Read)?,
    ]);
    let profile =
        PermissionProfile::from_runtime_permissions(&fs, NetworkSandboxPolicy::Restricted);
    let request = build_request(
        &command(&profile, root),
        root,
        Vec::new(),
        &[root.to_owned()],
        &[],
    )?;
    assert_eq!(
        request.policy.readwrite_paths,
        vec![root.to_str().unwrap(), writable.to_str().unwrap()]
    );
    assert_eq!(
        request.policy.readonly_paths,
        vec![
            root.join(".agents").to_str().unwrap(),
            root.join(".codex").to_str().unwrap(),
            root.join(".git").to_str().unwrap(),
            readonly.to_str().unwrap()
        ]
    );
    Ok(())
}

#[test]
fn volume_expansion_does_not_turn_read_only_alias_writable() -> Result<()> {
    let temp = tempfile::tempdir()?;
    let root = canonical_root(&temp)?;
    let readonly = root.join("protected");
    let alias = root.join("alias");
    std::fs::write(&readonly, "protected")?;
    std::fs::hard_link(&readonly, &alias)?;
    let fs = FileSystemSandboxPolicy::restricted(vec![
        entry(&root, FileSystemAccessMode::Write)?,
        entry(&readonly, FileSystemAccessMode::Read)?,
    ]);
    let profile =
        PermissionProfile::from_runtime_permissions(&fs, NetworkSandboxPolicy::Restricted);
    let request = build_request(
        &command(&profile, &root),
        &root,
        Vec::new(),
        std::slice::from_ref(&root),
        &[],
    )?;
    let alias = alias.display().to_string();
    assert_eq!(
        (
            request.policy.readwrite_paths.contains(&alias),
            request.policy.readonly_paths.contains(&alias),
        ),
        (false, true)
    );
    Ok(())
}

#[cfg(unix)]
#[test]
fn volume_expansion_uses_normalized_root_access() -> Result<()> {
    let temp = tempfile::tempdir()?;
    let root = canonical_root(&temp)?;
    let volume = root.join("volume");
    let child = volume.join("child");
    let alias = root.join("alias");
    std::fs::create_dir_all(&child)?;
    std::os::unix::fs::symlink(&volume, &alias)?;
    let fs = FileSystemSandboxPolicy::restricted(vec![
        entry(&volume, FileSystemAccessMode::Write)?,
        entry(&alias, FileSystemAccessMode::Read)?,
    ]);
    let profile =
        PermissionProfile::from_runtime_permissions(&fs, NetworkSandboxPolicy::Restricted);
    let request = build_request(
        &command(&profile, &root),
        &root,
        Vec::new(),
        std::slice::from_ref(&volume),
        &[],
    )?;
    let child = child.display().to_string();
    assert_eq!(
        (
            request.policy.readwrite_paths.contains(&child),
            request.policy.readonly_paths.contains(&child),
        ),
        (false, true)
    );
    Ok(())
}

#[cfg(unix)]
#[test]
fn volume_expansion_skips_uninspectable_children() -> Result<()> {
    let temp = tempfile::tempdir()?;
    let root = canonical_root(&temp)?;
    let uninspectable = root.join("loop");
    std::os::unix::fs::symlink(&uninspectable, &uninspectable)?;
    let denied = root.join("secret");
    std::fs::write(&denied, "secret")?;
    let fs = FileSystemSandboxPolicy::restricted(vec![
        entry(&root, FileSystemAccessMode::Write)?,
        entry(&denied, FileSystemAccessMode::Deny)?,
    ]);
    let profile =
        PermissionProfile::from_runtime_permissions(&fs, NetworkSandboxPolicy::Restricted);
    let request = build_request(
        &command(&profile, &root),
        &root,
        Vec::new(),
        std::slice::from_ref(&root),
        &[],
    )?;
    assert_eq!(
        (request.policy.readwrite_paths, request.policy.denied_paths),
        (
            vec![root.to_str().unwrap().to_owned()],
            vec![denied.to_str().unwrap().to_owned()],
        )
    );
    Ok(())
}

#[test]
fn deny_globs_expand_files_and_directories_before_launch() -> Result<()> {
    let temp = tempfile::tempdir()?;
    let root = canonical_root(&temp)?;
    let nested = root.join("nested");
    std::fs::create_dir(&nested)?;
    let file = nested.join("file.secret");
    let directory = nested.join("directory.secret");
    std::fs::write(&file, "secret")?;
    std::fs::create_dir(&directory)?;
    std::fs::write(nested.join("allowed.txt"), "allowed")?;
    let missing = root.join("explicit.secret");
    let fs = FileSystemSandboxPolicy::restricted(vec![
        entry(&root, FileSystemAccessMode::Write)?,
        entry(&missing, FileSystemAccessMode::Deny)?,
        FileSystemSandboxEntry::new(
            FileSystemPath::GlobPattern {
                pattern: "**/*.secret".to_owned(),
            },
            FileSystemAccessMode::Deny,
        ),
    ]);
    let profile =
        PermissionProfile::from_runtime_permissions(&fs, NetworkSandboxPolicy::Restricted);
    let request = build_request(&command(&profile, &root), &nested, Vec::new(), &[], &[])?;
    let mut expected = [file, directory, missing];
    expected.sort();
    assert_eq!(
        request.policy.denied_paths,
        expected.map(|path| path.to_str().unwrap().to_owned())
    );
    Ok(())
}

#[test]
fn relative_working_directories_fail_before_launch() -> Result<()> {
    let root = tempfile::tempdir()?;
    let profile = PermissionProfile::from_runtime_permissions(
        &FileSystemSandboxPolicy::restricted(Vec::new()),
        NetworkSandboxPolicy::Restricted,
    );
    for (policy_cwd, command_cwd, kind) in [
        (Path::new("relative"), root.path(), "policy"),
        (root.path(), Path::new("relative"), "command"),
    ] {
        let error = build_request(
            &command(&profile, policy_cwd),
            command_cwd,
            Vec::new(),
            &[],
            &[],
        )
        .unwrap_err();
        assert_eq!(
            error.to_string(),
            format!("MXC requires an absolute {kind} working directory")
        );
    }
    Ok(())
}

#[test]
fn non_unicode_paths_fail_before_launch() -> Result<()> {
    #[cfg(unix)]
    let name = <std::ffi::OsString as std::os::unix::ffi::OsStringExt>::from_vec(vec![0xff]);
    #[cfg(windows)]
    let name = <std::ffi::OsString as std::os::windows::ffi::OsStringExt>::from_wide(&[0xd800]);
    let temp = tempfile::tempdir()?;
    let root = canonical_root(&temp)?;
    let invalid = root.join(name);
    for (policy_path, command_cwd, expected) in [
        (
            root.as_path(),
            invalid.as_path(),
            "MXC requires a Unicode command working directory",
        ),
        (
            invalid.as_path(),
            root.as_path(),
            "MXC requires Unicode filesystem policy paths",
        ),
    ] {
        let fs = FileSystemSandboxPolicy::restricted(vec![entry(
            policy_path,
            FileSystemAccessMode::Deny,
        )?]);
        let profile =
            PermissionProfile::from_runtime_permissions(&fs, NetworkSandboxPolicy::Restricted);
        let error = build_request(&command(&profile, &root), command_cwd, Vec::new(), &[], &[])
            .unwrap_err();
        assert_eq!(error.to_string(), expected);
    }
    Ok(())
}
