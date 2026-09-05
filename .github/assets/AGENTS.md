# README artwork: real pixels, deterministic rendering

These rules cover README artwork under `.github/assets/`. Read
`readme/README.md` before changing the hero, its screenshot, or its renderer.
The root README and `scripts/render-readme-hero.sh` must follow this contract too.

## Non-negotiable source fidelity

Use the actual Android/Termux screenshot supplied by the owner as the source of
truth. If it is missing, request it; never substitute a synthetic screen or an
old hero cropped back into a screenshot. Do not redraw, OCR/retype, regenerate,
AI-reconstruct, sharpen, recolour, or clean up screen content. Preserve the
original CLI text, ANSI colours, spacing, Android status icons, usage/version
text, Termux extra keys, and Android navigation UI. Do not paint over UI to make
room for a camera or remove information; ask for a suitable new capture instead.

Use ImageMagick **7** (`magick`) and the repository's custom SVG chassis. No
image-generation tools, stock device pixels, watermarks, network image services,
or font-based reconstruction belong in routine updates. A device reference is
only a shape reference, not a compositing asset.

## Geometry and finish

- Read the screenshot dimensions dynamically. Add an 18 px native-resolution
  bezel; use outer chassis radius 24, inner black face radius 18, and mask only
  the screenshot's outer corners with `rx=10`. Retain the dark metallic SVG
  gradient and small centred top/bottom Fold seam ticks.
- The approved unfolded-Fold camera is centred over the **right half** of the
  screen: `x = bezel + 3 * screenshot_width / 4`, `y = bezel + 25`. Use the dark
  concentric circles in the renderer, not a camera at the centre hinge.
- The phone must be perfectly front-on. Only uniform Lanczos scaling and integer
  translation are allowed. Never use Perspective, rotation, shear, keystone,
  forced aspect-ratio stretching, or any transform making edges non-parallel.
- Keep the canvas 1898 x 1190 and background exactly `#6867AA`. Centre the phone
  on both axes with Y offset -3 px (integer rounding may differ by half a pixel).
  Default phone height is 1000 px for a larger presentation; 900 reproduces the
  original framing. Reject sizes that would clip the phone or tight shadow.
- Depth comes only from the alpha silhouette: tight `#101014` shadow, blur 6,
  alpha multiplier 0.76, offset +3,+6; broad `#1c1a35` shadow, blur 30,
  multiplier 0.34, offset 0,+14. Reset the final phone layer to +0,+0 so the
  shadow offset cannot accidentally shift the phone.
- Export the normal PNG and its 3796 x 2380 `@2x` Lanczos upscale from the same
  render. Do not independently edit either image or substitute a lossy export.

## Required update and review

Replace the real source capture, run the renderer, run its regression tests,
inspect both PNGs, then commit the source and both outputs together. Update the
asset README when source paths or render parameters change. Do not point the
root README at files that are not present in the same change. Prefer the normal
PNG at `width="100%"` for legibility; keep operational detail out of the root README.

Before committing, visually check: exactly front-on; no device/UI clipping; no
watermark; original status bar and bottom controls visible; original text and
colours retained; thin bezels; right-half camera clear of status icons; exact
purple background; both resolutions regenerated from the same capture. Tests
supplement this visual review, not replace it. Reject a bad capture instead of
repairing its pixels.

Use normal short-lived feature branches and PRs, not a permanent mockup branch.
Do not touch runtime code, release manifests/tags, protection rules, or CI to
update artwork. Classify helper commits in `scripts/termux/patch_audit.tsv` as
required by the root instructions. Never force-push or overwrite concurrent work.
