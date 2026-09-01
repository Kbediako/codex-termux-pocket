//! Composer undo transactions preserve rich draft data and active Vim commands.

use std::path::PathBuf;

use codex_config::types::KeybindingSpec;
use codex_config::types::KeybindingsSpec;
use codex_config::types::TuiKeymap;
use crossterm::event::KeyCode;
use crossterm::event::KeyEvent;
use crossterm::event::KeyModifiers;
use pretty_assertions::assert_eq;

use super::super::super::chat_composer_history::HistoryEntry;
use super::super::ChatComposer;
use super::super::InputResult;
use super::super::LARGE_PASTE_CHAR_THRESHOLD;
use super::super::tests::new_test_composer;
use crate::keymap::RuntimeKeymap;

fn vim_composer(text: &str) -> ChatComposer {
    let (mut composer, _receiver) = new_test_composer();
    composer.set_disable_paste_burst(/*disabled*/ true);
    composer.set_text_content(text.to_owned(), Vec::new(), Vec::new());
    composer.set_vim_enabled(/*enabled*/ true);
    composer.draft.textarea.set_cursor(/*pos*/ 0);
    composer
}

fn keys(composer: &mut ChatComposer, keys: &str) {
    for key in keys.chars() {
        let code = if key == '\n' {
            KeyCode::Enter
        } else {
            KeyCode::Char(key)
        };
        let _ = composer.handle_key_event(KeyEvent::new(code, KeyModifiers::NONE));
    }
}

fn escape(composer: &mut ChatComposer) {
    let _ = composer.handle_key_event(KeyEvent::new(KeyCode::Esc, KeyModifiers::NONE));
}

fn ctrl_r(composer: &mut ChatComposer) {
    let _ = composer.handle_key_event(KeyEvent::new(KeyCode::Char('r'), KeyModifiers::CONTROL));
}

#[test]
fn undo_groups_complete_vim_edits() {
    for (original, command, edited) in [
        ("one two", "cwX", "X two"),
        ("abc", "iXYZ", "XYZabc"),
        ("", "i/review", "/review"),
        ("one two", "c/two\nX", "Xtwo"),
        ("one two", "d/two\n", "two"),
        ("abc-def", "df-", "def"),
        ("abc-def", "cf-X", "Xdef"),
    ] {
        let mut composer = vim_composer(original);
        keys(&mut composer, command);
        if composer.popups.active() {
            escape(&mut composer);
        }
        escape(&mut composer);
        assert_eq!(composer.current_text(), edited);
        assert_eq!(composer.vim_history.undo.len(), 1);

        keys(&mut composer, "u");
        assert_eq!(
            (composer.current_text(), composer.cursor()),
            (original.to_owned(), 0)
        );
    }
}

#[test]
fn undo_preserves_repeat_and_pending_operator_bindings() {
    let mut composer = vim_composer("alpha beta gamma");
    keys(&mut composer, "dw.u");
    assert_eq!(composer.current_text(), "beta gamma");
    keys(&mut composer, "u.");
    assert_eq!(composer.current_text(), "beta gamma");

    let mut composer = vim_composer("one two");
    let mut keymap = RuntimeKeymap::defaults();
    keymap.vim_operator.motion_word_forward = vec![crate::key_hint::plain(KeyCode::Char('u'))];
    composer.set_keymap_bindings(&keymap);
    keys(&mut composer, "duu");
    assert_eq!(composer.current_text(), "one two");
}

#[test]
fn undo_preserves_confirmed_vim_search() {
    let mut composer = vim_composer("alpha beta alpha");
    keys(&mut composer, "/alpha\n0xun");
    assert_eq!(
        (composer.current_text(), composer.cursor()),
        ("alpha beta alpha".to_owned(), 11)
    );

    keys(&mut composer, "0");
    composer.handle_paste("Z".to_owned());
    keys(&mut composer, "n");
    assert_eq!(
        (composer.current_text(), composer.cursor()),
        ("Zalpha beta alpha".to_owned(), 12)
    );
}

#[test]
fn externally_canceled_search_operator_finishes_the_undo_transaction() {
    let mut composer = vim_composer("abc");
    keys(&mut composer, "xd/");
    assert!(composer.cancel_vim_search());
    keys(&mut composer, "uxu");
    assert_eq!(composer.current_text(), "abc");
}

#[test]
fn normal_mode_explicit_paste_is_its_own_undoable_edit() {
    let mut composer = vim_composer("abc");
    keys(&mut composer, "x");
    composer.handle_paste("Z".to_owned());
    assert_eq!(composer.current_text(), "Zbc");
    keys(&mut composer, "u");
    assert_eq!(composer.current_text(), "bc");
    keys(&mut composer, "u");
    assert_eq!(composer.current_text(), "abc");
}

