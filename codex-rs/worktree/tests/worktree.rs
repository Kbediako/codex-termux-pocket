#![allow(clippy::expect_used)]

use codex_worktree::CreateWorktree;
use codex_worktree::ManagedWorktree;
use codex_worktree::WorktreeManager;
use codex_worktree::WorktreeSettings;
use pretty_assertions::assert_eq;
use serde_json::Value;
use serde_json::json;
use std::fs;
use std::path::Path;
use std::path::PathBuf;
use std::process::Command;
use tempfile::TempDir;

struct RepositoryFixture {
    _temp_dir: TempDir,
    codex_home: PathBuf,
    repository: PathBuf,
}

impl RepositoryFixture {
    fn new() -> Self {
        let temp_dir = tempfile::tempdir().expect("create temporary test directory");
        let temp_root = dunce::canonicalize(temp_dir.path()).expect("canonicalize temporary root");
        let codex_home = temp_root.join("codex-home");
        let repository = temp_root.join("project");
        fs::create_dir_all(&codex_home).expect("create Codex home");
        initialize_repository(&repository);

        Self {
            _temp_dir: temp_dir,
            codex_home,
            repository,
        }
    }

    fn manager(&self) -> WorktreeManager {
        let settings =
            WorktreeSettings::from_desktop_config(&self.codex_home, /*desktop*/ None)
                .expect("load default worktree settings");
        WorktreeManager::new(settings)
    }
}

fn initialize_repository(repository: &Path) {
    fs::create_dir_all(repository.join("nested/component"))
        .expect("create temporary repository directories");
    run_git(repository, &["init", "--quiet"]);
    fs::write(
        repository.join("README.md"),
        "initial repository contents\n",
    )
    .expect("write tracked repository file");
    fs::write(
        repository.join("nested/component/tracked.txt"),
        "nested tracked file\n",
    )
    .expect("write nested tracked repository file");
    run_git(repository, &["add", "."]);
    commit(repository, "initial commit");
}

fn commit(repository: &Path, message: &str) {
    run_git(
        repository,
        &["commit", "--quiet", "--no-gpg-sign", "-m", message],
    );
}

fn create_worktree(
    manager: &WorktreeManager,
    source_cwd: &Path,
    base: Option<&str>,
) -> anyhow::Result<ManagedWorktree> {
    manager.create(&CreateWorktree {
        source_cwd: source_cwd.to_path_buf(),
        base: base.map(str::to_owned),
    })
}

fn git_output(repository: &Path, args: &[&str]) -> std::process::Output {
    Command::new("git")
        .current_dir(repository)
        .args([
            "-c",
            "user.name=Codex Worktree Test",
            "-c",
            "user.email=codex-worktree-test@example.invalid",
            "-c",
            "commit.gpgSign=false",
            "-c",
            "tag.gpgSign=false",
        ])
        .args(args)
        .output()
        .unwrap_or_else(|error| panic!("run git {args:?} in {repository:?}: {error}"))
}

fn run_git(repository: &Path, args: &[&str]) -> String {
    let output = git_output(repository, args);
    assert!(
        output.status.success(),
        "git {args:?} failed in {repository:?}: {}",
        String::from_utf8_lossy(&output.stderr),
    );
    String::from_utf8(output.stdout)
        .expect("git output is UTF-8")
        .trim()
        .to_owned()
}

#[test]
fn thread_binding_rejects_primary_and_unmanaged_worktrees() {
    let fixture = RepositoryFixture::new();
    let manager = fixture.manager();
    fs::create_dir_all(&manager.settings().root).expect("create managed root");
    assert!(
        manager
            .bind_thread(&fixture.repository, "not-a-managed-thread")
            .is_err(),
    );
    assert!(
        !fixture.repository.join(".git/codex-thread.json").exists(),
        "primary checkout ownership metadata must not be modified",
    );

    let unmanaged = manager.settings().root.join("scratch").join("project");
    fs::create_dir_all(unmanaged.parent().expect("unmanaged parent"))
        .expect("create unmanaged parent");
    run_git(
        &fixture.repository,
        &[
            "worktree",
            "add",
            "--detach",
            unmanaged.to_str().expect("UTF-8 unmanaged worktree"),
            "HEAD",
        ],
    );
    assert!(manager.bind_thread(&unmanaged, "unmanaged").is_err());
    assert!(manager.owner(&unmanaged).is_err());
}

