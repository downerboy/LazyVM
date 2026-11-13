# LazyVM Brand and UI Theme — v1

Status: Draft. Based on the security findings page (2026-11-12).

## 1. Principles

1. **Calm, not alarming.** LazyVM reports; it doesn't panic. Navy and white carry the page. Color is used only for meaning.
2. **Color never works alone.** Every color is paired with text or an icon, so the page reads in grayscale, under magnification and with a screen reader.
3. **One accent for actions.** Yellow is used only for things you click.
4. **The same shape every time.** Every finding uses the same card and the same fields in the same order.
5. **Zoom-proof.** Sizes are in `rem`. The layout must hold at 400% browser zoom with no sideways scrolling.

## 2. Color tokens

All pairs meet WCAG AA (4.5:1) for text; most meet AAA.

| Token | Hex | Use |
|---|---|---|
| `--lv-navy` | `#0B2E59` | Brand primary. Header bar, headings, button borders, focus ring |
| `--lv-ink` | `#13223F` | Body text |
| `--lv-ink-muted` | `#475467` | Secondary text (timestamps, "First seen") |
| `--lv-page` | `#F5F8FC` | Page background |
| `--lv-card` | `#FFFFFF` | Card background |
| `--lv-card-border` | `#C9D6E5` | Card and command-box borders |
| `--lv-tint` | `#DCEAF8` | Summary panel, alternate-row tint |
| `--lv-accent` | `#FFD75E` | Buttons (yellow) |
| `--lv-accent-hover` | `#FFC929` | Button hover/pressed |
| `--lv-on-accent` | `#0B2E59` | Button text (about 10:1 on yellow) |
| `--lv-on-sev` | `#FFFFFF` | Severity badge text (`#0A1628` in the dark theme) |

### Severity

| Severity | Token | Hex | Icon | Text on white |
|---|---|---|---|---|
| High | `--lv-sev-high` | `#B42318` | ▲ (triangle) | 6.5:1 |
| Medium | `--lv-sev-medium` | `#B54708` | ◆ (diamond) | 5.3:1 |
| Low | `--lv-sev-low` | `#175CD3` | ● (circle) | 5.0:1 |
| Info | `--lv-sev-info` | `#475467` | ■ (square) | 7.5:1 |

Shapes differ as well as colors, so severities stay distinct for color-blind users and in grayscale.

### Status chip

| Status | Background | Text |
|---|---|---|
| New | `--lv-navy` | white |
| Still open | `--lv-tint` | `--lv-navy` |
| Resolved | `#E7F4EC` | `#05603A` |
| Approved | `#EEF0F3` | `--lv-ink-muted` |

## 3. Typography

| Role | Font | Size | Weight |
|---|---|---|---|
| Page title (h1) | Segoe UI, system-ui, sans-serif | 1.75rem | 700 |
| Card title (h2) | same | 1.25rem | 700 |
| Body / field values | same | 1rem (16px) | 400 |
| Field labels | same | 1rem | 600 |
| Code / commands | Cascadia Mono, Consolas, monospace | 0.9375rem | 400 |

- Line height 1.5 for body text and 1.25 for headings.
- Use sentence case everywhere. No ALL CAPS.

## 4. Layout

- Content max width `60rem`, centered, `1.5rem` side padding.
- Spacing scale: `0.25 / 0.5 / 1 / 1.5 / 2 / 3 rem`.
- Card: `--lv-card` background, 1px `--lv-card-border`, **6px left stripe in the severity color**, radius `0.5rem`, padding `1.5rem`, gap between cards `1rem`.
- Field list: `<dl>` grid, label column `10rem`. Below `40rem` wide, labels stack above values.

## 5. Components

### Header bar
`--lv-navy` background, white h1 "LazyVM security findings for <VM name>", with the scan time under it in `#C9D6E5`.

### Summary panel
`--lv-tint` background, radius `0.5rem`. Holds:
1. The counts line ("4 findings: 3 new, 1 still open, 0 resolved")
2. The host-only note
3. The "see findings" command

### Finding card
1. h2: `Finding 1 of 4:` + severity badge + title.
2. Severity badge: icon + word, `--lv-on-sev` text on the severity color, radius `0.25rem`, padding `0.125rem 0.5rem`.
3. Fields, always in this order: Id, Severity, What we found, Where (optional), Why it matters, How to fix, First seen, Status (chip).
4. Approve block, last.

