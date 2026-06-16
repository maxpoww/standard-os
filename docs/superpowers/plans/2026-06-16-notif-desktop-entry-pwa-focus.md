# `desktop-entry` PWA-safe View Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Capture the `desktop-entry` notification hint in `notif-os-daemon`, plumb it through `ListNotifications`, the JSONL journal, and the bash menu code, and use it as the Hyprland class needle so View focuses Chrome PWAs cleanly instead of falling back to a regular Chromium window.

**Architecture:** One new `String` field (`desktop_entry`) added to `NotifRecord`, the dbus `ListEntry` JSON, and the journal line. `notif-menu` reads it via `jq` alongside the existing per-row metadata, stores it in a parallel global, and passes it as the needle to `hypr_focus_by_class` (falling back to `app_name` only when the hint is absent — not when present-but-unmatched).

**Tech Stack:** Rust (zbus, serde, chrono), bash 5, jq, Hyprland (`hyprctl clients`), home-manager / nixos-rebuild for deploy.

**Spec:** `docs/superpowers/specs/2026-06-16-notif-desktop-entry-pwa-focus-design.md`

---

## File map

**Rust daemon (`/etc/nixos/home/notif-os-daemon/`):**
- `src/store.rs` — `NotifRecord` struct gains the field.
- `src/notifications.rs` — `Notify` handler extracts the hint.
- `src/notifos.rs` — `ListEntry` serializes the field.
- `src/journal.rs` — `JournalLine` serializes the field.

**Bash side (`/etc/nixos/home/scripts/`):**
- `notif-menu` — per-row metadata array, L2 hydration, do_view needle override, view_latest hydration.

**Tests:**
- `notif-os-daemon/src/notifications.rs` `#[cfg(test)]` — new unit tests for the hint extraction.
- `notif-os-daemon/src/journal.rs` `#[cfg(test)]` — new test that the line carries the field.
- `notif-os-daemon/src/notifos.rs` `#[cfg(test)]` — new test for the JSON shape.
- `tests/notif-menu-flow-test.sh` — new fixture exercising the desktop-entry override.

---

### Task 1: NotifRecord gains `desktop_entry`

**Files:**
- Modify: `/etc/nixos/home/notif-os-daemon/src/store.rs`

- [ ] **Step 1: Read the current `NotifRecord` definition**

```bash
sed -n '1,40p' /etc/nixos/home/notif-os-daemon/src/store.rs
```

Note the existing struct fields — they include `id`, `app`, `summary`, `body`, `urgency`, `actions`, `app_icon`, `sender_pid`, `source_window`, `ts`. You will add `desktop_entry: String` as the last field.

- [ ] **Step 2: Add the field**

Edit `src/store.rs`. Inside `pub struct NotifRecord { ... }`, add as the last field:

```rust
    /// `desktop-entry` freedesktop hint. "" when the source app didn't
    /// set it. For Chrome PWAs this is the PWA's .desktop basename
    /// (e.g. `chrome-cinhimbnkkaeohfgghhklpknlkffjgod-Default`) which
    /// is also the Hyprland window class — letting View focus the
    /// specific PWA rather than regular Chromium.
    pub desktop_entry: String,
```

- [ ] **Step 3: Update every `NotifRecord` literal in the same file's `#[cfg(test)]` module**

Search for `NotifRecord {` inside `src/store.rs` (look for the test helpers). Each literal needs `desktop_entry: String::new()` added as the last field. If a helper builds them with `..Default::default()` or similar, no change needed — but the struct doesn't currently derive `Default`, so this is unlikely.

- [ ] **Step 4: Compile check**

```bash
cd /etc/nixos/home/notif-os-daemon && cargo check 2>&1 | tail -20
```

Expected: compile errors will surface in other files (`notifications.rs`, `notifos.rs`, `journal.rs`) where `NotifRecord` literals exist without the new field. Those are fixed in subsequent tasks — for now confirm only the struct change compiles in isolation. If `store.rs` itself has errors, fix them.

- [ ] **Step 5: Commit**

```bash
cd /etc/nixos/home && git add notif-os-daemon/src/store.rs && \
git commit -m "notif-os-daemon: NotifRecord gains desktop_entry field"
```

