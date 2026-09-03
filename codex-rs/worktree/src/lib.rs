mod git;
mod metadata;
mod paths;
mod settings;

use crate::git::GitOperation;
use crate::git::git_output;
use crate::git::git_path;
use crate::git::git_stdout;
use crate::paths::allocate_worktree_root;
use crate::paths::remove_empty_bucket;
use anyhow::Context;
use anyhow::Result;
use anyhow::bail;
use serde::Serialize;
use std::ffi::OsStr;
use std::path::Component;
use std::path::Path;
use std::path::PathBuf;

pub use settings::DEFAULT_WORKTREE_KEEP_COUNT;
pub use settings::WorktreeSettings;

/// A Desktop-compatible checkout and the cwd that should be used to start its thread.
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ManagedWorktree {
    pub root: PathBuf,
    pub cwd: PathBuf,
    pub source_root: PathBuf,
    pub source_cwd: PathBuf,
    pub head_sha: String,
    /// A UTF-8 branch label, when available; absence does not imply detached HEAD.
    pub branch: Option<String>,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct CreateWorktree {
    pub source_cwd: PathBuf,
    pub base: Option<String>,
}

/// Creates and identifies worktrees using the existing Codex Desktop contract.
#[derive(Clone, Debug)]
pub struct WorktreeManager {
    settings: WorktreeSettings,
}

impl WorktreeManager {
    pub fn new(mut settings: WorktreeSettings) -> Self {
        settings.root = dunce::simplified(&settings.root).to_path_buf();
        Self { settings }
    }

    pub fn settings(&self) -> &WorktreeSettings {
        &self.settings
    }

    pub fn create(&self, request: &CreateWorktree) -> Result<ManagedWorktree> {
        if !self.settings.root.is_absolute() {
            bail!("managed worktree root must be an absolute path");
        }

        let source_cwd = dunce::canonicalize(&request.source_cwd)
            .with_context(|| format!("cannot resolve {}", request.source_cwd.display()))?;
        let source_root = repository_root(&source_cwd)?;
        let relative_cwd = source_cwd
            .strip_prefix(&source_root)
            .context("working directory is outside the repository root")?;
        let repository_name = source_root
            .file_name()
            .context("repository root has no directory name")?;
        let revision = format!("{}^{{commit}}", request.base.as_deref().unwrap_or("HEAD"));
        let head_sha = git_stdout(
            &source_root,
            [
                "rev-parse",
                "--verify",
                "--end-of-options",
                revision.as_str(),
            ],
        )?;
        let root = allocate_worktree_root(&self.settings.root, repository_name)?;

        let result = git_output(
            &source_root,
            GitOperation::WorkingTree,
            [
                OsStr::new("worktree"),
                OsStr::new("add"),
                OsStr::new("--detach"),
                OsStr::new("--no-checkout"),
                root.as_os_str(),
                OsStr::new(&head_sha),
            ],
        );
        if let Err(error) = result {
            remove_empty_bucket(&root);
            return Err(error).context("cannot create managed worktree");
        }

        // Write only the destination's config, without changing shared settings or
        // enabling worktreeConfig for the source repository.
        let result = git_path(
            &root,
            [
                "rev-parse",
                "--path-format=absolute",
                "--git-path",
                "config.worktree",
            ],
        )
        .and_then(|config| {
            git_output(
                &root,
                GitOperation::Metadata,
                [
                    OsStr::new("config"),
                    OsStr::new("--file"),
                    config.as_os_str(),
                    OsStr::new("core.worktree"),
                    root.as_os_str(),
                ],
            )?;
            // Discover destination-only filters before materializing files, and pin
            // the working tree even when per-worktree configuration is disabled.
            git_output(
                &root,
                GitOperation::WorkingTree,
                [
                    "--work-tree=.",
                    "reset",
                    "--hard",
                    "--no-recurse-submodules",
                    head_sha.as_str(),
                ],
            )
        });
        if let Err(error) = result {
            remove_worktree(&source_root, &root)
                .context("cannot roll back an incomplete managed worktree")?;
            return Err(error).context("cannot populate managed worktree");
        }

        let cwd = root.join(relative_cwd);
        if !is_safe_worktree_cwd(&root, &cwd) {
            remove_worktree(&source_root, &root)
                .context("cannot roll back a worktree missing its working directory")?;
            bail!(
                "requested base does not contain a safe working directory {}",
                relative_cwd.display()
            );
        }

        Ok(ManagedWorktree {
            cwd,
            root,
            source_root,
            source_cwd,
            head_sha,
            branch: None,
        })
    }

    pub fn bind_thread(&self, checkout: &Path, thread_id: &str) -> Result<()> {
        let checkout = self.managed_checkout(checkout)?;
        metadata::bind_thread(&checkout, thread_id)
    }

    pub fn owner(&self, checkout: &Path) -> Result<Option<String>> {
        let checkout = self.managed_checkout(checkout)?;
        metadata::owner(&checkout)
    }

    fn managed_checkout(&self, checkout: &Path) -> Result<PathBuf> {
        let managed_root = dunce::canonicalize(&self.settings.root).with_context(|| {
            format!(
                "cannot resolve managed worktree root {}",
                self.settings.root.display()
            )
        })?;
        let checkout = dunce::canonicalize(checkout)
            .with_context(|| format!("cannot resolve worktree {}", checkout.display()))?;
        if !has_managed_layout(&managed_root, &checkout) {
            bail!("{} is not a managed worktree", checkout.display());
        }

        linked_worktree_common_dir(&checkout)?;
        Ok(checkout)
    }
}

fn remove_worktree(source_root: &Path, root: &Path) -> Result<()> {
    let result = git_output(
        source_root,
        GitOperation::WorkingTree,
        [
            OsStr::new("worktree"),
            OsStr::new("remove"),
            OsStr::new("--force"),
            root.as_os_str(),
        ],
    );
    remove_empty_bucket(root);
    result.map(|_| ())
}

fn is_safe_worktree_cwd(root: &Path, cwd: &Path) -> bool {
    let Ok(root) = dunce::canonicalize(root) else {
        return false;
    };
    dunce::canonicalize(cwd).is_ok_and(|resolved| resolved.is_dir() && resolved.starts_with(&root))
}

fn linked_worktree_common_dir(checkout: &Path) -> Result<PathBuf> {
    if checkout != repository_root(checkout)? {
        bail!("{} is not a worktree root", checkout.display());
    }
    let git_dir = resolve_git_path(checkout, "--git-dir")?;
    let common_dir = resolve_git_path(checkout, "--git-common-dir")?;
    if git_dir == common_dir {
        bail!("{} is not a linked worktree", checkout.display());
    }
    Ok(common_dir)
}

fn has_managed_layout(root: &Path, checkout: &Path) -> bool {
    let Ok(relative) = checkout.strip_prefix(root) else {
        return false;
    };
    let mut components = relative.components();
    let Some(Component::Normal(bucket)) = components.next() else {
        return false;
    };
    let Some(bucket) = bucket.to_str() else {
        return false;
    };
    bucket.len() == 4
        && bucket.bytes().all(|byte| byte.is_ascii_hexdigit())
        && matches!(components.next(), Some(Component::Normal(_)))
        && components.next().is_none()
}

fn resolve_git_path(checkout: &Path, argument: &str) -> Result<PathBuf> {
    let path = checkout.join(git_path(checkout, ["rev-parse", argument])?);
    dunce::canonicalize(&path)
        .with_context(|| format!("cannot resolve Git path {}", path.display()))
}

fn repository_root(cwd: &Path) -> Result<PathBuf> {
    let path = git_path(cwd, ["rev-parse", "--show-toplevel"])?;
    dunce::canonicalize(&path)
        .with_context(|| format!("cannot resolve repository root {}", path.display()))
}
