# DAYMARK Brand Guide

**Tagline:** Plan your day. Track your progress.
**Personality:** minimal, calm, reliable, focused. Gold is an accent, never a flood.

The official artwork is the supplied brand set, stored **unmodified** in `branding/source/` (checksums in `SHA256SUMS`). It is raster (PNG) artwork exported from the approved concept. Nothing in this repository redraws, recolours or re-creates it.

## How the supplied files are used

`python branding/apply_brand.py apps/client` copies them into a Flutter project (add `--check` to verify without changing anything).

| Supplied file | Project path | Used for |
|---|---|---|
| `logo/DAYMARK-primary-light.png` (960x195) | `assets/brand/logo/daymark-logo.png` | Light-mode logo: onboarding, dashboard header, desktop sidebar, settings/About |
| `logo/DAYMARK-primary-dark.png` (660x170) | `assets/brand/logo/daymark-logo-dark.png` | Dark-mode logo (same places) |
| `icons/DAYMARK-icon-512.png` (transparent) | `assets/brand/logo/daymark-symbol.png` | In-app standalone symbol |
| `android/ic_launcher-{48,72,96,144,192}.png` | `android/app/src/main/res/mipmap-{m,h,xh,xxh,xxxh}dpi/ic_launcher.png` | Legacy launcher icon (Android < 8) |
| `android/ic_launcher-512.png` | `android/app/src/main/ic_launcher-playstore.png` | Play Store listing icon |
| `icons/DAYMARK-icon-transparent-1024.png` | derived: `mipmap-*/ic_launcher_foreground.png` | Adaptive-icon foreground (**scaled and padded only**) |
| `icons/DAYMARK-app-icon-1024.png` | background colour sampled (`#F7F7F4`) | Adaptive-icon background colour |
| `web/favicon-{16,32,48}.png`, `favicon-32.png` | `web/icons/favicon-*.png`, `web/favicon.png` | Browser tab icons |
| `web/favicon-180.png` | `web/icons/apple-touch-icon.png` | iOS home screen |
| `web/favicon-192.png`, `favicon-512.png` | `web/icons/Icon-192.png`, `Icon-512.png` | PWA / install icons |
| `web/site.webmanifest` | `web/manifest.json` | Same name, colours; relative paths and `start_url` added |

In Flutter, never reference the files directly. Use `DaymarkLogo` (horizontal, picks the light or dark variant from the theme) and `DaymarkMark` (symbol) from `lib/shared/widgets/daymark_logo.dart`.

Unused but kept in `source/`: `DAYMARK-icon-{16..256}.png` (other transparent sizes), `DAYMARK-app-icon-1024.png`, and the guideline sheet in `reference/`.

## Palette (from the supplied README)

| Token | Hex | Role | Contrast |
|---|---|---|---|
| Charcoal (primary) | `#202428` | Light-mode text, dark-mode background | 14.6:1 on `#F7F7F4` |
| Gold (accent) | `#C9A85A` | Fills, progress, accents | **2.1:1 on light: never use for text there** |
| Off-white (background) | `#F7F7F4` | Light-mode background | |
| Gold ink | `#7A5C1A` | Gold-family text and focus ring on light (app addition) | 5.8:1 on `#F7F7F4` |
| Gold soft | `#D4B572` | Gold-family text on dark (app addition) | 7.9:1 on `#202428` |
| Secondary text | `#5F6368` | Light metadata (app choice) | 5.6:1 |

The supplied secondary gray `#6B7280` measures 4.5:1 on `#F7F7F4`, right at the WCAG AA limit for body text, so the app keeps the slightly darker `#5F6368` for text. Dark-mode surfaces (`#272B31`, `#30343B`) and status colours are app tokens in `daymark_tokens.dart`; ratios are noted there.

## Typography

**Manrope** (variable, SIL OFL 1.1) is the app's UI font, bundled locally. It is **not** the logo's lettering, which is part of the supplied artwork and is only available as an image.

## Usage

- **Light surfaces:** light logo. **Dark surfaces:** dark logo. Do not use the light logo on dark.
- **Backgrounds are baked in.** Both primary logos are opaque PNGs. The light one's background is about `#F9F9F7` (the app background is `#F7F7F4`, a difference of 2 levels, invisible in practice). The dark one's is about `#1F2327`, so the dark theme background is the brand charcoal `#202428`. Place the dark logo on that background, or let `DaymarkLogo` round it as a plate on raised surfaces.
- **Symbol on dark:** the transparent symbol's check mark is see-through and its tile is charcoal, so it disappears on dark surfaces. `DaymarkMark` puts it on off-white in dark mode, as the supplied app icon does.
- **Sizes:** keep `DaymarkLogo` at or under 56 logical px tall (source is 195 px / 170 px tall). Symbol: favicon down to 16 px; in-app 24 px and up.
- **Don't:** recolour, stretch, rotate, add shadows or outlines, or re-typeset the wordmark.

## Known issues with the supplied files

1. **Both primary logos have baked-in backgrounds** (no transparency), so they only work on matching surfaces.
2. **Inconsistent padding.** The light logo has 0 px right margin (the "K" touches the canvas edge) and 3 px bottom margin. The dark logo is off-centre (64 px left, 3 px right) and its artwork fills 73% of the canvas height versus 82% for the light one. `DaymarkLogo` compensates for the scale difference; the margins are untouched.
3. **Raster, noisy edges.** The PNGs are exports from a generated concept (the supplied README says so) with slightly noisy colours. For a crisp, scalable logo, have the symbol and wordmark traced as vector artwork and compare against the reference sheet.
4. **Palette is approximate.** Sampled pixels differ by a few levels from the documented hex values (e.g. tile `#1D2225` vs `#202428`). Documented values are used for the theme.

## Missing variants (not supplied, not invented)

SVG/vector logo and symbol; compact horizontal and stacked logos as files (they appear only on the guideline sheet); monochrome logo; dark-background standalone symbol; inverted dark app icon; transparent-background primary logos; maskable PWA icons; round Android icons; `favicon.ico`; Android 13 themed (monochrome) icon layer. Anything that needs one of these currently falls back as described above.
