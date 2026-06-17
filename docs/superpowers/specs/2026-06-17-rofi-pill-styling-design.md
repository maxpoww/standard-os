# Rofi pill styling — make the popup visually indistinguishable from OPTIONS

**Date:** 2026-06-17
**Status:** Draft

## Why

The notif-menu rofi popup currently anchors correctly under the bell (yesterday's bellwether + this morning's cursor-anchor + clamp work) but does not visually belong to OPTIONS. The screenshot the user reacted to shows plain text rows, header lines, and a uniformly-tinted window — none of the surface / pill / glass vocabulary that defines the bar's identity. The user said: *"your menu does not look or feels like options, there is no pills. now work on the look and feel of the menu to make it look and feel like part of the bar (more options) for that you will need to mimic the waybar configuration css."*

This is the bellwether's second half: the first half put the popup *in the right place*; this one puts the popup *in the right clothes*. Five remaining rofi surfaces (apps launcher, window switcher, restore-minimized, reboot-prompt, notif-rofi legacy) will inherit the same look automatically — they all import the same shared rasi.

## Constraints (Standard-OS soul rules, inherited)

- **Closed budget** (Rule 1). The popup is allowed only what the bar is already allowed: 6 colors + 4 motions + 2 surfaces + 1 (soft inset) border. No new tokens, no per-row hue scheme, no semantic state colors here. The popup distinguishes by SURFACE level (parent vs child), not by hue.
- **No hard borders anywhere** (Rule 3). Border-radius and surface tint do the visual heavy lifting; outlines stay banned.
- **Input acknowledged; context shifts silent** (Rule 4). The popup itself is a silent context shift (no flash on open). Hover/selected state is treated as input acknowledgement and gets the universal hover-bright film.
- **Same option, same look** (Rule 6). The Dismiss / View action rows in the menu carry the same child-surface treatment that bar action pills carry. When the apps launcher gets a "+" or "kill" row later, it inherits the action-row class. No reinvention.

## Soul of the change

> Rofi is just a wide pill from the OPTIONS family. Its window is the bar's container layer; its rows are pills inside.

The existing `options-base.rasi` already states this intent in its leading comment. The current implementation only achieves it for action rows; the design below extends the treatment so every row reads as a pill, and the window itself recedes to bar-veil so the pills inside become visible.

## Architecture

Three layers, mirroring the bar's own three:

```
        Layer in bar                        Layer in popup
        ───────────────────                 ───────────────────
        window#waybar      ──────────────►  rasi `window`
          @opt-bar-veil 0.10                  @opt-bar-veil 0.10
          border-radius 30px                  border-radius 30px

        .opt-pill          ──────────────►  rasi `element normal.normal`
          @opt-surface-parent 0.30            @opt-surface-parent 0.30
          border-radius 30px (bar = pill)     border-radius 18px (popup row)

        .opt-pill-child    ──────────────►  rasi `element normal.active`
          @opt-surface-child 0.30 brighter    @opt-surface-child 0.30 brighter
          border-radius 30px                  border-radius 18px

        .opt-pill:hover    ──────────────►  rasi `element selected.*`
          inset 999px @opt-hover-bright       background-color @opt-hover-bright
          (layered film over existing bg)     (replacement — closest cairo can do)
```

The mismatch on hover is the only place rofi can't 1:1 reproduce the bar (rasi has no `box-shadow`; the existing `opt-hover-bright` token serves both purposes — over an existing surface it composites to roughly the same perceived brightness because the alpha values match).

Row border-radius is 18px (not 30px). The bar's 30px on a ~22-28 px tall pill renders as fully rounded; on a ~30 px row that's 466 px wide, 30 px is fine too — but 18 px reads more clearly as "this is a pill in a list" rather than "this is a chip." The bar's chips are emphatic because they're tiny; list pills are wide so the rounded ends feel softer. Pick 18px.

## Token mapping (rasi → waybar style.css)

The shared rasi files `options-dark.rasi` and `options-light.rasi` already define five tokens that mirror `waybar/style.css`. One addition needed:

| Token              | Today  | Add | Notes                                          |
|--------------------|--------|-----|------------------------------------------------|
| `opt-surface-parent` | yes  |     | gray 0.30 — pill rest face                     |
| `opt-surface-child`  | yes  |     | gray 0.30 brighter — action / "+" face         |
| `opt-hover-bright`   | yes  |     | white 0.30 — selected / hover film             |
| `opt-text`           | yes  |     | mode-specific: white on dark, near-black on light |
| `opt-text-dim`       | yes  |     | 55% alpha of text color — section headers     |
| `opt-bar-veil`       |      | yes | gray 0.10 — window surface (matches bar)       |

Adding `@opt-bar-veil` to both light and dark rasi files mirrors the corresponding `@define-color opt-bar-veil` in `waybar/style.css:50` (same rgba literal). Single source of truth: the rgba lives in two files (rasi + css) because rofi and gtk can't share variables; pinning the same literal in both is the documented convention (`rofi/options-base.rasi` leading comment).

## Rule deltas in `rofi/options-base.rasi`

