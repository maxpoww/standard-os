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
            desktop_entry: String::new(),
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