#[test]
fn thread_binding_writes_the_exact_desktop_owner_schema_into_git_metadata() {
    let fixture = RepositoryFixture::new();
    let manager = fixture.manager();
    let checkout = manager.settings().root.join("a1b2/project");
    fs::create_dir_all(checkout.parent().expect("checkout parent")).expect("create bucket");
    run_git(
        &fixture.repository,
        &[
            "worktree",
            "add",
            "--detach",
            checkout.to_str().expect("UTF-8 checkout"),
            "HEAD",
        ],
    );
    let thread_id = "019f1234-5678-7000-8000-000000000001";

    assert_eq!(manager.owner(&checkout).expect("read initial owner"), None);

    manager
        .bind_thread(&checkout, thread_id)
        .expect("bind managed worktree to thread");

    assert_eq!(
        manager.owner(&checkout).expect("read bound owner"),
        Some(thread_id.to_owned()),
    );

    let metadata_path = checkout.join(run_git(
        &checkout,
        &["rev-parse", "--git-path", "codex-thread.json"],
    ));
    let metadata: Value = serde_json::from_slice(
        &fs::read(&metadata_path).expect("read Desktop-compatible worktree owner metadata"),
    )
    .expect("parse Desktop-compatible worktree owner metadata");

    assert_eq!(
        metadata,
        json!({
            "version": 1,
            "ownerThreadId": thread_id,
        }),
    );
}

#[test]
fn creation_uses_desktop_hash_bucket_layout_and_detached_head() {
    let fixture = RepositoryFixture::new();
    let manager = fixture.manager();
    let source_head = run_git(&fixture.repository, &["rev-parse", "HEAD"]);

    let worktree = create_worktree(&manager, &fixture.repository, /*base*/ None)
        .expect("create managed worktree");

    assert_eq!(
        manager
            .settings()
            .root
            .join(".metadata_never_index")
            .is_file(),
        cfg!(target_os = "macos"),
    );
    assert_eq!(
        worktree.root.parent().and_then(Path::parent),
        Some(fixture.codex_home.join("worktrees").as_path())
    );
    assert_eq!(
        worktree.root.file_name(),
        fixture.repository.file_name(),
        "Desktop expects the repository name underneath the hash bucket",
    );

    let bucket = worktree
        .root
        .parent()
        .and_then(Path::file_name)
        .and_then(|name| name.to_str())
        .expect("worktree has a UTF-8 hash-bucket directory");
    assert_eq!(bucket.len(), 4);
    assert!(bucket.bytes().all(|byte| byte.is_ascii_hexdigit()));

    assert_eq!(worktree.cwd, worktree.root);
    assert_eq!(worktree.source_root, fixture.repository);
    assert_eq!(worktree.source_cwd, worktree.source_root);
    assert_eq!(worktree.head_sha, source_head);
    assert_eq!(worktree.branch, None);
    assert_eq!(run_git(&worktree.root, &["rev-parse", "HEAD"]), source_head);
    assert!(
        !git_output(&worktree.root, &["symbolic-ref", "--quiet", "HEAD"])
            .status
            .success(),
        "Desktop-managed worktrees start with a detached HEAD",
    );
}

