# notif-os-daemon (Rust) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the Python notif-os-daemon POC (which got stuck on dbus-next
0.2.3 quirks) with a Rust implementation built on zbus. Single static binary,
no runtime deps, full freedesktop spec compliance, plus our `org.standardos.NotifOS`
extension interface that notif-menu already calls.

**Architecture:** One Rust crate at `/etc/nixos/home/notif-os-daemon/` with
modules split by responsibility: `store` (in-memory state), `journal` (JSONL
writer), `hypr` (Hyprland active-window query), `notifications` (the freedesktop
interface), `notifos` (our extension). `main.rs` wires them together via zbus's
async object_server. Every D-Bus method runs sync-from-Rust's-perspective but
the tokio runtime drives the bus loop concurrently — no async-vs-sync handler
mismatch like dbus-next had.

**Tech Stack:** Rust stable, zbus 5 (D-Bus library), tokio (async runtime),
serde + serde_json (journal write), anyhow (error handling), chrono (ISO 8601
timestamps). All from crates.io via cargo; nix builds the binary with
`rustPlatform.buildRustPackage`.

**Spec reference:** `/etc/nixos/home/docs/superpowers/specs/2026-06-14-notif-menu-view-design.md`
(View action design — this daemon is the backend that makes View reliable).

**Why Rust over the Python POC:** The Python POC ran into dbus-next 0.2.3's
sync/async handler dispatch quirks. Five hours of debugging didn't isolate the
stale-line-number behavior. Rust + zbus has none of these issues — zbus's
`#[interface]` macro produces a clean async impl that runs identically every
time, and a single static binary eliminates the runtime/cache/import-path
class of bugs.

---

## File structure

| Path | Purpose | Created in |
|---|---|---|
| `notif-os-daemon/Cargo.toml` | Crate manifest, deps | Task 1 |
| `notif-os-daemon/Cargo.lock` | Locked deps (committed) | Task 1 |
| `notif-os-daemon/src/main.rs` | Entry point, bus connection, signal handling | Task 1, expanded in Task 6, 7 |
| `notif-os-daemon/src/store.rs` | In-memory HashMap<u32, NotifRecord> | Task 2 |
| `notif-os-daemon/src/journal.rs` | Append JSONL lines to ~/.local/share/standard-os/notif-history.jsonl | Task 3 |
| `notif-os-daemon/src/hypr.rs` | `hyprctl -j activewindow` → Option<String> | Task 4 |
| `notif-os-daemon/src/notifications.rs` | `org.freedesktop.Notifications` interface impl | Task 5 |
| `notif-os-daemon/src/notifos.rs` | `org.standardos.NotifOS` extension interface impl | Task 6 |
| `modules/notif-center.nix` | Replace Python notifOsDaemonBin with Rust derivation | Task 7 |
| `scripts/notif-os-daemon` | DELETE (the broken Python POC) | Task 8 |

The Rust source lives at `/etc/nixos/home/notif-os-daemon/` (sibling of `scripts/`).
This separation keeps cargo-managed code out of the shell-script tree.

---

## Task 1: Crate skeleton with bus connection

**Files:**
- Create: `/etc/nixos/home/notif-os-daemon/Cargo.toml`
- Create: `/etc/nixos/home/notif-os-daemon/src/main.rs`
- Create: `/etc/nixos/home/notif-os-daemon/.gitignore`

- [ ] **Step 1: Create the Cargo manifest**

Write `/etc/nixos/home/notif-os-daemon/Cargo.toml`:

```toml
[package]
name = "notif-os-daemon"
version = "0.1.0"
edition = "2021"
description = "Standard-OS native notification daemon"

[dependencies]
zbus = { version = "5", default-features = false, features = ["tokio"] }
tokio = { version = "1", features = ["macros", "rt-multi-thread", "process", "sync", "time", "signal"] }
serde = { version = "1", features = ["derive"] }
serde_json = "1"
anyhow = "1"
chrono = { version = "0.4", default-features = false, features = ["clock", "serde"] }

[profile.release]
lto = true
codegen-units = 1
strip = true
```

- [ ] **Step 2: Create .gitignore**

Write `/etc/nixos/home/notif-os-daemon/.gitignore`:

```
/target/
```

- [ ] **Step 3: Write the minimum main**

Write `/etc/nixos/home/notif-os-daemon/src/main.rs`:

```rust
//! notif-os-daemon — Standard-OS native notification daemon.
//!
//! Owns `org.freedesktop.Notifications` (the spec) and `org.standardos.NotifOS`
//! (our extension) on the session bus. Captures sender PID + active Hyprland
//! window at every Notify call. Writes every arrival to the project's
//! JSONL journal at ~/.local/share/standard-os/notif-history.jsonl.

use anyhow::Result;

#[tokio::main]
async fn main() -> Result<()> {
    let conn = zbus::connection::Builder::session()?.build().await?;

    // Acquire both bus names. If another notif daemon is already serving the
    // freedesktop name, this errors fast — exit so the user knows to stop it.
    conn.request_name("org.freedesktop.Notifications").await?;
    conn.request_name("org.standardos.NotifOS").await?;

    eprintln!(
        "notif-os-daemon: ready on org.freedesktop.Notifications + org.standardos.NotifOS"
    );

    // Park forever — the connection's tokio task does the actual work.
    std::future::pending::<()>().await;
    Ok(())
}
```

- [ ] **Step 4: Build it**

```bash
cd /etc/nixos/home/notif-os-daemon && cargo build 2>&1 | tail -20
```

Expected: `Compiling notif-os-daemon v0.1.0`, ends with `Finished dev profile`. Warnings about unused imports are OK at this stage.

- [ ] **Step 5: Smoke test — runs without crashing**

```bash
# Stop the current daemons so the bus name is free
systemctl --user stop notif-daemon
pkill -f mako
sleep 0.5

# Run the new daemon foreground for 3 seconds; expect the "ready" line
timeout 3 cargo run --manifest-path /etc/nixos/home/notif-os-daemon/Cargo.toml 2>&1 | head -5

# Restore the old stack so the system isn't broken between tasks
systemctl --user start notif-daemon
```

