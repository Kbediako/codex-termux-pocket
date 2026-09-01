//! Regression coverage for bounded background-terminal input previews.

use super::*;
use pretty_assertions::assert_eq;

#[test]
fn unified_exec_input_preview_limits_wrapped_payload() {
    let input = "abcdefghijklmnopqrstuvwxyz0123456789".repeat(/*n*/ 2_000);
    let cell = new_unified_exec_interaction(Some("cat".to_string()), input.clone());
    let preview = cell.display_lines(/*width*/ 40);
    insta::assert_snapshot!(
        preview.iter().map(ToString::to_string).collect::<Vec<_>>().join("\n"),
        @"
    ↳ Interacted with background terminal ·
    cat
      └ abcdefghijklmnopqrstuvwxyz0123456789
        abcdefghijklmnopqrstuvwxyz0123456789
        abcdefghijklmnopqrstuvwxyz0123456789
        abcdefghijklmnopqrstuvwxyz0123456789
        abcdefghijklmnopqrstuvwxyz0123456789
        abcdefghijklmnopqrstuvwxyz0123456789
        abcdefghijklmnopqrstuvwxyz0123456789
        abcdefghijklmnopqrstuvwxyz0123456789
        abcdefghijklmnopqrstuvwxyz0123456789
        abcdefghijklmnopqrstuvwxyz0123456789
        abcdefghijklmnopqrstuvwxyz0123456789
        abcdefghijklmnopqrstuvwxyz0123456789
      … Input preview limited (ctrl + t to view transcript).
    ",
    );
    assert_eq!(
        cell.raw_lines(),
        vec![
            Line::from("Interacted with background terminal: cat"),
            Line::from(input.clone()),
        ],
    );
    let transcript = cell.transcript_lines(/*width*/ 40);
    assert_eq!(
        transcript[2..],
        adaptive_wrap_lines(
            input.lines(),
            RtOptions::new(/*width*/ 40)
                .initial_indent(Line::from("  └ ".dim()))
                .subsequent_indent(Line::from("    ".dim())),
        ),
    );
}

#[test]
fn unified_exec_input_preview_preserves_fitting_lines() {
    for input in [
        "line\n".repeat(/*n*/ 20),
        format!(
            "prefixprefixprefix https://example.test/a-b\n{}",
            "line\n".repeat(/*n*/ 20)
        ),
    ] {
        let cell = new_unified_exec_interaction(/*command_display*/ None, input);
        let mut expected = cell.transcript_lines(/*width*/ 40);
        expected.truncate(/*len*/ 13);
        expected.push(
            "  … Input preview limited (ctrl + t to view transcript)."
                .dim()
                .into(),
        );
        assert_eq!(cell.display_lines(/*width*/ 40), expected);
    }
}

#[test]
fn unified_exec_input_preview_respects_viewport_rows() {
    for width in [1, 2, 4, 5, 8, 40, 80] {
        for input in [
            "a".repeat(/*n*/ 4_000),
            format!("https://example.com/{}", "a".repeat(/*n*/ 4_000)),
            "界👩‍💻e\u{301}\t ".repeat(/*n*/ 1_000),
            "\x1b[A".repeat(/*n*/ 1_000),
        ] {
            let cell = new_unified_exec_interaction(/*command_display*/ None, input);
            let preview = cell.display_lines(width);
            let header =
                new_unified_exec_interaction(/*command_display*/ None, "x".to_string())
                    .display_lines(width);
            let content = &preview[header.len() - 1..preview.len() - 1];
            assert!(
                Paragraph::new(content.to_vec())
                    .wrap(Wrap { trim: false })
                    .line_count(width)
                    <= INPUT_PREVIEW_ROWS,
                "input preview exceeds row budget at width {width}",
            );
        }
    }
}

#[test]
fn unified_exec_input_preview_bounds_zero_width_payload() {
    let input = "\u{301}".repeat(/*n*/ 100_000);
    let cell = new_unified_exec_interaction(/*command_display*/ None, input.clone());
    let preview = cell.display_lines(/*width*/ 80);
    assert!(
        preview
            .last()
            .unwrap()
            .to_string()
            .contains("Input preview limited")
    );
    assert!(
        preview
            .iter()
            .map(|line| line.to_string().len())
            .sum::<usize>()
            < 66_000
    );
    assert_eq!(
        cell.raw_lines(),
        vec![
            Line::from("Interacted with background terminal"),
            Line::from(input)
        ],
    );
}

#[test]
fn unified_exec_input_preview_keeps_short_and_exact_budget_input() {
    for input in [
        "".to_string(),
        "ls\npwd".to_string(),
        "x\n".repeat(/*n*/ 12),
    ] {
        let cell = new_unified_exec_interaction(Some("cat".to_string()), input);
        assert_eq!(
            cell.display_lines(/*width*/ 80),
            cell.transcript_lines(/*width*/ 80)
        );
        assert_eq!(cell.display_lines(/*width*/ 0), Vec::<Line<'static>>::new());
    }
}