---

### Task 2: Notify handler extracts `desktop-entry` from hints

**Files:**
- Modify: `/etc/nixos/home/notif-os-daemon/src/notifications.rs`

- [ ] **Step 1: Write the failing tests**

Open `src/notifications.rs`. Find the existing `#[cfg(test)]` mod at the bottom (or create one if absent). Add three tests:

```rust
#[cfg(test)]
mod desktop_entry_tests {
    use super::*;
    use crate::store::Store;
    use std::collections::HashMap;
    use zbus::zvariant::Value;

    fn record_after_notify(hints: HashMap<String, Value<'_>>) -> crate::store::NotifRecord {
        let store = Store::new();
        let notif = Notifications { store: store.clone() };
        let _id = futures::executor::block_on(notif.notify(
            "test-app".into(),
            0,
            String::new(),
            "summary".into(),
            "body".into(),
            vec![],
            hints,
            -1,
        ));
        store.list().into_iter().next().expect("one record")
    }

    #[test]
    fn notify_extracts_desktop_entry() {
        let mut hints = HashMap::new();
        hints.insert(
            "desktop-entry".to_string(),
            Value::from("chrome-abc-Default".to_string()),
        );
        let rec = record_after_notify(hints);
        assert_eq!(rec.desktop_entry, "chrome-abc-Default");
    }

    #[test]
    fn notify_absent_desktop_entry_is_empty_string() {
        let rec = record_after_notify(HashMap::new());
        assert_eq!(rec.desktop_entry, "");
    }

    #[test]
    fn notify_non_string_desktop_entry_is_empty_string() {
        let mut hints = HashMap::new();
        hints.insert("desktop-entry".to_string(), Value::from(42u32));
        let rec = record_after_notify(hints);
        assert_eq!(rec.desktop_entry, "");
    }
}
```

If `futures` isn't already a dev-dep, the harness already has tokio in tests; if `futures::executor` isn't available, use `tokio_test::block_on` or wrap in a `#[tokio::test] async fn` and `.await` directly. Inspect the existing tests in this file for the established pattern and mirror it.

- [ ] **Step 2: Run tests to verify they fail**

```bash
cd /etc/nixos/home/notif-os-daemon && cargo test desktop_entry_tests 2>&1 | tail -20
```

Expected: compilation error (NotifRecord literal missing `desktop_entry` field in the `notify` handler) OR test failures asserting on `rec.desktop_entry`.

- [ ] **Step 3: Implement the extraction**

In `src/notifications.rs`, inside the `notify` method, find the urgency extraction block:

```rust
let urgency: u8 = hints
    .get("urgency")
    .and_then(|v| u8::try_from(v).ok())
    .unwrap_or(1);
```

Add immediately after it:

```rust
let desktop_entry: String = hints
    .get("desktop-entry")
    .and_then(|v| <String>::try_from(v).ok())
    .unwrap_or_default();
```

Then add `desktop_entry,` to the `NotifRecord { ... }` literal that builds `rec` — paste the field as the last entry, matching the struct order.

- [ ] **Step 4: Run tests**

```bash
cd /etc/nixos/home/notif-os-daemon && cargo test desktop_entry_tests 2>&1 | tail -15
```

Expected: all three new tests pass.

- [ ] **Step 5: Run the full test suite to ensure nothing else broke**

```bash
cd /etc/nixos/home/notif-os-daemon && cargo test 2>&1 | tail -15
```

Expected: full pass. If any pre-existing test fails because a `NotifRecord` literal in test fixtures lacks `desktop_entry`, add the field there with `String::new()`.

- [ ] **Step 6: Commit**

```bash
cd /etc/nixos/home && git add notif-os-daemon/src/notifications.rs && \
git commit -m "notif-os-daemon: extract desktop-entry hint in Notify handler"
```

---

### Task 3: ListNotifications JSON includes `desktop_entry`

**Files:**
- Modify: `/etc/nixos/home/notif-os-daemon/src/notifos.rs`

- [ ] **Step 1: Write the failing test**

In `src/notifos.rs`, find the existing `#[cfg(test)]` mod (or create one). Add:

```rust
#[cfg(test)]
mod desktop_entry_test {
    use super::*;
    use crate::store::{NotifRecord, Store};

    #[test]
    fn list_notifications_serializes_desktop_entry() {
        let store = Store::new();
        let rec = NotifRecord {
            id: 0,
            app: "WhatsApp Web".into(),
            summary: "hi".into(),
            body: "".into(),
            urgency: 1,
            actions: vec![],
            app_icon: String::new(),
            sender_pid: 0,
            source_window: String::new(),
            ts: "2026-06-16T10:00:00-03:00".into(),
            desktop_entry: "chrome-abc-Default".into(),
        };
        store.insert(0, rec);
        let notifos = NotifOs { store };
        let json = notifos.list_notifications();
        let v: serde_json::Value = serde_json::from_str(&json).expect("valid JSON");
        assert_eq!(v[0]["desktop_entry"], "chrome-abc-Default");
    }
}
```

- [ ] **Step 2: Run the test**

```bash
cd /etc/nixos/home/notif-os-daemon && cargo test desktop_entry_test 2>&1 | tail -10
```

Expected: FAIL because `ListEntry` doesn't have `desktop_entry` yet, so the JSON field is absent.

- [ ] **Step 3: Add the field to `ListEntry`**

In `src/notifos.rs`, find the `ListEntry` struct (look for `#[derive(Serialize)]` above `struct ListEntry`):

```rust
#[derive(Serialize)]
struct ListEntry<'a> {
    id: u32,
    app: &'a str,
    summary: &'a str,
    body: &'a str,
    urgency: u8,
    actions: &'a [(String, String)],
    sender_pid: u32,
    source_window: &'a str,
    ts: &'a str,
}
```

Add `desktop_entry: &'a str` as the last field. Then in the `list_notifications` body where `ListEntry { ... }` is constructed, add `desktop_entry: &r.desktop_entry,` to the literal.

- [ ] **Step 4: Run the test**

```bash
cd /etc/nixos/home/notif-os-daemon && cargo test desktop_entry_test 2>&1 | tail -10
```

Expected: pass.

- [ ] **Step 5: Commit**

```bash
cd /etc/nixos/home && git add notif-os-daemon/src/notifos.rs && \
git commit -m "notif-os-daemon: ListNotifications JSON includes desktop_entry"
```

---

### Task 4: Journal records `desktop_entry`

**Files:**
- Modify: `/etc/nixos/home/notif-os-daemon/src/journal.rs`

- [ ] **Step 1: Write the failing test**

In `src/journal.rs`, find the existing test module. Add:

```rust
#[test]
fn journal_records_desktop_entry() {
    let tmp = tempfile::NamedTempFile::new().unwrap();
    let mut rec = rec(1, "WhatsApp Web", "ping");
    rec.desktop_entry = "chrome-abc-Default".into();
    append(tmp.path(), &rec).unwrap();
    let s = std::fs::read_to_string(tmp.path()).unwrap();
    let v: serde_json::Value = serde_json::from_str(s.trim()).unwrap();
    assert_eq!(v["desktop_entry"], "chrome-abc-Default");
}
```

The `rec` helper already exists in this module (see prior tests). Confirm by reading `tests/notif-os-daemon/src/journal.rs`'s `mod tests`. If the helper builds `NotifRecord` literals, update it to include `desktop_entry: String::new()`.

- [ ] **Step 2: Run the test**

```bash
cd /etc/nixos/home/notif-os-daemon && cargo test journal_records_desktop_entry 2>&1 | tail -10
```

Expected: FAIL — JournalLine doesn't carry the field.

- [ ] **Step 3: Add the field to `JournalLine`**

In `src/journal.rs`, find:

```rust
#[derive(Serialize)]
struct JournalLine<'a> {
    ts: &'a str,
    id: u32,
    app: &'a str,
    summary: &'a str,
    body: &'a str,
    urgency: u8,
    dismissed_at: &'a str,
    source_window: &'a str,
    sender_pid: u32,
}
```

Add `desktop_entry: &'a str` as the last field. In `append`'s body where `JournalLine { ... }` is built, add `desktop_entry: &rec.desktop_entry,` to the literal.

- [ ] **Step 4: Run the journal tests**