#[test]
fn creation_preserves_the_source_working_directory_relative_to_the_repository() {
    let fixture = RepositoryFixture::new();
    let manager = fixture.manager();
    fs::create_dir_all(&manager.settings().root).expect("precreate managed worktree root");
    let source_cwd = fixture.repository.join("nested/component");

    let worktree = create_worktree(&manager, &source_cwd, /*base*/ None)
        .expect("create worktree from nested source directory");

    assert_eq!(worktree.source_root, fixture.repository);
    assert_eq!(worktree.source_cwd, source_cwd);
    assert_eq!(worktree.cwd, worktree.root.join("nested/component"));
    assert!(worktree.cwd.join("tracked.txt").is_file());
    assert_eq!(
        manager
            .settings()
            .root
            .join(".metadata_never_index")
            .is_file(),
        cfg!(target_os = "macos"),
    );
}

#[test]
fn creation_respects_an_explicit_starting_commit() {
    let fixture = RepositoryFixture::new();
    let manager = fixture.manager();
    let initial_commit = run_git(&fixture.repository, &["rev-parse", "HEAD"]);

    fs::write(fixture.repository.join("second.txt"), "second commit\n")
        .expect("write another tracked repository file");
    run_git(&fixture.repository, &["add", "second.txt"]);
    commit(&fixture.repository, "second commit");

    let worktree = create_worktree(&manager, &fixture.repository, Some(&initial_commit))
        .expect("create worktree from explicit commit");

    assert_eq!(worktree.head_sha, initial_commit);
    assert_eq!(
        run_git(&worktree.root, &["rev-parse", "HEAD"]),
        initial_commit
    );
    assert!(!worktree.root.join("second.txt").exists());
}

#[test]
fn creation_peels_annotated_tags_to_the_checked_out_commit() {
    let fixture = RepositoryFixture::new();
    let manager = fixture.manager();
    let commit = run_git(&fixture.repository, &["rev-parse", "HEAD"]);
    run_git(
        &fixture.repository,
        &["tag", "-a", "release", "-m", "annotated release"],
    );

    let worktree = create_worktree(&manager, &fixture.repository, Some("release"))
        .expect("create worktree from annotated tag");

    assert_eq!(worktree.head_sha, commit);
    assert_eq!(run_git(&worktree.root, &["rev-parse", "HEAD"]), commit);
}

#[cfg(unix)]
#[test]
fn creation_rejects_a_working_directory_that_escapes_through_a_base_symlink() {
    let fixture = RepositoryFixture::new();
    let manager = fixture.manager();
    let original = run_git(&fixture.repository, &["rev-parse", "HEAD"]);
    let outside = fixture.codex_home.join("outside-worktree");
    fs::create_dir_all(&outside).expect("create outside directory");
    let linked_directory = fixture.repository.join("nested/component");
    fs::remove_dir_all(&linked_directory).expect("remove existing tracked directory");
    std::os::unix::fs::symlink(&outside, &linked_directory)
        .expect("replace tracked directory with an escaping symlink");
    run_git(&fixture.repository, &["add", "-A"]);
    commit(
        &fixture.repository,
        "introduce escaping working-directory symlink",
    );
    let unsafe_revision = run_git(&fixture.repository, &["rev-parse", "HEAD"]);
    run_git(&fixture.repository, &["reset", "--hard", &original]);

    let registered_before = run_git(&fixture.repository, &["worktree", "list", "--porcelain"]);

    assert!(
        create_worktree(&manager, &linked_directory, Some(&unsafe_revision)).is_err(),
        "an escaping destination symlink must never become the thread cwd",
    );
    assert_eq!(
        run_git(&fixture.repository, &["worktree", "list", "--porcelain"]),
        registered_before
    );
}