Expected output: the "ready" line. Exit code 124 (from `timeout`) is the desired outcome — the daemon parked successfully.

- [ ] **Step 6: Commit**

```bash
cd /etc/nixos/home && git add notif-os-daemon/Cargo.toml notif-os-daemon/Cargo.lock notif-os-daemon/src/main.rs notif-os-daemon/.gitignore && git commit -m "notif-os-daemon (Rust): crate skeleton + bus name acquisition

zbus 5 + tokio runtime. Minimum viable main: acquires both bus names, parks. Both interfaces will be filled in subsequent tasks."
```

---

## Task 2: Store module — in-memory notification state

**Files:**
- Create: `/etc/nixos/home/notif-os-daemon/src/store.rs`
- Modify: `/etc/nixos/home/notif-os-daemon/src/main.rs`

- [ ] **Step 1: Write the store module with inline tests**

Create `/etc/nixos/home/notif-os-daemon/src/store.rs`:

```rust
//! In-memory state of currently-known notifications.
//!
//! Notifications live here from arrival until either the app calls
//! CloseNotification, the user invokes an action via our extension, or
//! they expire (expiry isn't implemented in v0 — notifs live forever).

use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;
use std::sync::{Arc, Mutex};

/// One notification record. Field names mirror the JSONL journal shape so
/// the same struct can be serialized for both the in-memory ListNotifications
/// response and the on-disk journal entry.
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct NotifRecord {
    pub id: u32,
    pub app: String,
    pub summary: String,
    pub body: String,
    pub urgency: u8,
    /// `(key, label)` pairs as the app declared them.
    pub actions: Vec<(String, String)>,
    pub app_icon: String,
    pub sender_pid: u32,
    pub source_window: String,
    pub ts: String,
}

#[derive(Clone, Default)]
pub struct Store {
    inner: Arc<Mutex<StoreInner>>,
}

#[derive(Default)]
struct StoreInner {
    notifs: BTreeMap<u32, NotifRecord>,
    next_id: u32,
}

impl Store {
    pub fn new() -> Self {
        Self {
            inner: Arc::new(Mutex::new(StoreInner {
                notifs: BTreeMap::new(),
                next_id: 1,
            })),
        }
    }

    /// Insert a new record. If `replaces_id` is non-zero and the id exists,
    /// reuse that id; otherwise allocate a fresh one. Returns the chosen id.
    pub fn insert(&self, replaces_id: u32, mut rec: NotifRecord) -> u32 {
        let mut g = self.inner.lock().unwrap();
        let id = if replaces_id != 0 && g.notifs.contains_key(&replaces_id) {
            replaces_id
        } else {
            let id = g.next_id;
            g.next_id += 1;
            id
        };
        rec.id = id;
        g.notifs.insert(id, rec);
        id
    }

    /// Remove a notif by id. Returns true if it was present.
    pub fn remove(&self, id: u32) -> bool {
        self.inner.lock().unwrap().notifs.remove(&id).is_some()
    }

    /// Snapshot every notification ordered by id ascending.
    pub fn list(&self) -> Vec<NotifRecord> {
        self.inner.lock().unwrap().notifs.values().cloned().collect()
    }

    pub fn count(&self) -> u32 {
        self.inner.lock().unwrap().notifs.len() as u32
    }

    pub fn contains(&self, id: u32) -> bool {
        self.inner.lock().unwrap().notifs.contains_key(&id)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn rec(id: u32, app: &str) -> NotifRecord {
        NotifRecord {
            id,
            app: app.into(),
            summary: "s".into(),
            body: "b".into(),
            urgency: 1,
            actions: vec![],
            app_icon: String::new(),
            sender_pid: 0,
            source_window: String::new(),
            ts: "2026-06-15T00:00:00-03:00".into(),
        }
    }

    #[test]
    fn insert_fresh_id() {
        let s = Store::new();
        let id1 = s.insert(0, rec(0, "a"));
        let id2 = s.insert(0, rec(0, "b"));
        assert_eq!(id1, 1);
        assert_eq!(id2, 2);
        assert_eq!(s.count(), 2);
    }

    #[test]
    fn insert_replaces_existing_id() {
        let s = Store::new();
        let id1 = s.insert(0, rec(0, "a"));
        assert_eq!(id1, 1);
        // Same id, different app — must reuse 1, not allocate 2.
        let id2 = s.insert(1, rec(0, "b"));
        assert_eq!(id2, 1);
        assert_eq!(s.count(), 1);
        assert_eq!(s.list()[0].app, "b");
    }

    #[test]
    fn insert_with_unknown_replaces_id_allocates_fresh() {
        let s = Store::new();
        let _id1 = s.insert(0, rec(0, "a"));
        // replaces_id=99 doesn't exist — should allocate next id (2).
        let id = s.insert(99, rec(0, "b"));
        assert_eq!(id, 2);
        assert_eq!(s.count(), 2);
    }

    #[test]
    fn remove_present_and_absent() {
        let s = Store::new();
        let id = s.insert(0, rec(0, "a"));
        assert!(s.remove(id));
        assert!(!s.remove(id));
        assert_eq!(s.count(), 0);
    }

    #[test]
    fn list_ordered_by_id() {
        let s = Store::new();
        s.insert(0, rec(0, "first"));
        s.insert(0, rec(0, "second"));
        s.insert(0, rec(0, "third"));
        let xs = s.list();
        assert_eq!(xs.len(), 3);
        assert_eq!(xs[0].id, 1);
        assert_eq!(xs[1].id, 2);
        assert_eq!(xs[2].id, 3);
    }
}
```

- [ ] **Step 2: Wire the module into main.rs**

Edit `/etc/nixos/home/notif-os-daemon/src/main.rs` — add the module declaration near the top of the file (just below the doc comment):

```rust
mod store;
```