```bash
cd /etc/nixos/home/notif-os-daemon && cargo test --test '*' 2>&1 | tail -5
cd /etc/nixos/home/notif-os-daemon && cargo test 2>&1 | tail -10
```

Expected: full pass.

- [ ] **Step 5: Commit**

```bash
cd /etc/nixos/home && git add notif-os-daemon/src/journal.rs && \
git commit -m "notif-os-daemon: journal line includes desktop_entry"
```

---

### Task 5: `notif-menu` plumbs `desktop_entry` to do_view

**Files:**
- Modify: `/etc/nixos/home/scripts/notif-menu`

- [ ] **Step 1: Add the per-row metadata array**

In `/etc/nixos/home/scripts/notif-menu`, find the `declare -A` line near the top of the per-row metadata block (around line 39):

```bash
declare -A kind_at id_at ts_at app_at summary_at body_at urgency_at source_window_at
```

Change to:

```bash
declare -A kind_at id_at ts_at app_at summary_at body_at urgency_at source_window_at desktop_entry_at
```

In the same vicinity, find `reset_index()`:

```bash
reset_index() {
    kind_at=(); id_at=(); ts_at=(); app_at=()
    summary_at=(); body_at=(); urgency_at=(); source_window_at=()
}
```

Add `desktop_entry_at=()` at the end of that list.

- [ ] **Step 2: Update `put_row` to take and store the new field**

Find `put_row()` (~line 48). Current signature accepts: `IDX KIND [ID TS APP SUMMARY BODY URGENCY SOURCE_WINDOW]`. Extend to take an optional `DESKTOP_ENTRY` at the end:

```bash
put_row() {
    local idx="$1" kind="$2" id="${3:-}" ts="${4:-}" app="${5:-}" \
          summary="${6:-}" body="${7:-}" urgency="${8:-}" source_window="${9:-}" \
          desktop_entry="${10:-}"
    kind_at[$idx]="$kind"
    id_at[$idx]="$id"
    ts_at[$idx]="$ts"
    app_at[$idx]="$app"
    summary_at[$idx]="$summary"
    body_at[$idx]="$body"
    urgency_at[$idx]="$urgency"
    source_window_at[$idx]="$source_window"
    desktop_entry_at[$idx]="$desktop_entry"
}
```

- [ ] **Step 3: Populate desktop_entry in populate_l1**

In `populate_l1`, the Unread loop pulls fields from `tac journal | jq` then calls `put_row $idx "unread" "$id" "$ts" "$app" "$summary" "$body" "$urg" "$src"`. The jq pull currently looks like:

```bash
fields=$(tac "$JOURNAL" 2>/dev/null | jq -r --argjson id "$id" '
    select(.id == $id) | [.ts, .app, .summary, .body, (.source_window // "")] | @tsv
' 2>/dev/null | head -1)
```

Change the jq selector to also pull `desktop_entry`:

```bash
fields=$(tac "$JOURNAL" 2>/dev/null | jq -r --argjson id "$id" '
    select(.id == $id) | [.ts, .app, .summary, .body, (.source_window // ""), (.desktop_entry // "")] | @tsv
' 2>/dev/null | head -1)
```

And the read into bash vars:

```bash
IFS=$'\t' read -r ts app summary body src <<<"$fields"
```

Becomes:

```bash
IFS=$'\t' read -r ts app summary body src de <<<"$fields"
```

Update the corresponding `put_row` calls in the Unread loop to pass `"$de"` as the trailing argument:

```bash
put_row $idx "unread" "$id" "$ts" "$app" "$summary" "$body" "$urg" "$src" "$de"
```