#[test]
fn creation_ignores_inherited_git_environment() {
    const CHILD_ROOT: &str = "CODEX_WORKTREE_ENV_TEST_ROOT";
    if let Some(root) = std::env::var_os(CHILD_ROOT) {
        let root = PathBuf::from(root);
        let source = root.join("project");
        let source_cwd = source.join("nested/component");
        let settings =
            WorktreeSettings::from_desktop_config(&root.join("codex-home"), /*desktop*/ None)
                .expect("fixture operation succeeds");
        let worktree = create_worktree(
            &WorktreeManager::new(settings),
            &source_cwd,
            /*base*/ None,
        )
        .expect("fixture operation succeeds");
        assert_eq!(worktree.source_root, source);
        assert_eq!(worktree.source_cwd, source_cwd);
        assert_eq!(
            worktree.head_sha,
            std::env::var("CODEX_WORKTREE_ENV_TEST_HEAD").expect("fixture operation succeeds")
        );
        return;
    }

    let fixture = RepositoryFixture::new();
    let other = fixture.codex_home.join("other-repository");
    initialize_repository(&other);
    fs::write(other.join("other.txt"), "different repository").expect("fixture operation succeeds");
    run_git(&other, &["add", "."]);
    commit(&other, "different repository");
    fs::write(
        fixture.repository.join(".gitattributes"),
        "*.txt filter=review\n",
    )
    .expect("fixture operation succeeds");
    run_git(&fixture.repository, &["add", "."]);
    commit(&fixture.repository, "checkout filter attributes");
    let mut child = Command::new(std::env::current_exe().expect("current test executable"));
    child
        .args(["--exact", "creation_ignores_inherited_git_environment", "--nocapture"])
        .env(CHILD_ROOT, fixture.repository.parent().expect("fixture parent"))
        .env("CODEX_WORKTREE_ENV_TEST_HEAD", run_git(&fixture.repository, &["rev-parse", "HEAD"]))
        .env("GIT_DIR", other.join(".git"))
        .env("GIT_COMMON_DIR", other.join(".git"))
        .env("GIT_CEILING_DIRECTORIES", &fixture.repository)
        .env("GIT_WORK_TREE", &fixture.repository)
        .env("GIT_CONFIG_COUNT", "1")
        .env("GIT_CONFIG_KEY_0", "filter.review.required")
        .env("GIT_CONFIG_VALUE_0", "true")
        .env("GIT_CONFIG_PARAMETERS", "'filter.review.process=codex-worktree-nonexistent-filter' 'filter.review.required=true'");
    let output = child.output().expect("fixture operation succeeds");
    assert!(
        output.status.success(),
        "child failed: {}\n{}",
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr),
    );
}

#[test]
fn creation_disables_filters_from_destination_conditional_config() {
    let fixture = RepositoryFixture::new();
    fs::write(
        fixture.repository.join(".gitattributes"),
        "*.txt filter=late text eol=lf\n",
    )
    .expect("write checkout attributes");
    run_git(&fixture.repository, &["add", "."]);
    commit(&fixture.repository, "checkout attributes");
    let config = fixture.codex_home.join("destination.gitconfig");
    fs::write(
        &config,
        "[filter \"late\"]\nsmudge = codex-worktree-nonexistent-filter\nrequired = true\n",
    )
    .expect("write conditional filter config");
    let git_dir = fixture.repository.join(".git/worktrees");
    let condition = format!(
        "includeIf.gitdir:{}/.path",
        git_dir.to_string_lossy().replace('\\', "/")
    );
    run_git(
        &fixture.repository,
        &["config", &condition, config.to_str().expect("UTF-8 config")],
    );

    let worktree = create_worktree(&fixture.manager(), &fixture.repository, /*base*/ None)
        .expect("checkout must not invoke the destination-only filter");
    assert_eq!(
        fs::read_to_string(worktree.root.join("nested/component/tracked.txt"))
            .expect("read checked out file"),
        "nested tracked file\n",
    );
}

