# SnagMe landing — design

Single-screen (no scroll) landing for the SnagMe macOS app. Pet project,
direct `.app` distribution (no App Store, no Apple Developer license).

## Goal
One screen that explains what SnagMe is and offers a direct download.
CTA is a placeholder link for now (GitHub Releases / direct file later).

## Reference
Structure modeled on https://lo.cafe/notchnook — which is already
monospace: soft gradient background + diagonal texture, white mono text,
outlined rounded "pill" buttons, app icon + name + version pill, lowercase
friendly copy, product screenshot, OS-requirement pills.

Difference from reference: **pixel + white monochrome**. Gradient
desaturated to gray, single accent = white. Pixel display font for the
wordmark / headline / button labels; monospace for body.

## Decisions
- Language: English
- Style: pixel + monospace, white monochrome on gray gradient
- Fonts: `Press Start 2P` (pixel, wordmark/buttons) + `JetBrains Mono` (body)
- CTA: download = placeholder (`#`), github = placeholder
- Single screen, no scroll (100vh, content vertically centered, scales via clamp)

## Layout (top → bottom, centered column ~620px)
1. Kicker: `a macos app /`
2. Head: pixel-hand icon box + `SnagMe` + version pill `v0.9`
3. Tagline (mono, lowercase)
4. Feature pills: `drag & drop` · `auto folders` · `100% local`
5. Buttons: `↓ download` (primary, filled white), `github` (outlined)
6. Product illustration: pixel notch + ref dropping in + saved pill + folder chips
7. Footer pills: `macOS 14+` · `apple silicon` · `free — trust or don't`

## File
`site/index.html` — fully self-contained (inline CSS + inline SVG, fonts
from Google Fonts). Deployable via GitHub Pages (`/site` or move to `/docs`).
