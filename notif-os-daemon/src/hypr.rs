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