Do the same in the fallback `fetch_live_meta` branch (set `de=""` since the live fetch doesn't read desktop_entry — or extend `fetch_live_meta` similarly if you prefer; for v1 setting `de=""` in the fallback is acceptable).

- [ ] **Step 4: Populate desktop_entry in populate_l1's History pass**

In the History pass (search for `# ── History (journal entries whose id is NOT in the live set)`), the per-line jq currently maps to:

```bash
[.id, .urgency, .ts, .app, .summary, .body, (.source_window // "")] | @tsv
```

Change to:

```bash
[.id, .urgency, .ts, .app, .summary, .body, (.source_window // ""), (.desktop_entry // "")] | @tsv
```

And the `while IFS=$'\t' read -r id urg ts app summary body src` loop becomes `... src de`. Extend `hist_buf` to include `"$de"` (append `$'\t'"$de"` after `$src`). Extend the consumer loop similarly (the loop that reads `hist_buf` for emission). Each `put_row` call in the History section gets `"$de"` appended.

- [ ] **Step 5: Hydrate `L2_DESKTOP_ENTRY` in populate_l2_live and populate_l2_history**

Find `populate_l2_live`. It currently has:

```bash
L2_SOURCE_WINDOW="${source_window_at[$l1_idx]:-}"
L2_KIND="live"
```

Add immediately after:

```bash
L2_DESKTOP_ENTRY="${desktop_entry_at[$l1_idx]:-}"
```

Do the same in `populate_l2_history` (the variant near line 243).

- [ ] **Step 6: Hydrate `L2_DESKTOP_ENTRY` in view_latest**

Find `view_latest()` (the headless entry called by `notif-click invoke-and-dismiss`). It pulls metadata from the live store via `_notif_list_raw`. Currently:

```bash
L2_SOURCE_WINDOW=$(printf '%s' "$latest_json" | jq -r '.source_window // ""')
```

Add immediately after:

```bash
L2_DESKTOP_ENTRY=$(printf '%s' "$latest_json" | jq -r '.desktop_entry // ""')
```

- [ ] **Step 7: Use `L2_DESKTOP_ENTRY` as the needle override in do_view**

Find `do_view()`. The needle override goes inside step 3 (the `hypr_focus_by_class` call). Currently:

```bash
local focused=0
if hypr_focus_by_class "$app" "${L2_SUMMARY:-}" "${L2_BODY:-}" "${L2_SOURCE_WINDOW:-}"; then
    focused=1
fi
```

Change to:

```bash
local needle="$app"
[[ -n "${L2_DESKTOP_ENTRY:-}" ]] && needle="$L2_DESKTOP_ENTRY"
_dbg "do_view step3: needle='$needle' (desktop_entry='${L2_DESKTOP_ENTRY:-}')"
local focused=0
if hypr_focus_by_class "$needle" "${L2_SUMMARY:-}" "${L2_BODY:-}" "${L2_SOURCE_WINDOW:-}"; then
    focused=1
fi
```

Keep the step 4 fallback notify-send using `$app` (the human-readable app name), NOT the needle. The fallback message is for the user, the needle is for hyprctl.

- [ ] **Step 8: Smoke-test in isolation**

Run the test suite:

```bash
bash /etc/nixos/home/tests/notif-menu-flow-test.sh 2>&1 | tail -10
```

Expected: existing tests still pass. They use mocked busctl + mocked hyprctl. If a test asserts the exact `hypr_focus_by_class` arg list, it may need updating — let the next task add the new fixture.

- [ ] **Step 9: Commit**

```bash
cd /etc/nixos/home && git add scripts/notif-menu && \
git commit -m "notif-menu: plumb desktop_entry through L2 + use as needle in do_view"
```

---

### Task 6: notif-menu-flow test — `desktop_entry` overrides app

**Files:**
- Modify: `/etc/nixos/home/tests/notif-menu-flow-test.sh`

- [ ] **Step 1: Read the existing test structure**

```bash
head -80 /etc/nixos/home/tests/notif-menu-flow-test.sh
```

The file mocks `busctl`, `hyprctl`, `jq` (or not), and `_dbg`. Identify how tests assert `hypr_focus_by_class` was called with the expected needle — typically by capturing args into a variable.

- [ ] **Step 2: Add the new test case**

Append at the end of the file (before the final exit/result check):

```bash
# ─── desktop-entry override needle ────────────────────────────────────────
# When the notif's desktop_entry is non-empty, do_view should pass it
# (not the app name) as the class needle to hypr_focus_by_class. Covers
# the Chrome PWA case where app="WhatsApp Web" but the matching window
# class is the PWA's chrome-{hash}-Default desktop-entry.

# Mock the busctl ListNotifications return so the live-fetch path
# discovers a notif with a desktop_entry set.
busctl() {
    # Match the JSON shape ListNotifications returns: { "data": [ "[...]" ] }
    printf 's "%s"' '[{"id":42,"app":"WhatsApp Web","summary":"ping","body":"hello","urgency":1,"actions":[],"sender_pid":0,"source_window":"","ts":"2026-06-16T10:00:00-03:00","desktop_entry":"chrome-abc-Default"}]' \
        | sed 's/^/{"data":["/; s/$/"]}/'
}
export -f busctl 2>/dev/null || true

# Capture the needle hyprctl was called with.
HYPR_FOCUS_NEEDLE=""
hypr_focus_by_class() {
    HYPR_FOCUS_NEEDLE="$1"
    return 0   # pretend we found a window
}

# Provide do_view's other dependencies as no-ops.
mako_has_default_action() { return 1; }
mako_invoke() { :; }
mako_dismiss() { :; }
_dbg() { :; }

# Source the menu in LIB_ONLY mode if it supports it; otherwise extract
# just do_view via awk and exercise the function directly.
unset L2_KIND L2_APP L2_SUMMARY L2_BODY L2_SOURCE_WINDOW L2_DESKTOP_ENTRY
L2_KIND="live"
L2_APP="WhatsApp Web"
L2_SUMMARY="ping"
L2_BODY="hello"
L2_SOURCE_WINDOW=""
L2_DESKTOP_ENTRY="chrome-abc-Default"

eval "$(awk '/^do_view\(\)/,/^}/' /etc/nixos/home/scripts/notif-menu)"

do_view 42 "WhatsApp Web" >/dev/null 2>&1 || true

if [[ "$HYPR_FOCUS_NEEDLE" == "chrome-abc-Default" ]]; then
    printf '✓ do_view uses desktop_entry as the hypr_focus_by_class needle\n'
else
    printf '✗ do_view needle was %q (expected "chrome-abc-Default")\n' "$HYPR_FOCUS_NEEDLE"
    fail=$((fail+1))
fi
```

If the existing test file uses a different mocking style (e.g., bats, or sourcing the full menu), mirror that style. The key assertion is: `HYPR_FOCUS_NEEDLE == "chrome-abc-Default"` after `do_view` runs with `L2_DESKTOP_ENTRY` set.

- [ ] **Step 3: Run**

```bash
bash /etc/nixos/home/tests/notif-menu-flow-test.sh 2>&1 | tail -10
```

Expected: the new test passes and the suite's "all tests passed" tail line still appears.

- [ ] **Step 4: Commit**

```bash
cd /etc/nixos/home && git add tests/notif-menu-flow-test.sh && \
git commit -m "tests: notif-menu do_view honors desktop_entry override"
```

---

### Task 7: Rebuild + live verify with a real PWA

**Files:**
- (No code changes — rebuild + live test.)

- [ ] **Step 1: Rebuild**

```bash
sudo nixos-rebuild switch 2>&1 | tail -5
```

Expected: `Done.` line. Rust daemon is rebuilt as part of the NixOS rebuild because `notif-center.nix` references the Rust source via `rustPlatform.buildRustPackage`.

- [ ] **Step 2: Restart the Rust daemon**

```bash
systemctl --user restart notif-os-daemon
sleep 1
busctl --user list 2>&1 | grep -i 'org.standardos.NotifOS' | head -2
```

Expected: the daemon owns `org.standardos.NotifOS`.

- [ ] **Step 3: Fire a notification from a Chrome PWA and confirm `desktop_entry` is captured**

If a Chrome PWA is open on the user's session (e.g. WhatsApp Web installed as PWA), have it fire a notification (e.g. receive a message). Then:

```bash
busctl --user --json=short call org.standardos.NotifOS /org/standardos/NotifOS \
    org.standardos.NotifOS ListNotifications 2>&1 \
    | jq -r '.data[0]?' | jq '.[] | {id, app, desktop_entry}'
```

Expected: the entry's `desktop_entry` is a non-empty string starting with `chrome-` (or whatever the user's PWA hash is).

