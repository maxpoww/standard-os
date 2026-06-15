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