#[test]
fn creation_preserves_dirty_source_with_shared_git_config() {
    let fixture = RepositoryFixture::new();
    initialize_repository(&fixture.repository.join("submodule"));
    run_git(
        &fixture.repository,
        &["submodule", "add", "./submodule", "submodule"],
    );
    commit(&fixture.repository, "add initialized submodule");

    for (key, value) in [
        (
            "core.worktree",
            fixture.repository.to_str().expect("UTF-8 repository"),
        ),
        ("extensions.worktreeConfig", "true"),
        ("core.autocrlf", "false"),
        ("submodule.recurse", "true"),
    ] {
        run_git(&fixture.repository, &["config", key, value]);
    }
    let config_path = fixture.repository.join(".git/config");
    let source_config = fs::read(&config_path).expect("read shared Git config");
    let path = "nested/component/tracked.txt";
    let original = fs::read(fixture.repository.join(path)).expect("read committed file");
    let dirty = b"uncommitted source contents";
    fs::write(fixture.repository.join(path), dirty).expect("dirty the source checkout");

    let worktree = create_worktree(&fixture.manager(), &fixture.repository, /*base*/ None)
        .expect("create without resetting the source checkout");

    assert_eq!(
        (
            fs::read(fixture.repository.join(path)).expect("read dirty source file"),
            fs::read(worktree.root.join(path)).expect("read new checkout file"),
            fs::read(config_path).expect("reread shared Git config"),
        ),
        (dirty.to_vec(), original, source_config),
    );
    assert_eq!(
        (
            PathBuf::from(run_git(&worktree.cwd, &["rev-parse", "--show-toplevel"])),
            run_git(&worktree.cwd, &["status", "--porcelain"]),
        ),
        (worktree.root, String::new()),
    );
}

#[test]
fn creation_rolls_back_when_the_base_lacks_the_source_subdirectory() {
    let fixture = RepositoryFixture::new();
    let manager = fixture.manager();
    let older_commit = run_git(&fixture.repository, &["rev-parse", "HEAD"]);
    let source_cwd = fixture.repository.join("introduced/later");
    fs::create_dir_all(&source_cwd).expect("create newly introduced source directory");
    fs::write(source_cwd.join("tracked.txt"), "new directory\n")
        .expect("write newly introduced tracked file");
    run_git(&fixture.repository, &["add", "."]);
    commit(&fixture.repository, "introduce source directory");

    let registered_before = run_git(&fixture.repository, &["worktree", "list", "--porcelain"]);

    assert!(
        create_worktree(&manager, &source_cwd, Some(&older_commit)).is_err(),
        "a destination cwd missing from the requested base must fail",
    );
    assert_eq!(
        run_git(&fixture.repository, &["worktree", "list", "--porcelain"]),
        registered_before
    );
    assert_eq!(
        fs::read_dir(&manager.settings().root)
            .expect("read managed root")
            .filter(|entry| {
                entry
                    .as_ref()
                    .expect("read managed root entry")
                    .file_type()
                    .expect("read managed root entry type")
                    .is_dir()
            })
            .count(),
        0,
        "failed creation must remove its own empty bucket",
    );
}

#[test]
fn creation_rejects_relative_roots_before_resolving_the_source() {
    let directory = TempDir::new().expect("create temporary directory");
    let source = directory.path().join("missing-source");
    let settings = WorktreeSettings::from_desktop_config(
        Path::new("relative-codex-home"),
        /*desktop*/ None,
    )
    .expect("load settings with a relative default root");
    let error = create_worktree(&WorktreeManager::new(settings), &source, /*base*/ None)
        .expect_err("relative roots must fail before source discovery");

    assert_eq!(
        error.to_string(),
        "managed worktree root must be an absolute path",
    );
}

#[test]
fn creation_fails_for_a_directory_outside_a_git_repository() {
    let fixture = RepositoryFixture::new();
    let manager = fixture.manager();
    let non_repository = fixture.codex_home.join("not-a-repository");
    fs::create_dir_all(&non_repository).expect("create non-repository directory");

    assert!(
        create_worktree(&manager, &non_repository, /*base*/ None).is_err(),
        "managed worktree creation requires a Git repository",
    );
}