If there's no live PWA notif, simulate with notify-send + the hint:

```bash
notify-send --hint=string:desktop-entry:chrome-abc-Default \
    "PWA-test" "this should show desktop-entry"
sleep 0.3
busctl --user --json=short call org.standardos.NotifOS /org/standardos/NotifOS \
    org.standardos.NotifOS ListNotifications 2>&1 \
    | jq -r '.data[0]?' | jq '.[-1] | {id, app, desktop_entry}'
```

Expected: `desktop_entry: "chrome-abc-Default"`.

- [ ] **Step 4: Verify journal records the field**

```bash
tail -1 ~/.local/share/standard-os/notif-history.jsonl | jq '{app, desktop_entry}'
```

Expected: `desktop_entry` field present (non-empty for the simulated one).

- [ ] **Step 5: Live View test**

Open WhatsApp Web (or your PWA of choice) — confirm there's a corresponding Hyprland window with class matching the desktop-entry:

```bash
hyprctl -j clients | jq -r '.[] | {class, title}' | grep -i chrome
```

Move that window to a non-current workspace. Send a notif from inside the PWA (or use notify-send with the matching desktop-entry as a stand-in). Open notif-menu, navigate to the PWA notif, pick View. The PWA window should focus and pull you to its workspace — NOT a regular Chromium window.