#[test]
fn normal_mode_direct_insert_and_image_attachment_are_undoable() {
    let mut composer = vim_composer("abc");
    composer.insert_str("Z");
    assert_eq!(composer.current_text(), "Zabc");
    keys(&mut composer, "u");
    assert_eq!(composer.current_text(), "abc");

    let path = PathBuf::from("example.png");
    composer.attach_image(path.clone());
    assert_eq!(composer.local_image_paths(), vec![path]);
    keys(&mut composer, "u");
    assert_eq!(composer.current_text(), "abc");
    assert!(composer.local_image_paths().is_empty());
    keys(&mut composer, "\nABC");
    assert_eq!(composer.current_text(), "ABC");
    escape(&mut composer);
    keys(&mut composer, "u");
    assert!(composer.is_empty());
    keys(&mut composer, "u");
    assert!(composer.is_empty());
}

#[test]
fn deleting_a_selected_remote_image_is_one_undoable_vim_edit() {
    for key in [KeyCode::Delete, KeyCode::Backspace] {
        let mut composer = vim_composer("abc");
        let url = "https://example.com/remote.png".to_owned();
        composer.set_remote_image_urls(vec![url.clone()]);
        let _ = composer.handle_key_event(KeyEvent::new(KeyCode::Up, KeyModifiers::NONE));
        assert!(composer.vim_history.pending.is_none());
        let _ = composer.handle_key_event(KeyEvent::new(key, KeyModifiers::NONE));
        assert!(composer.remote_image_urls().is_empty());
        keys(&mut composer, "u");
        assert_eq!(composer.remote_image_urls(), vec![url]);
        assert_eq!(composer.current_text(), "abc");
    }
}

#[test]
fn direct_edits_join_the_active_vim_insert_transaction() {
    let mut composer = vim_composer("abc");
    composer.enable_vim_in_insert_mode();
    composer.handle_paste("ABC".to_owned());
    composer.attach_image(PathBuf::from("example.png"));
    keys(&mut composer, "D");
    escape(&mut composer);
    assert_eq!(composer.vim_history.undo.len(), 1);
    keys(&mut composer, "u");
    assert_eq!(composer.current_text(), "abc");
    assert!(composer.local_image_paths().is_empty());
}

#[test]
fn removing_the_shell_prefix_is_its_own_undoable_edit() {
    let mut composer = vim_composer("");
    keys(&mut composer, "!foo");
    escape(&mut composer);
    keys(&mut composer, "0");
    let before = composer.draft_snapshot();
    let _ = composer.handle_key_event(KeyEvent::new(KeyCode::Backspace, KeyModifiers::NONE));
    assert_eq!(composer.current_text(), "foo");
    keys(&mut composer, "u");
    assert_eq!(composer.draft_snapshot(), before);
}

#[test]
fn canceled_reverse_history_preview_preserves_vim_undo_and_repeat() {
    let mut composer = vim_composer("alpha beta alpha");
    composer
        .history
        .record_local_submission(HistoryEntry::new("archived prompt".to_owned()));
    keys(&mut composer, "/alpha\n0x");
    ctrl_r(&mut composer);
    keys(&mut composer, "archive");
    assert_eq!(composer.current_text(), "archived prompt");
    escape(&mut composer);
    assert_eq!(composer.current_text(), "lpha beta alpha");
    keys(&mut composer, "u");
    assert_eq!(composer.current_text(), "alpha beta alpha");
    keys(&mut composer, ".");
    assert_eq!(composer.current_text(), "lpha beta alpha");
    keys(&mut composer, "n");
    assert_eq!(composer.cursor(), 10);
}

#[test]
fn canceled_history_preview_preserves_active_vim_commands() {
    for query in ["", "archive", "missing"] {
        for (command, edited) in [("iX", "XYalpha beta"), ("cwX", "XY beta")] {
            let mut composer = vim_composer("alpha beta");
            composer
                .history
                .record_local_submission(HistoryEntry::new("archived prompt".to_owned()));
            keys(&mut composer, command);
            ctrl_r(&mut composer);
            keys(&mut composer, query);
            escape(&mut composer);
            keys(&mut composer, "Y");
            escape(&mut composer);
            assert_eq!(composer.current_text(), edited);
            keys(&mut composer, "u.");
            assert_eq!(composer.current_text(), edited);
        }
    }
}

#[test]
fn accepted_reverse_history_preview_starts_a_fresh_vim_edit_history() {
    let mut composer = vim_composer("abc");
    composer
        .history
        .record_local_submission(HistoryEntry::new("archived prompt".to_owned()));
    keys(&mut composer, "xiX");
    ctrl_r(&mut composer);
    keys(&mut composer, "archive\n");
    assert_eq!(composer.current_text(), "archived prompt");
    assert!(!composer.history_search_active());
    escape(&mut composer);
    keys(&mut composer, "u.");
    assert_eq!(composer.current_text(), "archived prompt");
}

