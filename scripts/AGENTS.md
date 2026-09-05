# README renderer scope

For `render-readme-hero.sh` and `test-render-readme-hero.sh`, first read
`../.github/assets/AGENTS.md` and `../.github/assets/readme/README.md`.

Keep the renderer offline and limited to Bash, ImageMagick 7, and standard shell
utilities. It must composite a supplied real screenshot, never regenerate UI.
Keep the executable bit on both scripts. Run `bash -n` on both and run
`./scripts/test-render-readme-hero.sh` after changing the rendering workflow.
Visually inspect both outputs using a real owner-provided capture before
publishing artwork. Record any checks that could not run rather than claiming
that the full repository CI passed.

These additional rules are specific to the two README scripts; other scripts
continue to follow their existing parent and more deeply scoped instructions.
