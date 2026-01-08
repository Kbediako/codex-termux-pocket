# Codex Execution Plans (ExecPlans)

ExecPlans are living, self-contained design documents used to drive complex, multi-step work. They exist so a new contributor can restart the task with only the ExecPlan and the current working tree. They must describe observable outcomes, not just internal code changes.

## How to use ExecPlans and PLANS.md

When authoring an ExecPlan, read this file first and follow it closely. Start from the skeleton below and expand it as you research. Include any context a novice would need; do not rely on external docs or past memory.

When implementing an ExecPlan, proceed step by step without asking the user for “next steps.” Keep the plan updated as work progresses, and record decisions and surprises as they occur.

When discussing an ExecPlan, record changes in the Decision Log so the plan remains a reliable historical record. The plan must always be restartable from scratch.

## Non‑negotiable requirements

- Self‑contained: include all knowledge needed to complete the work.
- Living document: update it as progress, decisions, and discoveries happen.
- Novice‑friendly: define any jargon or term of art you use.
- Outcome‑focused: describe behavior a human can verify.
- Explicit: name files, commands, and expected outputs.

## Formatting

- In chat: the ExecPlan must be a single fenced code block labeled `md` and contain no nested fences. Put commands, diffs, and transcripts as indented blocks inside that one fence.
- In a Markdown file that contains only the ExecPlan: omit the triple backticks.
- Use headings and two blank lines between headings.
- Prose first. Checklists are allowed only in **Progress**, where they are required.

## Guidance

- Define any non‑obvious term in plain language and tie it to a file or command in this repo.
- Resolve ambiguity in the plan itself; do not push decisions onto the reader.
- Acceptance criteria must be observable (tests, commands, expected output).
- Steps should be idempotent or include safe retry/rollback guidance.
- Capture short evidence snippets (logs, diffs) that prove success.

## Milestones

If you use milestones, make each one independently verifiable and narrative: what will exist, how to check it, and why it matters. Progress is granular; milestones tell the story.

## Required living sections

Every ExecPlan must include and maintain these sections:
- **Progress** (checkboxes with timestamps)
- **Surprises & Discoveries**
- **Decision Log**
- **Outcomes & Retrospective**

## Skeleton (template)

```md
# <Short, action‑oriented plan title>

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries, Decision Log, and Outcomes & Retrospective must be kept current. If PLANS.md exists in this repo, this plan follows it.

## Purpose / Big Picture

Explain what the user gains and how they can see it working.

## Progress

- [ ] (YYYY‑MM‑DD HH:MM) Step …
- [ ] …

## Surprises & Discoveries

- Observation: …
  Evidence: …

## Decision Log

- Decision: …
  Rationale: …
  Date/Author: …

## Outcomes & Retrospective

Summarize what was achieved, what remains, and lessons learned.

## Context and Orientation

Describe the current repo state relevant to this task. Name files and modules with full paths. Define any terms of art.

## Plan of Work

Describe the sequence of edits and additions in prose. Specify file paths and the changes to make.

## Concrete Steps

List exact commands with working directories and short expected outputs.

## Validation and Acceptance

Describe how to verify success with concrete inputs/outputs and test commands.

## Idempotence and Recovery

Explain safe re‑runs, retries, and rollback paths if a step fails.

## Artifacts and Notes

Include short, focused logs, diffs, or transcripts that prove success.

## Interfaces and Dependencies

Name the modules, types, and external dependencies required at the end of the work.
```