```
window {
-    background-color: @opt-surface-parent;
-    border-radius:    14px;
+    background-color: @opt-bar-veil;
+    border-radius:    30px;       /* matches bar pill */
}

listview {
-    spacing: 2px;
+    spacing: 4px;                 /* bar's pill-to-pill rhythm */
}

element {
-    padding:       4px 10px;
-    border-radius: 10px;
+    padding:       6px 12px;
+    border-radius: 18px;
+    background-color: @opt-surface-parent;   /* NEW: every row is a pill at rest */
}

element normal.active {            /* action rows — verb + chevron */
-    background-color: @opt-surface-child;
-    border-radius:    10px;
+    background-color: @opt-surface-child;    /* unchanged tint, new radius below */
+    border-radius:    18px;
}

element normal.urgent {            /* section headers — dim, smaller, no surface */
    background-color: transparent;
    text-color:       @opt-text-dim;
-    padding:          2px 10px 0;
+    padding:          4px 12px 0;
+    /* font set smaller — see "Header font" below */
}

element selected.normal,
element selected.active,
element selected.urgent {
    background-color: @opt-hover-bright;     /* unchanged — universal bright film */
    text-color:       @opt-text;
}
```

## Header font

Section headers (`— Actions —`, `— Unread (N) —`, `— History —`) read better in a smaller weight so they recede behind the pills they label. rasi supports `font` per selector. Add to `normal.urgent`:

```
element normal.urgent {
    font: "MesloLGS NF 11";
}
```

(Body font stays `MesloLGS NF 13` from `configuration { font: ... }`.)

## What's NOT in this change (kept out of scope)

- **State colors per notification row.** Tempting to mark unread rows `opt-yes` (blue) and critical rows `opt-no` (red). Skipped because (a) Rule 1 closed budget — the pill is communicating its content via the surface level already; and (b) the menu is for picking, not for monitoring state. The bell itself shows unread count + urgency.
- **Animations on rows.** Per Rule 4 the popup is a silent context shift. No `opt-pulse` / `opt-glow` / `opt-breathe` on rows.
- **Per-row icons in the rofi listview.** Could enable `show-icons: true` (already in configuration) for app icons, but the existing notif-menu formatter doesn't emit icon paths. Defer to a separate stream if the user wants app glyphs.
- **Backdrop blur on the window.** rofi-wayland with cairo can't natively blur its backdrop the way Hyprland blurs `window#waybar`. Acceptable: the bar-veil tint at 0.10 alpha is what makes the bar feel glassy too; the Hyprland blur is icing.
- **Migration of the four other rofi surfaces.** Each follows as a separate stream (apps launcher, window switcher, restore-minimized, reboot-prompt, notif-rofi legacy). They inherit this rasi automatically so the actual change per surface is small.

## Behavior verification

| Scenario                              | Expected appearance                                            |
|---------------------------------------|----------------------------------------------------------------|
| notif-menu opens on dark wallpaper    | Bar-veil window, gray pills, white text. Pills are visible.   |
| notif-menu opens on light wallpaper   | Bar-veil window, gray pills, dark text. Pills are visible.    |
| Hover on a notification row           | White-film film replaces the gray surface (visible brighten). |
| Hover on a `▸ Dismiss all unread` row | White-film film replaces the brighter gray (still brightens). |
| Section header row                    | No pill surface, small dim text, no select highlight.         |
| Selection moves over a header         | rasi's `element selected.urgent` rule still applies hover-bright (rofi cannot skip selection); visually distinct but does NOT mislead because pressing Enter on a header is a no-op (notif-menu's L1 dispatcher ignores non-pickable indices).|
| Theme flips (light ↔ dark glass)      | Surfaces stay the same gray; text color flips. Matches bar's behavior on `/tmp/glass-mode` change. (Note: rofi reads the theme at launch, so already-open popups don't live-flip — closing+reopening picks up the new mode. Acceptable; popups are short-lived.) |

## Files touched

```
rofi/options-base.rasi    — rule edits per "Rule deltas" above
rofi/options-dark.rasi    — add @opt-bar-veil token
rofi/options-light.rasi   — add @opt-bar-veil token
```

No script changes. No Nix module changes (rofi.nix already declares all three rasi files via out-of-store symlinks; edits are live without rebuild).

## Acceptance criteria

1. Open notif-menu on the current dark glass: every row is a visible pill (gray surface), action rows are visibly brighter, headers are dim small text without a pill surface, hover film reads identically to a bar pill's hover.
2. Switch `/tmp/glass-mode` to `light`, reopen notif-menu: pills stay visible, text reads dark, look matches the bar's light-mode pill cluster.
3. Window's outer border-radius matches the bar's pill border-radius visually (30 px).
4. Token addition: `@opt-bar-veil` defined in both light/dark rasi files, rgba literal matches `waybar/style.css:50` byte-for-byte.
5. Tests still green: `tests/rofi-anchor-test.sh` (anchor + clamp don't regress), `tests/notif-menu-format-test.sh`, `tests/pill-geom-test.sh`.
6. No new `notify-send` or daemon work. Pure CSS / rasi tuning.

## Risks

- **rofi GTK rendering inconsistencies.** rofi 2.0.0 + cairo renders most rasi properties faithfully but `font: "<family> <size>"` syntax has at times been finicky on subsetted Nerd Fonts. If `font: "MesloLGS NF 11"` doesn't take, fall back to omitting it (acceptable degradation: headers stay 13 pt, lose one bit of hierarchy but everything else still works).
- **Theme-flip latency.** rofi reads `/tmp/glass-mode` at launch only. Acceptable per the table above.
- **Headers selectable by keyboard.** rofi can't be told to skip rows during navigation; up/down arrow lands on header rows. The notif-menu L1 dispatcher already no-ops on header indices, so functionally this is fine; visually the hover-bright film on a header reads as "highlighted but won't do anything." Document this in the verification table rather than work around it.