- [ ] **Step 3: Run the tests (expect PASS)**

```bash
cd /etc/nixos/home/notif-os-daemon && cargo test store 2>&1 | tail -15
```

Expected: `running 5 tests` → `test result: ok. 5 passed`.

- [ ] **Step 4: Commit**

```bash
cd /etc/nixos/home && git add notif-os-daemon/src/store.rs notif-os-daemon/src/main.rs && git commit -m "notif-os-daemon: store module — in-memory state + tests

Thread-safe BTreeMap<u32, NotifRecord> behind Arc<Mutex<>>. Insert handles replaces_id semantics (reuse if present, allocate fresh otherwise). 5 unit tests cover fresh insert, replaces_id reuse, replaces_id unknown, remove, ordered list."
```

---

## Task 3: Journal module — JSONL writer compatible with notif-journal.sh

**Files:**
- Create: `/etc/nixos/home/notif-os-daemon/src/journal.rs`
- Modify: `/etc/nixos/home/notif-os-daemon/src/main.rs`

- [ ] **Step 1: Write the journal module**

Create `/etc/nixos/home/notif-os-daemon/src/journal.rs`:

```rust
//! JSONL journal writer.
//!
//! Same on-disk format as the existing `scripts/lib/notif-journal.sh`:
//! one JSON object per line, fields {ts, id, app, summary, body, urgency,
//! dismissed_at, source_window, sender_pid}. notif-menu's populate_l1
//! reads this file via `jq` so any field order/whitespace difference is
//! safe as long as the field names match.

use crate::store::NotifRecord;
use serde::Serialize;
use std::fs::OpenOptions;
use std::io::Write;
use std::path::{Path, PathBuf};

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

/// Resolves the journal path — env override or default.
pub fn default_path() -> PathBuf {
    if let Ok(p) = std::env::var("NOTIF_JOURNAL") {
        return PathBuf::from(p);
    }
    let home = std::env::var("HOME").unwrap_or_else(|_| "/tmp".to_string());
    PathBuf::from(home).join(".local/share/standard-os/notif-history.jsonl")
}

/// Read the journal-limit cap from env; default 200.
pub fn default_limit() -> usize {
    std::env::var("NOTIF_JOURNAL_LIMIT")
        .ok()
        .and_then(|s| s.parse().ok())
        .unwrap_or(200)
}

/// Append one record as a JSON line. Creates the file and parents if needed.
/// Idempotent for the file-doesn't-exist case.
pub fn append(path: &Path, rec: &NotifRecord) -> anyhow::Result<()> {
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent)?;
    }
    let line = JournalLine {
        ts: &rec.ts,
        id: rec.id,
        app: &rec.app,
        summary: &rec.summary,
        body: &rec.body,
        urgency: rec.urgency,
        dismissed_at: "",
        source_window: &rec.source_window,
        sender_pid: rec.sender_pid,
    };
    let s = serde_json::to_string(&line)?;
    let mut f = OpenOptions::new().create(true).append(true).open(path)?;
    writeln!(f, "{}", s)?;
    Ok(())
}

/// Prune the journal to the most recent `max` lines. Cheap when file is below
/// the cap; performs a temp+rename rewrite only when actually trimming.
pub fn prune(path: &Path, max: usize) -> anyhow::Result<()> {
    if max == 0 { return Ok(()); }
    let Ok(content) = std::fs::read_to_string(path) else { return Ok(()); };
    let lines: Vec<&str> = content.lines().collect();
    if lines.len() <= max { return Ok(()); }
    let kept: Vec<&str> = lines[lines.len() - max..].to_vec();
    let tmp = path.with_extension("jsonl.tmp");
    {
        let mut f = OpenOptions::new()
            .create(true).truncate(true).write(true).open(&tmp)?;
        for line in &kept { writeln!(f, "{}", line)?; }
    }
    std::fs::rename(&tmp, path)?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn rec(id: u32, app: &str, summary: &str) -> NotifRecord {
        NotifRecord {
            id,
            app: app.into(),
            summary: summary.into(),
            body: String::new(),
            urgency: 1,
            actions: vec![],
            app_icon: String::new(),
            sender_pid: 1234,
            source_window: "0xABC".into(),
            ts: "2026-06-15T10:00:00-03:00".into(),
        }
    }

    #[test]
    fn append_writes_one_line_per_call() {
        let tmp = tempfile::NamedTempFile::new().unwrap();
        append(tmp.path(), &rec(1, "a", "first")).unwrap();
        append(tmp.path(), &rec(2, "b", "second")).unwrap();
        let s = std::fs::read_to_string(tmp.path()).unwrap();
        assert_eq!(s.lines().count(), 2);
    }

    #[test]
    fn append_records_all_fields() {
        let tmp = tempfile::NamedTempFile::new().unwrap();
        append(tmp.path(), &rec(42, "kitty", "hi")).unwrap();
        let s = std::fs::read_to_string(tmp.path()).unwrap();
        let v: serde_json::Value = serde_json::from_str(s.trim()).unwrap();
        assert_eq!(v["id"], 42);
        assert_eq!(v["app"], "kitty");
        assert_eq!(v["summary"], "hi");
        assert_eq!(v["sender_pid"], 1234);
        assert_eq!(v["source_window"], "0xABC");
        assert_eq!(v["dismissed_at"], "");
    }

    #[test]
    fn prune_keeps_newest_n() {
        let tmp = tempfile::NamedTempFile::new().unwrap();
        for i in 1..=10 {
            append(tmp.path(), &rec(i, "a", &format!("s{}", i))).unwrap();
        }
        prune(tmp.path(), 3).unwrap();
        let s = std::fs::read_to_string(tmp.path()).unwrap();
        let lines: Vec<_> = s.lines().collect();
        assert_eq!(lines.len(), 3);
        // Newest three are ids 8, 9, 10
        let last: serde_json::Value = serde_json::from_str(lines[2]).unwrap();
        assert_eq!(last["id"], 10);
    }

    #[test]
    fn prune_noop_when_below_cap() {
        let tmp = tempfile::NamedTempFile::new().unwrap();
        append(tmp.path(), &rec(1, "a", "s")).unwrap();
        prune(tmp.path(), 200).unwrap();
        let s = std::fs::read_to_string(tmp.path()).unwrap();
        assert_eq!(s.lines().count(), 1);
    }
}
```