### Command box
- White background, 1px `--lv-card-border`, radius `0.25rem`, monospace, padding `0.5rem 0.75rem`.
- Long commands wrap (`overflow-wrap: anywhere`). Never scroll sideways.
- Commands mentioned in running text (such as "How to fix") also use monospace.

### Button (one style only)
- `--lv-accent` background, **2px `--lv-navy` border, always**, `--lv-on-accent` text, radius `0.375rem`, padding `0.375rem 1rem`, minimum target 44×44px.
- Hover/pressed: `--lv-accent-hover`.
- Focus: 3px `--lv-navy` outline, 2px offset. Never remove it.
- After a copy, the label changes to "Copied" for 2 seconds and an `aria-live="polite"` region announces "Copied".
- `aria-label` names the target, for example "Copy approve command for finding 1".

## 6. Accessibility rules

1. One h1. Each finding is an h2, so screen-reader users can jump between findings.
2. Severity comes first in each heading, so it's the first thing read.
3. Never convey meaning by color alone (rule 2).
4. Honor `prefers-reduced-motion`: no animations.
5. Honor `prefers-color-scheme: dark` (section 8).
6. Test at 200% and 400% zoom and with Windows High Contrast (`forced-colors: active`). Severity icons must survive forced colors.

## 7. Content rules

1. Plain language and short sentences, as on the current page.
2. Say what LazyVM did and didn't do ("It changed nothing in this VM").
3. Label every command with where it runs: **host** or **guest**.
4. No sample or test data in shipped reports.

## 8. Dark theme

| Token | Dark value |
|---|---|
| `--lv-page` | `#0A1628` |
| `--lv-card` | `#10223D` |
| `--lv-card-border` | `#2A4468` |
| `--lv-ink` | `#E6EDF5` |
| `--lv-ink-muted` | `#A9B8CC` |
| `--lv-tint` | `#16304F` |
| Severity High / Med / Low | `#F97066` / `#FDB022` / `#84ADFF` |
| `--lv-on-sev` | `#0A1628` |

Severity badges use dark text (`#0A1628`) in the dark theme. White text is too faint on the lighter dark-theme severity colors; dark text gives at least 7:1.

The accent and button styles are unchanged. The command box becomes `#0A1628` with `--lv-ink` text.

## 9. Console (PowerShell) theme

Use `$PSStyle` and fall back to plain text when `$PSStyle.OutputRendering` is `PlainText`.

| Meaning | Color | Prefix |
|---|---|---|
| High | `$PSStyle.Foreground.BrightRed` | `[HIGH]` |
| Medium | `$PSStyle.Foreground.BrightYellow` | `[MEDIUM]` |
| Low | `$PSStyle.Foreground.BrightCyan` | `[LOW]` |
| Info | default | `[INFO]` |
| Success | `$PSStyle.Foreground.BrightGreen` | `[OK]` |

The text prefix is always printed, so screen readers and logs keep the meaning.

## 10. CSS token block

```css
:root {
  --lv-navy:#0B2E59; --lv-ink:#13223F; --lv-ink-muted:#475467;
  --lv-page:#F5F8FC; --lv-card:#FFFFFF; --lv-card-border:#C9D6E5; --lv-tint:#DCEAF8;
  --lv-accent:#FFD75E; --lv-accent-hover:#FFC929; --lv-on-accent:#0B2E59;
  --lv-sev-high:#B42318; --lv-sev-medium:#B54708; --lv-sev-low:#175CD3; --lv-sev-info:#475467;
  --lv-on-sev:#FFFFFF;
  --lv-font:"Segoe UI",system-ui,sans-serif; --lv-mono:"Cascadia Mono",Consolas,monospace;
}
@media (prefers-color-scheme: dark) {
  :root {
    --lv-page:#0A1628; --lv-card:#10223D; --lv-card-border:#2A4468; --lv-tint:#16304F;
    --lv-ink:#E6EDF5; --lv-ink-muted:#A9B8CC;
    --lv-sev-high:#F97066; --lv-sev-medium:#FDB022; --lv-sev-low:#84ADFF;
    --lv-on-sev:#0A1628;
  }
}
```