- [ ] **Step 6: No commit needed (verification only).**

---

### Task 8: TODO entry + closeout

**Files:**
- Modify: `/etc/nixos/home/waybar/TODO.md`

- [ ] **Step 1: Add the DONE entry**

In `waybar/TODO.md`'s `## DONE` section, at the top (newest-first), insert:

```markdown
- **2026-06-16** — **View focuses Chrome PWAs correctly via desktop-entry hint.**
  Chrome PWAs (WhatsApp Web, YouTube Music, etc.) declare a distinct
  Hyprland window class per app (`chrome-<hash>-Default`). The same
  string appears in the notification's freedesktop `desktop-entry`
  hint. Previously View used the notif's `app_name` ("WhatsApp Web")
  as the class needle, which substring-matched the wrong Chromium
  window on another workspace. Now: notif-os-daemon extracts the
  `desktop-entry` hint at Notify time, stores it in NotifRecord +
  ListNotifications JSON + the JSONL journal; notif-menu uses it as
  the hyprctl class needle in do_view, falling back to `app_name`
  ONLY when the hint is absent (intentional — falling back when the
  hint is set but unmatched would defeat the PWA disambiguation).
  **Hint:** spec at `docs/superpowers/specs/2026-06-16-notif-desktop-entry-pwa-focus-design.md`.
  **Hint:** plan at `docs/superpowers/plans/2026-06-16-notif-desktop-entry-pwa-focus.md`.
  **Hint:** simulate from CLI with
  `notify-send --hint=string:desktop-entry:chrome-XXX-Default "title" "body"`.
```

- [ ] **Step 2: Commit**

```bash
cd /etc/nixos/home && git add waybar/TODO.md && \
git commit -m "TODO: PWA-safe View via desktop-entry hint shipped"
```

---

## Self-review

1. **Spec coverage:**
   - Rust NotifRecord field → Task 1.
   - Notify handler extraction → Task 2.
   - ListNotifications JSON → Task 3.
   - Journal line → Task 4.
   - notif-menu plumbing + do_view needle override → Task 5.
   - Tests (Rust + bash) → Tasks 2, 3, 4 (Rust) + Task 6 (bash).
   - Live verification → Task 7.
   - TODO + closeout → Task 8.

2. **Placeholder scan:** No TBDs. The smoke-test step in Task 7 has a CLI-simulation fallback if no live PWA notif is handy.

3. **Type consistency:** `desktop_entry: String` in Rust, `desktop_entry` in JSON, `L2_DESKTOP_ENTRY` in bash, `desktop_entry_at` for the array, `de` for the per-row var. Consistent snake_case in JSON / Rust, ALL_CAPS for bash globals — matches the file's convention.

---

Plan complete and saved to `docs/superpowers/plans/2026-06-16-notif-desktop-entry-pwa-focus.md`. Two execution options:

1. **Subagent-Driven (recommended)** — fresh subagent per task with two-stage review.
2. **Inline Execution** — single-session batch with checkpoints.

Which approach?