#[test]
fn undo_uses_configured_bindings_and_supports_unbinding() {
    let mut composer = vim_composer("abc");
    let mut keymap = RuntimeKeymap::defaults();
    keymap.vim_normal.undo = vec![crate::key_hint::plain(KeyCode::Char('z'))];
    composer.set_keymap_bindings(&keymap);
    keys(&mut composer, "xu");
    assert_eq!(composer.current_text(), "bc");
    keys(&mut composer, "z");
    assert_eq!(composer.current_text(), "abc");
    keymap.vim_normal.undo.clear();
    composer.set_keymap_bindings(&keymap);
    keys(&mut composer, "xz");
    assert_eq!(composer.current_text(), "bc");

    let mut config = TuiKeymap::default();
    config.composer.history_search_previous =
        Some(KeybindingsSpec::One(KeybindingSpec("u".to_owned())));
    composer.set_keymap_bindings(&RuntimeKeymap::from_config(&config).unwrap());
    keys(&mut composer, "u");
    assert!(composer.history_search_active());
    escape(&mut composer);
    config.vim_normal.undo = Some(KeybindingsSpec::One(KeybindingSpec("u".to_owned())));
    composer.set_keymap_bindings(&RuntimeKeymap::from_config(&config).unwrap());
    keys(&mut composer, "u");
    assert!(!composer.history_search_active());

    let mut composer = vim_composer("abc");
    let mut config = TuiKeymap::default();
    config.composer.submit = Some(KeybindingsSpec::One(KeybindingSpec("u".to_owned())));
    composer.set_keymap_bindings(&RuntimeKeymap::from_config(&config).unwrap());
    assert_eq!(
        composer
            .handle_key_event(KeyEvent::new(KeyCode::Char('u'), KeyModifiers::NONE))
            .0,
        InputResult::Submitted {
            text: "abc".to_owned(),
            text_elements: Vec::new()
        }
    );
}

#[test]
fn undo_restores_deleted_large_paste_payload() {
    let mut composer = vim_composer("alpha ");
    composer.draft.textarea.set_cursor("alpha ".len());
    keys(&mut composer, "i");
    let pasted = "x".repeat(LARGE_PASTE_CHAR_THRESHOLD + 1);
    composer.handle_paste(pasted.clone());
    escape(&mut composer);
    let before = composer.draft_snapshot();
    keys(&mut composer, "x");
    assert_eq!(composer.current_text(), "alpha ");
    assert!(composer.draft.pending_pastes.is_empty());
    keys(&mut composer, "u");
    assert_eq!(composer.draft_snapshot(), before);
    assert_eq!(
        composer.current_text_with_pending(),
        format!("alpha {pasted}")
    );
}

#[test]
fn undo_restores_deleted_image_attachment() {
    let mut composer = vim_composer("alpha ");
    composer.draft.textarea.set_cursor("alpha ".len());
    composer.attach_image(PathBuf::from("example.png"));
    composer.draft.textarea.set_cursor("alpha ".len());
    let before = composer.draft_snapshot();
    keys(&mut composer, "x");
    assert_eq!(composer.current_text(), "alpha ");
    assert!(composer.local_image_paths().is_empty());
    keys(&mut composer, "u");
    assert_eq!(composer.draft_snapshot(), before);
}

#[test]
fn find_jump_and_search_navigation_never_snapshot_the_draft() {
    let mut composer = vim_composer("alpha beta\nalpha gamma");
    for key in ['f', 'F', 'G', '/', '?', 'n', 'N'] {
        composer.begin_vim_edit(KeyEvent::new(KeyCode::Char(key), KeyModifiers::NONE));
        assert!(
            composer.vim_history.pending.is_none(),
            "navigation binding {key:?} snapshotted the draft"
        );
    }
    let (code, modifiers) = composer
        .vim_normal_keymap
        .jump_top
        .first()
        .expect("native jump-top chord")
        .parts();
    composer.begin_vim_edit(KeyEvent::new(code, modifiers));
    assert!(composer.vim_history.pending.is_none());

    for command in ["llwbh0$", "fb", "Fa", "G", "/beta\nnN", "?alpha\n"] {
        let text = "alpha beta\nalpha gamma";
        let mut composer = vim_composer(text);
        for key in command.chars() {
            keys(&mut composer, &key.to_string());
            assert!(
                composer.vim_history.pending.is_none(),
                "navigation command {command:?} snapshotted the draft"
            );
            assert!(composer.vim_history.undo.is_empty());
        }
        assert_eq!(composer.current_text(), text);
    }
    composer
        .history
        .record_local_submission(HistoryEntry::new("alpha archived".to_owned()));
    ctrl_r(&mut composer);
    keys(&mut composer, "alpha");
    assert_eq!(composer.current_text(), "alpha archived");
    assert!(composer.vim_history.pending.is_none());
    assert!(composer.vim_history.undo.is_empty());
    escape(&mut composer);
    assert_eq!(composer.current_text(), "alpha beta\nalpha gamma");
}
