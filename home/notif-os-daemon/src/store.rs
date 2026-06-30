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
    /// `desktop-entry` freedesktop hint. "" when the source app didn't
    /// set it. For Chrome PWAs this is the PWA's .desktop basename
    /// (e.g. `chrome-cinhimbnkkaeohfgghhklpknlkffjgod-Default`) which
    /// is also the Hyprland window class — letting View focus the
    /// specific PWA rather than regular Chromium.
    pub desktop_entry: String,
}

#[derive(Clone)]
pub struct Store {
    inner: Arc<Mutex<StoreInner>>,
}

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
        u32::try_from(self.inner.lock().unwrap().notifs.len()).unwrap_or(u32::MAX)
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
            desktop_entry: String::new(),
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