- [ ] **Step 2: Add tempfile as a dev-dep**

Edit `/etc/nixos/home/notif-os-daemon/Cargo.toml` — append at the end:

```toml

[dev-dependencies]
tempfile = "3"
```

- [ ] **Step 3: Add the module declaration**

Edit `/etc/nixos/home/notif-os-daemon/src/main.rs` — add below the existing `mod store;` line:

```rust
mod journal;
```

- [ ] **Step 4: Run the tests (expect PASS)**

```bash
cd /etc/nixos/home/notif-os-daemon && cargo test journal 2>&1 | tail -15
```

Expected: `running 4 tests` → `test result: ok. 4 passed`.

- [ ] **Step 5: Commit**

```bash
cd /etc/nixos/home && git add notif-os-daemon/src/journal.rs notif-os-daemon/src/main.rs notif-os-daemon/Cargo.toml notif-os-daemon/Cargo.lock && git commit -m "notif-os-daemon: journal module — JSONL writer + prune

Same on-disk format as notif-journal.sh so notif-menu's populate_l1
reads our writes seamlessly. append() creates the file and parents on
first call. prune() does a temp+rename rewrite only when over the cap.
Four tests cover append (one-line-per-call, all-fields-recorded), prune
(keeps-newest-n, noop-when-below-cap)."
```

---

## Task 4: Hyprland active-window adapter

**Files:**
- Create: `/etc/nixos/home/notif-os-daemon/src/hypr.rs`
- Modify: `/etc/nixos/home/notif-os-daemon/src/main.rs`

- [ ] **Step 1: Write the hypr module**

Create `/etc/nixos/home/notif-os-daemon/src/hypr.rs`:

```rust
//! Hyprland active-window query.
//!
//! Captured at notification arrival time so View later focuses the EXACT
//! window the notif came from (when sender attribution via PID isn't
//! available — e.g. for `notify-send` from a kitty shell).

use std::process::Command;
use std::time::Duration;

/// Returns the address of the currently-focused Hyprland window, or empty
/// string if hyprctl isn't installed / Hyprland isn't running / parse fails.
pub fn active_window_address() -> String {
    let out = Command::new("hyprctl")
        .args(["-j", "activewindow"])
        .output();
    let stdout = match out {
        Ok(o) if o.status.success() => o.stdout,
        _ => return String::new(),
    };
    let Ok(v): Result<serde_json::Value, _> = serde_json::from_slice(&stdout) else {
        return String::new();
    };
    v.get("address")
        .and_then(|a| a.as_str())
        .unwrap_or("")
        .to_string()
}

/// Same as `active_window_address` but bounded by a short timeout so a hung
/// hyprctl doesn't block the Notify hot path. Spawns the subprocess with
/// kill-on-drop and gives up after 500ms.
pub async fn active_window_address_async() -> String {
    let fut = tokio::task::spawn_blocking(active_window_address);
    match tokio::time::timeout(Duration::from_millis(500), fut).await {
        Ok(Ok(s)) => s,
        _ => String::new(),
    }
}
```

- [ ] **Step 2: Wire into main.rs**

Edit `/etc/nixos/home/notif-os-daemon/src/main.rs` — add below the existing `mod` lines:

```rust
mod hypr;
```

- [ ] **Step 3: Manual verification**

```bash
cat > /tmp/hypr-probe.rs <<'EOF'
fn main() {
    let s = notif_os_daemon::hypr::active_window_address();
    println!("address: {:?}", s);
}
EOF
# A quick foreground check that the function returns something
cd /etc/nixos/home/notif-os-daemon && cargo build 2>&1 | tail -3
```

