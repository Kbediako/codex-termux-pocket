# Reproducible README hero

The hero is a deterministic ImageMagick 7 composite of a **real Android/Termux
screenshot**, inside a custom SVG unfolded-phone chassis. It is not generated
artwork. The supplied screenshot is the only source of screen pixels. Read
[the asset instructions](../AGENTS.md) before changing it.

## Source and output paths

| Role | Repository path |
| --- | --- |
| Real capture | `.github/assets/readme/termux-screenshot.jpg` (or a supplied native PNG) |
| Renderer | `scripts/render-readme-hero.sh` |
| Normal PNG | `.github/assets/readme/codex-termux-pocket-readme-hero.png` |
| High-DPI PNG | `.github/assets/readme/codex-termux-pocket-readme-hero@2x.png` |
| Regression tests | `scripts/test-render-readme-hero.sh` |

Keep an owner-provided capture in its original format; the current supplied
capture is JPEG. Prefer a native PNG for future captures, but never recompress,
retype, sharpen, or AI-clean an existing capture to make it look better. Do not
crop away the status bar, blank terminal space, extra keys, or navigation bar.
If the real source is absent from your checkout, obtain it from the owner. Do
not generate a placeholder or change the README image link until the real
source and both PNGs are ready to commit together.

## Update from the repository root

Use Bash on Linux, macOS, Termux, or Windows via WSL, with ImageMagick 7's
`magick` command and its PNG, JPEG, and internal SVG (MSVG) support available.
No fonts, stock mockups, image-generation service, or network access are needed.
Provide an upright, opaque sRGB screenshot; the renderer does not auto-rotate or
colour-correct it. Inspect the capture for private information before publishing.
If it contains information that should not be published, supply a new capture
rather than editing the screen pixels.

```sh
magick -version
./scripts/render-readme-hero.sh \
  .github/assets/readme/termux-screenshot.jpg \
  .github/assets/readme/codex-termux-pocket-readme-hero.png

bash -n scripts/render-readme-hero.sh scripts/test-render-readme-hero.sh
./scripts/test-render-readme-hero.sh
magick identify .github/assets/readme/codex-termux-pocket-readme-hero*.png
git diff --check
```

Replace the capture with the owner's new screenshot before running this command.
For PNG input, use its actual `.png` filename and update this documented path.
The input is never modified. Paths containing spaces are supported. The output
directory is created as needed. Bad inputs, source/output collisions, symlink
outputs, multi-frame images, and sizes that cannot fit are rejected.

Open **both** PNGs at native resolution and review the visual checklist in
[AGENTS.md](../AGENTS.md), including status icons, terminal text, bottom controls,
camera placement, thin bezels, parallel edges, background colour, and clipping.
Only then stage the source and both images together. Point the root README's
image at the normal PNG with `width="100%"`; retain its short installation and
update guidance unchanged. Do not use generative image tools for this workflow.

## Fixed design and reproducibility

The canvas is 1898 x 1190 with flat background `#6867AA`. The phone is centred
with a -3 px vertical offset, an 18 px source-resolution bezel, and the approved
right-half camera position (not the central hinge). Its default height is
**1000 px**, increased from 900 so it occupies more of the canvas without
clipping. The final `@2x` file is 3796 x 2380, created by Lanczos upscaling the
normal render, not by independently rebuilding the device.

To reproduce the older 900 px framing, append the optional height:

```sh
./scripts/render-readme-hero.sh CAPTURE.png OUTPUT.png 900
```

Other heights must retain the same aspect ratio and fit the canvas margins.
Only alpha-derived shadows supply depth; there is no perspective. The broad
shadow can fade into the canvas boundary, but the phone and tight shadow must
remain fully inside. Chassis geometry, radii, gradients, seam ticks, camera,
corner mask, colours, and shadow parameters live in the renderer and in the
scoped asset instructions, not in conversational history.

The renderer forces ImageMagick's internal SVG renderer and a single worker,
strips output metadata and PNG timestamps, and stages both renders before
replacing either destination. Each rename is atomic, but the pair is not a
filesystem transaction; commit both outputs together. The regression test
checks byte-identical repeated runs on the same toolchain, unchanged source
pixels at native scale, exact placement and camera position, dimensions and
background, the @2x relationship, bad-input handling, and failure safety.

Validated locally with ImageMagick **7.1.2-1 Q16-HDRI**, internal MSVG. Exact
PNG bytes across different ImageMagick, quantum-depth, HDRI, or codec builds are
not promised: record `magick -version` when reproducing or upgrading, rerun the
tests, and review the images. Never accept rendering drift by reconstructing UI.

The original geometry/compositing approach came from the owner's supplied
`render_codex_termux_readme_mockup(1).sh`. This version retains that process,
corrects the right-half camera and sticky final-layer geometry, and adds input
validation and repeatability checks. No permanent mockup-only branch is needed;
merge this tooling through the regular feature-branch/PR workflow.
