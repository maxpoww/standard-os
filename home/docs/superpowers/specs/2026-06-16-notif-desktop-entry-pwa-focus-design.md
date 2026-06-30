# `desktop-entry` hint capture for View — PWA-safe focus

**Date:** 2026-06-16
**Status:** Approved (brainstorming, this session).
**Goal:** When the user clicks **View** on a notification, focus the specific source application — including disambiguating Chrome PWAs (WhatsApp Web, YouTube Music, etc.) from a regular Chromium window that lives on a different workspace.

## Why

View currently uses the notification's `app_name` to find a matching Hyprland window via class substring search. This fails for Chrome PWAs: WhatsApp Web's notif carries `app_name="WhatsApp Web"` (variable per-PWA) but the matched Hyprland class for a *regular* Chromium window is `chromium-browser`. View ends up focusing whichever Chromium-ish window has the highest score — usually the regular browser on a different workspace, which is exactly the wrong window.

PWAs are distinguishable in two places:
1. **The notification carries a `desktop-entry` hint** — freedesktop spec — set by Chromium to the PWA's app-specific `.desktop` file basename. For WhatsApp Web that's `chrome-hnpfjngllnobngcgfapefoaidbinmjnm-Default` (verified live in this session).
2. **The PWA's Hyprland window class matches** — exactly the same string: `chrome-hnpfjngllnobngcgfapefoaidbinmjnm-Default`.

So if the daemon captures the hint and View uses it as the class needle, the PWA window gets a clean hit and regular Chromium is correctly ignored.

## Behavior contract

| Notif `desktop-entry` hint | View match needle | Net behavior |
|---|---|---|
| present and non-empty | the hint verbatim, substring-matched against Hyprland window classes | PWA windows match their PWA class; regular Firefox/Chromium match `firefox` / `chromium-browser`; everything else still works because most apps set `desktop-entry` to their main `.desktop` file basename |
| missing or empty | `app_name` (current behavior) | Fallback covers older apps that don't set the hint |

`hypr_focus_by_class`'s existing multi-match scoring (descendant cmdline word matches, source_window tiebreak, focusHistoryID) is unchanged — only the needle string changes.

## Rust daemon — `notif-os-daemon`

### `NotifRecord`

Add one field:

```rust
pub struct NotifRecord {
    pub id: u32,
    pub app: String,
    pub summary: String,
    pub body: String,
    pub urgency: u8,
    pub actions: Vec<(String, String)>,
    pub app_icon: String,
    pub sender_pid: u32,
    pub source_window: String,
    pub ts: String,
    pub desktop_entry: String,   // NEW — freedesktop `desktop-entry` hint, "" when absent
}
```

### `notifications.rs` — `Notify` handler

Extract the hint alongside urgency:

```rust
let desktop_entry: String = hints
    .get("desktop-entry")
    .and_then(|v| <String>::try_from(v).ok())
    .unwrap_or_default();
```

Pass into the `NotifRecord` literal.

### `notifos.rs` — `ListNotifications` JSON

Add `desktop_entry: &'a str` to the `ListEntry` struct so the bash side can read it.

### `journal.rs` — JSONL writer

Add `desktop_entry: &'a str` to the `JournalLine` struct. The existing `notif-history.jsonl` file gains a field; bash readers that don't know about it just ignore it.

## Bash side — `notif-os.sh`, `notif-menu`, `notif-daemon`

### `lib/notif-os.sh`

The `mako_*` helpers that wrap `org.standardos.NotifOS.ListNotifications` already pass through the full JSON. No change needed — consumers query `.desktop_entry` directly via `jq`.

### `notif-menu`

`populate_l1` and `populate_l2_live` extract `desktop_entry` from the journal / live store alongside `ts/app/summary/body/source_window`.

Add a parallel global: `declare -A desktop_entry_at` (per-row metadata, indexed by L1 row).

`populate_l2_live` and `populate_l2_history` set `L2_DESKTOP_ENTRY="${desktop_entry_at[$l1_idx]:-}"` (paralleling `L2_SOURCE_WINDOW`).

`do_view` step 3 needle selection becomes:

```bash
local needle="$L2_APP"
[[ -n "${L2_DESKTOP_ENTRY:-}" ]] && needle="$L2_DESKTOP_ENTRY"
if hypr_focus_by_class "$needle" "${L2_SUMMARY:-}" "${L2_BODY:-}" "${L2_SOURCE_WINDOW:-}"; then
    focused=1
fi
```

Step 4's fallback notify-send keeps using `$L2_APP` for the human-readable message (the user wants "View couldn't open WhatsApp Web", not "couldn't open chrome-hnpfj...").

### `notif-daemon` (bash)

`query_mako_state` doesn't currently extract `desktop_entry`. It doesn't need to: the bash daemon only handles the wide-pill + bell pin + sound. View is dispatched from `notif-menu`, which queries the Rust daemon directly via `notif-os.sh`.

## Tests

### `notif-os-daemon` Rust tests

- `notify_extracts_desktop_entry`: feed a hints map with a string `desktop-entry`, assert the stored `NotifRecord.desktop_entry` matches.
- `notify_absent_desktop_entry_is_empty_string`: hints map without the key → empty string.
- `notify_invalid_desktop_entry_is_empty_string`: hints map with non-string desktop-entry → empty string.
- `journal_records_desktop_entry`: append a record and parse back the JSONL line, assert the field is present.
- `list_notifications_returns_desktop_entry`: store one notif, call ListNotifications, parse the JSON, assert the field.

### `notif-menu` tests

- `do_view` test cases (in `tests/notif-menu-flow-test.sh`): one new fixture where the notif has a non-empty `desktop_entry`. Assert that `hypr_focus_by_class` is called with the `desktop_entry` value as the needle.

### Live verification

- Install WhatsApp Web as a PWA via Chromium.
- Send a notif from it (or trigger from the page).
- Open notif-menu, pick View on the WhatsApp Web entry.
- The PWA window focuses regardless of which workspace it's on, even if a regular Chromium with multiple tabs is also open on another workspace.

## Risks

1. **Apps that send a `desktop-entry` that doesn't match their actual Hyprland class.** Some apps (custom GTK launchers, electron variants) set the hint inconsistently. Mitigated: substring match is forgiving; if the literal hint doesn't hit, we fall through to step 4's honest fallback notify-send. We do NOT auto-fall-back to `app_name` because that defeats the disambiguation purpose for PWAs — if a Chromium PWA's hint doesn't hit, falling back to "Chromium" would re-focus the wrong window.
2. **Existing journal entries don't have `desktop_entry`.** Lines without the field deserialize with empty string in `jq`'s `// ""` fallback. View falls back to `app_name` for those, which is the pre-change behavior. No data migration needed.
3. **Rust struct field addition is a breaking API change for the Rust daemon's tests.** Trivial fix — all `NotifRecord` literals in tests get an empty `desktop_entry: String::new()`.

## Untouched

- The Rust daemon's `org.freedesktop.Notifications` interface (Notify return-id, CloseNotification, signals) — unchanged.
- The bash daemon's wide-pill / bell-pin / sound paths — unchanged.
- `notif-rofi` (deprecated) — won't gain the feature.
- Tab-level focus inside Firefox / regular Chromium (no PWA) — explicitly out of scope per the previous brainstorming session.

## Rollback

Single commit reverts everything: the Rust `NotifRecord` field, the JSON/journal additions, the bash needle override. Journal entries with the extra field remain forward-compatible (extra `jq` fields are ignored by older readers).
