//! `org.freedesktop.Notifications` — the freedesktop notification spec.
//!
//! Methods: Notify, CloseNotification, GetCapabilities, GetServerInformation.
//! Signals: NotificationClosed (id, reason), ActionInvoked (id, action_key).

use crate::hypr;
use crate::journal;
use crate::store::{NotifRecord, Store};
use chrono::Local;
use std::collections::HashMap;
use zbus::{interface, object_server::SignalEmitter, zvariant::Value};

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
        let ts = Local::now().format("%Y-%m-%dT%H:%M:%S%:z").to_string();

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
        if let Err(e) = journal::append(&path, &rec_with_id) {
            eprintln!("notif-os-daemon: journal append failed: {e}");
        }
        if let Err(e) = journal::prune(&path, journal::default_limit()) {
            eprintln!("notif-os-daemon: journal prune failed: {e}");
        }

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