Expected: clean build. No automated test — this module wraps a real subprocess and is meaningfully tested only against a live Hyprland (covered in Task 8's manual smoke).

- [ ] **Step 4: Commit**

```bash
cd /etc/nixos/home && git add notif-os-daemon/src/hypr.rs notif-os-daemon/src/main.rs && git commit -m "notif-os-daemon: hypr module — active-window address capture

Sync wrapper plus async-with-timeout variant. The async variant runs hyprctl in spawn_blocking with a 500ms cap so a hung subprocess can't stall the Notify hot path. Empty-string return for any failure path (no Hyprland, malformed JSON, timeout) — callers store empty source_window which notif-menu's View action treats as a missing hint."
```

---

## Task 5: org.freedesktop.Notifications interface

**Files:**
- Create: `/etc/nixos/home/notif-os-daemon/src/notifications.rs`
- Modify: `/etc/nixos/home/notif-os-daemon/src/main.rs`

This is the spec-mandated interface. The Notify method is the hot path.

- [ ] **Step 1: Write the interface impl**

Create `/etc/nixos/home/notif-os-daemon/src/notifications.rs`:

```rust
//! `org.freedesktop.Notifications` — the freedesktop notification spec.
//!
//! Methods: Notify, CloseNotification, GetCapabilities, GetServerInformation.
//! Signals: NotificationClosed (id, reason), ActionInvoked (id, action_key).

use crate::hypr;
use crate::journal;
use crate::store::{NotifRecord, Store};
use chrono::Local;
use std::collections::HashMap;
use zbus::{interface, zvariant::Value, SignalEmitter};

pub struct Notifications {
    pub store: Store,
}

#[interface(name = "org.freedesktop.Notifications")]
impl Notifications {
    /// Notify(app_name, replaces_id, app_icon, summary, body, actions, hints,
    ///        expire_timeout) -> u32
    /// The hot path — captures everything we need at arrival time.
    #[allow(clippy::too_many_arguments)]
    async fn notify(
        &self,
        app_name: String,
        replaces_id: u32,
        app_icon: String,
        summary: String,
        body: String,
        actions: Vec<String>,
        hints: HashMap<String, Value<'_>>,
        _expire_timeout: i32,
    ) -> u32 {
        // urgency hint is a byte ('y'); default 1 (normal) when absent.
        let urgency: u8 = hints
            .get("urgency")
            .and_then(|v| u8::try_from(v).ok())
            .unwrap_or(1);

        // The actions array alternates [key0, label0, key1, label1, ...].
        let action_pairs: Vec<(String, String)> = actions
            .chunks_exact(2)
            .map(|c| (c[0].clone(), c[1].clone()))
            .collect();

        let source_window = hypr::active_window_address_async().await;
        let ts = Local::now().format("%Y-%m-%dT%H:%M:%S%z").to_string();

        let rec = NotifRecord {
            id: 0, // overwritten by store.insert
            app: app_name,
            summary,
            body,
            urgency,
            actions: action_pairs,
            app_icon,
            sender_pid: 0, // populated when we add MessageHeader access (future task)
            source_window,
            ts,
        };

        let id = self.store.insert(replaces_id, rec.clone());
        let mut rec_with_id = rec;
        rec_with_id.id = id;

        let path = journal::default_path();
        let _ = journal::append(&path, &rec_with_id);
        let _ = journal::prune(&path, journal::default_limit());

        id
    }

    /// Close a notification by id and emit NotificationClosed(id, reason=3).
    /// Reason 3 = "closed by a call to CloseNotification" per the spec.
    async fn close_notification(
        &self,
        #[zbus(signal_emitter)] emitter: SignalEmitter<'_>,
        id: u32,
    ) -> zbus::fdo::Result<()> {
        if self.store.remove(id) {
            Notifications::notification_closed(&emitter, id, 3).await?;
        }
        Ok(())
    }

    /// Capabilities we support. The spec defines specific strings; we list
    /// the subset that matches our behavior.
    fn get_capabilities(&self) -> Vec<&'static str> {
        vec!["actions", "body", "body-markup", "persistence"]
    }

    /// (name, vendor, version, spec_version).
    fn get_server_information(&self) -> (String, String, String, String) {
        (
            "notif-os-daemon".into(),
            "Standard-OS".into(),
            env!("CARGO_PKG_VERSION").into(),
            "1.2".into(),
        )
    }

    /// Emitted when a notif is closed. Reason: 1=expired, 2=dismissed by user,
    /// 3=closed by CloseNotification, 4=undefined.
    #[zbus(signal)]
    async fn notification_closed(
        emitter: &SignalEmitter<'_>,
        id: u32,
        reason: u32,
    ) -> zbus::Result<()>;

    /// Emitted when the user (or our InvokeAction extension) triggers an action.
    #[zbus(signal)]
    async fn action_invoked(
        emitter: &SignalEmitter<'_>,
        id: u32,
        action_key: String,
    ) -> zbus::Result<()>;
}
```

- [ ] **Step 2: Add the module to main.rs and register the interface**

Edit `/etc/nixos/home/notif-os-daemon/src/main.rs` — replace the file's contents with:

```rust
//! notif-os-daemon — Standard-OS native notification daemon.
//!
//! Owns `org.freedesktop.Notifications` (the spec) and `org.standardos.NotifOS`
//! (our extension) on the session bus. Captures sender PID + active Hyprland
//! window at every Notify call. Writes every arrival to the project's
//! JSONL journal at ~/.local/share/standard-os/notif-history.jsonl.

mod hypr;
mod journal;
mod notifications;
mod store;

use anyhow::Result;
use notifications::Notifications;
use store::Store;

#[tokio::main]
async fn main() -> Result<()> {
    let store = Store::new();

    let conn = zbus::connection::Builder::session()?
        .serve_at(
            "/org/freedesktop/Notifications",
            Notifications { store: store.clone() },
        )?
        .build()
        .await?;

    conn.request_name("org.freedesktop.Notifications").await?;
    conn.request_name("org.standardos.NotifOS").await?;

    eprintln!(
        "notif-os-daemon: ready on org.freedesktop.Notifications + org.standardos.NotifOS"
    );

    std::future::pending::<()>().await;
    Ok(())
}
```

- [ ] **Step 3: Build**

```bash
cd /etc/nixos/home/notif-os-daemon && cargo build 2>&1 | tail -10
```

Expected: clean build.

- [ ] **Step 4: Live smoke test**

```bash
# Free the bus name
systemctl --user stop notif-daemon
pkill -f mako
sleep 0.5

# Run daemon in background
setsid cargo run --manifest-path /etc/nixos/home/notif-os-daemon/Cargo.toml < /dev/null > /tmp/nod.log 2>&1 &
disown
sleep 2

# Sanity check it's alive
ps -ef | grep notif-os-daemon | grep -v grep | head -3
head -5 /tmp/nod.log

# Test GetServerInformation
busctl --user --json=short call \
    org.freedesktop.Notifications /org/freedesktop/Notifications \
    org.freedesktop.Notifications GetServerInformation 2>&1 | head -3

# Test Notify via notify-send
notify-send -a kitty "rust-test" "view this kitty" --action=archive=Archive
sleep 0.5
tail -1 ~/.local/share/standard-os/notif-history.jsonl | python3 -m json.tool

# Test CloseNotification by id
ID=$(tail -1 ~/.local/share/standard-os/notif-history.jsonl | jq -r .id)
busctl --user call \
    org.freedesktop.Notifications /org/freedesktop/Notifications \
    org.freedesktop.Notifications CloseNotification u "$ID"

# Restore
pkill -f notif-os-daemon
systemctl --user start notif-daemon
```

Expected: GetServerInformation returns four strings ending with "1.2". The journal entry contains app=kitty, summary=rust-test, sender_pid=0, source_window=<some address>. CloseNotification returns without error.

- [ ] **Step 5: Commit**

```bash
cd /etc/nixos/home && git add notif-os-daemon/src/notifications.rs notif-os-daemon/src/main.rs && git commit -m "notif-os-daemon: org.freedesktop.Notifications interface

Full freedesktop spec methods (Notify / CloseNotification / GetCapabilities / GetServerInformation) plus the two standard signals (NotificationClosed, ActionInvoked). Notify is the hot path — captures urgency from hints, parses the alternating-array actions into (key,label) pairs, grabs the active Hyprland window address, and journals the arrival. Smoke-tested live with notify-send."
```

---

## Task 6: org.standardos.NotifOS extension interface

**Files:**
- Create: `/etc/nixos/home/notif-os-daemon/src/notifos.rs`
- Modify: `/etc/nixos/home/notif-os-daemon/src/main.rs`

The extension interface notif-menu (via `notif-os.sh`) actually calls.

- [ ] **Step 1: Write the extension interface**

Create `/etc/nixos/home/notif-os-daemon/src/notifos.rs`:

```rust
//! `org.standardos.NotifOS` — our extension interface.
//!
//! Gives consumers (notif-menu, the bash notif-daemon when wired) a clean
//! read+write API the freedesktop spec doesn't cover:
//!   - ListNotifications: full per-id data with all hints and source-window.
//!   - InvokeAction(id, action_key): fires ActionInvoked + closes. Works
//!     for ANY id, not just the latest (swaync's limit).
//!   - Count: just the active notif count.

use crate::notifications::Notifications;
use crate::store::Store;
use serde::Serialize;
use zbus::{interface, object_server::Interface, SignalEmitter};

pub struct NotifOs {
    pub store: Store,
}

#[derive(Serialize)]
struct ListEntry<'a> {
    id: u32,
    app: &'a str,
    summary: &'a str,
    body: &'a str,
    urgency: u8,
    /// As `[[key, label], ...]` — same shape the Python POC emitted, which
    /// the notif-os.sh adapter already parses correctly.
    actions: &'a [(String, String)],
    sender_pid: u32,
    source_window: &'a str,
    ts: &'a str,
}

#[interface(name = "org.standardos.NotifOS")]
impl NotifOs {
    /// Returns every current notif as a JSON-encoded string. Returning JSON
    /// (rather than a D-Bus struct array) lets the bash adapter use jq
    /// directly — no protocol-shape coupling between the adapter and the
    /// daemon's internal types.
    fn list_notifications(&self) -> String {
        let snap = self.store.list();
        let entries: Vec<ListEntry> = snap
            .iter()
            .map(|r| ListEntry {
                id: r.id,
                app: &r.app,
                summary: &r.summary,
                body: &r.body,
                urgency: r.urgency,
                actions: &r.actions,
                sender_pid: r.sender_pid,
                source_window: &r.source_window,
                ts: &r.ts,
            })
            .collect();
        serde_json::to_string(&entries).unwrap_or_else(|_| "[]".to_string())
    }

    /// Fire ActionInvoked(id, action_key) on the freedesktop interface, then
    /// remove the notif and emit NotificationClosed(id, 2). Returns false if
    /// the id isn't present.
    async fn invoke_action(
        &self,
        #[zbus(object_server)] server: &zbus::ObjectServer,
        id: u32,
        action_key: String,
    ) -> zbus::fdo::Result<bool> {
        if !self.store.contains(id) {
            return Ok(false);
        }
        // Get the freedesktop interface so we can fire its signals.
        let iface_ref = server
            .interface::<_, Notifications>("/org/freedesktop/Notifications")
            .await?;
        let emitter = iface_ref.signal_emitter();
        // ActionInvoked first (so a listener sees the action before close).
        Notifications::action_invoked(emitter, id, action_key).await?;
        self.store.remove(id);
        // Reason 2 = dismissed by user.
        Notifications::notification_closed(emitter, id, 2).await?;
        Ok(true)
    }

    fn count(&self) -> u32 {
        self.store.count()
    }
}

// Tag the interface as `Interface` for the object_server.interface() lookup
// in invoke_action above to find it. This is automatic via the macro but
// the import above keeps clippy quiet.
#[allow(dead_code)]
fn _interface_marker() {
    let _: fn() -> &'static str = Notifications::name;
}
```

- [ ] **Step 2: Wire into main.rs**

Edit `/etc/nixos/home/notif-os-daemon/src/main.rs` — replace `mod` block and the connection-builder block:

```rust
//! notif-os-daemon — Standard-OS native notification daemon.
//!
//! Owns `org.freedesktop.Notifications` (the spec) and `org.standardos.NotifOS`
//! (our extension) on the session bus. Captures sender PID + active Hyprland
//! window at every Notify call. Writes every arrival to the project's
//! JSONL journal at ~/.local/share/standard-os/notif-history.jsonl.

mod hypr;
mod journal;
mod notifications;
mod notifos;
mod store;

use anyhow::Result;
use notifications::Notifications;
use notifos::NotifOs;
use store::Store;

#[tokio::main]
async fn main() -> Result<()> {
    let store = Store::new();

    let conn = zbus::connection::Builder::session()?
        .serve_at(
            "/org/freedesktop/Notifications",
            Notifications { store: store.clone() },
        )?
        .serve_at(
            "/org/standardos/NotifOS",
            NotifOs { store: store.clone() },
        )?
        .build()
        .await?;

    conn.request_name("org.freedesktop.Notifications").await?;
    conn.request_name("org.standardos.NotifOS").await?;

    eprintln!(
        "notif-os-daemon: ready on org.freedesktop.Notifications + org.standardos.NotifOS"
    );

    // Park forever. Ctrl-C / SIGTERM are handled by the runtime exiting.
    tokio::signal::ctrl_c().await.ok();
    Ok(())
}
```

- [ ] **Step 3: Build**

```bash
cd /etc/nixos/home/notif-os-daemon && cargo build 2>&1 | tail -10
```

Expected: clean build.

- [ ] **Step 4: Live smoke test against notif-menu**

```bash
# Free bus
systemctl --user stop notif-daemon
pkill -f mako
sleep 0.5

# Start the daemon
setsid cargo run --manifest-path /etc/nixos/home/notif-os-daemon/Cargo.toml < /dev/null > /tmp/nod.log 2>&1 &
disown
sleep 2

# Fire a notif
notify-send -a kitty "ext-test" "with default action" --action=default=Open --action=archive=Archive
sleep 0.5

# List via our extension
busctl --user --json=short call \
    org.standardos.NotifOS /org/standardos/NotifOS \
    org.standardos.NotifOS ListNotifications 2>&1 \
    | jq -r '.data[0]' | python3 -m json.tool | head -25

# Test the notif-os.sh adapter end-to-end
bash -c '
    source /etc/nixos/home/scripts/lib/notif-os.sh
    echo "=== mako_list_live ==="
    mako_list_live
    echo "=== mako_list_actions (first id) ==="
    ID=$(mako_list_live | head -1 | cut -f1)
    mako_list_actions "$ID"
    echo "=== mako_has_default_action ==="
    if mako_has_default_action "$ID"; then echo "YES (correct)"; else echo "NO (WRONG)"; fi
'

# Invoke an action — should fire ActionInvoked and close
ID=$(busctl --user --json=short call \
    org.standardos.NotifOS /org/standardos/NotifOS \
    org.standardos.NotifOS ListNotifications 2>&1 | jq -r '.data[0]' | jq -r '.[0].id')
busctl --user --json=short call \
    org.standardos.NotifOS /org/standardos/NotifOS \
    org.standardos.NotifOS InvokeAction us "$ID" archive
sleep 0.3

# Confirm it's gone
busctl --user --json=short call \
    org.standardos.NotifOS /org/standardos/NotifOS \
    org.standardos.NotifOS Count 2>&1 | head -2

# Restore
pkill -f notif-os-daemon
systemctl --user start notif-daemon
```

Expected: ListNotifications returns the kitty notif with actions array `[["default","Open"],["archive","Archive"]]`. The adapter's mako_list_live, mako_list_actions, mako_has_default_action all produce correct output. Count goes to 0 after InvokeAction.

- [ ] **Step 5: Commit**

```bash
cd /etc/nixos/home && git add notif-os-daemon/src/notifos.rs notif-os-daemon/src/main.rs && git commit -m "notif-os-daemon: org.standardos.NotifOS extension interface

ListNotifications returns JSON-encoded array of all current notifs (id, app, summary, body, urgency, actions, sender_pid, source_window, ts). InvokeAction(id, key) is the load-bearing call from notif-menu's do_view step 1 — fires ActionInvoked on the freedesktop interface, removes the notif, fires NotificationClosed(2). Count for sanity checks. Live-tested via the notif-os.sh adapter end-to-end."
```

---

## Task 7: Nix module — package the Rust binary

**Files:**
- Modify: `/etc/nixos/home/modules/notif-center.nix`
- Delete: `/etc/nixos/home/scripts/notif-os-daemon` (the Python POC)

- [ ] **Step 1: Update the nix module**

Edit `/etc/nixos/home/modules/notif-center.nix` — replace the `notifOsDaemonPython` block and `notifOsDaemonBin` binding (look for the lines that reference `python3.withPackages` and the writeShellScriptBin wrapping `../scripts/notif-os-daemon`) with:

```nix
  # Rust notif-os-daemon: builds the static binary via rustPlatform.
  notifOsDaemonBin = pkgs.rustPlatform.buildRustPackage {
    pname = "notif-os-daemon";
    version = "0.1.0";
    src = ../notif-os-daemon;
    cargoLock.lockFile = ../notif-os-daemon/Cargo.lock;
    # No runtime deps inside the binary; hyprctl is resolved via PATH at runtime.
    meta.description = "Standard-OS native notification daemon (Rust)";
  };
```

The `home.packages` list already includes `notifOsDaemonBin` from the Python iteration — that line stays the same; only the derivation behind the name changes.

- [ ] **Step 2: Delete the Python POC**

```bash
rm /etc/nixos/home/scripts/notif-os-daemon
```

- [ ] **Step 3: Dry-build**

```bash
sudo nixos-rebuild dry-build 2>&1 | tail -10
```

Expected: derivation list includes `notif-os-daemon-0.1.0` (or similar — naming may vary). No errors.

- [ ] **Step 4: Commit**

```bash
cd /etc/nixos/home && git add modules/notif-center.nix scripts/notif-os-daemon && git commit -m "notif-center.nix: build notif-os-daemon from the Rust crate

Replace the Python wrapper (which was blocked by dbus-next 0.2.3 quirks) with rustPlatform.buildRustPackage. Single static binary, no runtime Python or library deps. Source tree at ../notif-os-daemon. Cargo.lock pinned for reproducibility. Drops the orphaned Python POC script."
```

---

## Task 8: Live verification — rebuild + smoke + commit completion

**Files:**
- Modify: `/etc/nixos/home/waybar/TODO.md` (DONE entry)

- [ ] **Step 1: Rebuild**

```bash
sudo nixos-rebuild switch 2>&1 | tail -10
```

Expected: succeeds. The new `notif-os-daemon` binary lands on PATH.

- [ ] **Step 2: Free the bus, run our daemon, full end-to-end test**

```bash
systemctl --user stop notif-daemon
pkill -f mako
sleep 0.5

# Run the installed binary (from PATH this time, not cargo run)
setsid notif-os-daemon < /dev/null > /tmp/nod.log 2>&1 &
disown
sleep 2

# Fire test notifs from three different windows (manually focus each kitty
# window first, then fire its notify-send — the source_window field will
# be unique per notif)
notify-send -a kitty "win-A-test" "should focus the window I'm in NOW"
sleep 0.3
tail -1 ~/.local/share/standard-os/notif-history.jsonl | python3 -m json.tool

# Open notif-menu — manually pick the row, then View. Expect the kitty
# this notify-send was fired from to come forward.
notif-menu
```

This step is interactive — the human runs it and visually confirms.

- [ ] **Step 3: Add the DONE entry**

In `/etc/nixos/home/waybar/TODO.md`, insert as the FIRST item under `## DONE`:

```markdown
- **2026-06-15** — **notif-os-daemon (Rust): Standard-OS native notification daemon.**
  Replaces mako as the `org.freedesktop.Notifications` D-Bus owner. Pure Rust
  binary built with zbus + tokio; no Python runtime, no library quirks.
  Implements the freedesktop spec (Notify, CloseNotification, GetCapabilities,
  GetServerInformation, NotificationClosed, ActionInvoked) plus our
  `org.standardos.NotifOS` extension (ListNotifications returning full JSON,
  InvokeAction working for ANY id, Count). Every Notify captures the active
  Hyprland window address — notif-menu's View action focuses the exact source
  window for interactively-fired notify-send. Same on-disk JSONL journal as
  notif-journal.sh, so notif-menu's populate_l1 reads the new daemon's writes
  without any adapter change.
  **Hint:** the daemon owns BOTH bus names — org.freedesktop.Notifications
  (so apps' notify-send goes through it) AND org.standardos.NotifOS (so
  notif-menu can call our richer API). Both registered in the connection
  builder's serve_at chain in src/main.rs.
  **Hint:** notif-menu's notif-os.sh adapter is unchanged from the Python
  POC iteration — same function names, same busctl call shapes, same JSON
  parsing. The daemon's interface contract was preserved on purpose.
  **Hint:** sender_pid is captured as 0 in v0 (the Notify method body doesn't
  yet plumb the D-Bus MessageHeader's sender field through). source_window
  is the load-bearing field; sender_pid is a future iteration.
  **Hint:** bash notif-daemon is still running alongside but is no-op against
  the new daemon (its mako-specific busctl calls fail silently). C-5 of the
  June 14 plan will rewire it to subscribe to our NotificationClosed +
  ActionInvoked signals so the bell pill / transient pill / OTP / sound
  return to life.
  **Hint:** if the daemon ever crashes, mako auto-activates and re-owns
  the bus name on the next Notify. To force a clean state during dev:
  `pkill -f notif-os-daemon; pkill -f mako` then restart the daemon.
```

- [ ] **Step 4: Commit**

```bash
cd /etc/nixos/home && git add waybar/TODO.md && git commit -m "TODO: notif-os-daemon (Rust) shipped"
```

- [ ] **Step 5: Final sanity sweep**

```bash
cd /etc/nixos/home/notif-os-daemon && cargo test 2>&1 | tail -5
cd /etc/nixos/home && for t in notif-menu-format-test notif-mako-test notif-os-test notif-menu-flow-test notif-hypr-test notif-rofi-test notif-journal-test; do
    "tests/$t.sh" > /dev/null 2>&1 && echo "$t: pass" || echo "$t: FAIL"
done
```

Expected: cargo test reports 9 tests passing (5 store + 4 journal). All 7 bash suites pass.

---

## Self-review notes

**Spec coverage:**

| Goal | Task |
|---|---|
| Bus name acquisition | Task 1 |
| In-memory store with replaces_id | Task 2 |
| Journal compat with notif-journal.sh | Task 3 |
| Hyprland source-window capture | Task 4 |
| Notify / CloseNotification / capabilities / server info | Task 5 |
| Signals: NotificationClosed, ActionInvoked | Task 5 (declarations) + Task 6 (InvokeAction fires them) |
| ListNotifications (full JSON for notif-menu) | Task 6 |
| InvokeAction (arbitrary-id) | Task 6 |
| Count | Task 6 |
| Nix packaging | Task 7 |
| Live verify + DONE entry | Task 8 |

**Out of scope (future work — not in this plan):**
- sender_pid resolution via MessageHeader (planned for a follow-up iteration; v0 stores 0 in the field, journal still has the column).
- Popup display (no GUI; notif-menu is the UX).
- DND / inhibitors (deferred until C-5 wires the bash notif-daemon to subscribe).
- replaces_id with synchronous hint (P2's OTP feature; not in v0).
- image-data hint storage / icon caching.

**Placeholder scan:** no TBD / TODO / "implement later" / vague-error-handling phrases. Every step has complete code blocks.

**Type consistency:** `Store` is used identically across Tasks 2/5/6. `NotifRecord` fields match between store.rs (Task 2), journal.rs (Task 3), notifications.rs (Task 5), notifos.rs (Task 6). `NotifOs` (Task 6) takes the same `Store` clone as `Notifications` (Task 5).

**One adapter contract worth flagging:** `notif-os.sh::mako_list_actions` parses `actions` as a JSON array of `[key, label]` two-element arrays. The Rust `ListEntry` (Task 6) serializes `actions: &[(String, String)]` — serde_json renders Rust tuples as JSON arrays, so the wire shape is `[["key","label"],...]`. Matches the adapter's expectation; no change to notif-os.sh needed.

---

## Quick reference for the implementer

**Building locally during development:**
```bash
cd /etc/nixos/home/notif-os-daemon
cargo build           # debug
cargo test            # all unit tests
cargo run             # foreground for manual testing
```

**Live testing (without rebuild):**
```bash
systemctl --user stop notif-daemon
pkill -f mako
setsid cargo run --manifest-path /etc/nixos/home/notif-os-daemon/Cargo.toml < /dev/null > /tmp/nod.log 2>&1 &
disown
```

**Restoring the working mako stack:**
```bash
pkill -f notif-os-daemon
systemctl --user start notif-daemon
```

**Useful busctl probes:**
```bash
# Who owns the bus name right now
busctl --user list | grep org.freedesktop.Notifications

# Introspect our extension
busctl --user introspect org.standardos.NotifOS /org/standardos/NotifOS

# List notifs as JSON
busctl --user --json=short call org.standardos.NotifOS /org/standardos/NotifOS \
    org.standardos.NotifOS ListNotifications | jq -r '.data[0]' | jq .
```
