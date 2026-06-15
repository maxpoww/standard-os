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
