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
use zbus::interface;

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
    desktop_entry: &'a str,
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
                desktop_entry: &r.desktop_entry,
            })
            .collect();
        serde_json::to_string(&entries).unwrap_or_else(|_| "[]".to_string())
    }

    /// Fire ActionInvoked(id, action_key) on the freedesktop interface, then
    /// emit NotificationClosed(id, 2). Returns false if the id isn't present.
    /// Removes from the store FIRST so a concurrent CloseNotification can't
    /// race us into emitting NotificationClosed twice for the same id.
    async fn invoke_action(
        &self,
        #[zbus(object_server)] server: &zbus::ObjectServer,
        id: u32,
        action_key: String,
    ) -> zbus::fdo::Result<bool> {
        if !self.store.remove(id) {
            return Ok(false);
        }
        // Get the freedesktop interface so we can fire its signals.
        let iface_ref = server
            .interface::<_, Notifications>("/org/freedesktop/Notifications")
            .await?;
        let emitter = iface_ref.signal_emitter();
        // ActionInvoked first (so a listener sees the action before close).
        Notifications::action_invoked(emitter, id, action_key).await?;
        // Reason 2 = dismissed by user.
        Notifications::notification_closed(emitter, id, 2).await?;
        Ok(true)
    }

    fn count(&self) -> u32 {
        self.store.count()
    }
}

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
