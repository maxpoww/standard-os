# Notification P2 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Compose action buttons, app icons, and 2FA / OTP extraction onto the live P1 notification architecture, without changing P1's invariants.

**Architecture:** Three new daemon-driven `custom/notif-action-{1,2,3}` child pills join the existing `group/notif` (parent `custom/notif-bell`, child `custom/notif-dnd`) and are populated from mako's `actions` array on every arrival. The wide-pill text gains Pango bold for the app name (`<b>App</b> · Title`). Body + summary text are scanned for a 4-8 digit OTP code anchored to one of ~15 keywords; on match the daemon embeds the code in the bell cache as a non-standard `otp_code` field and adds `opt-glow-green` to the class array. Clicking the wide pill in OTP state copies the code via `wl-copy`, signals the daemon via SIGUSR2 (with the id written to `/tmp/notif-otp-clicked` as a rendezvous), transitions the daemon to a 500ms `otp_copied` kind that renders ` · copied` suffix, then dismisses. Rofi rows get icons via the native `\0icon\x1f<app_name>` row metadata + `-show-icons` flag — no new lookup code.

**Tech Stack:** bash 5 (Pango-escape, GNU `grep -P`), mako 1.10 (busctl JSON for actions array, makoctl invoke -n <id> <key>), waybar 0.14 (Pango markup in custom-module text), rofi 1.7 (`-show-icons` + row metadata), `wl-clipboard` (`wl-copy`), NixOS Home-Manager modules.

**Spec:** `docs/superpowers/specs/2026-06-10-notification-p2-design.md`

---

## File structure

| Path | Role | New? |
|---|---|---|
| `home/scripts/notif-daemon` | Existing daemon, extended with `pango_escape`, `detect_otp`, `render_action_for_state`, extended `render_bell_for_state`, extended `query_mako_state` (actions), `emit_action_caches`, SIGUSR2 trap + handler, `check_transient_timer` extension for `otp_copied` | MODIFY |
| `home/scripts/notif-click` | Existing click handler, extended: bell OTP flow, new `action <N>` subcommand | MODIFY |
| `home/scripts/notif-rofi` | Existing rofi launcher, add `-show-icons` to rofi invocation | MODIFY |
| `home/scripts/lib/notif-rofi-format.sh` | Existing formatter lib, `format_rofi_entry` extended with icon hint | MODIFY |
| `home/modules/notif-center.nix` | Existing Nix module, `wl-clipboard` added to `runtimeDeps` | MODIFY |
| `home/tests/notif-state-test.sh` | Existing tests, extended for pango_escape, OTP detect, OTP class composition, render_action_for_state | MODIFY |
| `home/tests/notif-click-test.sh` | Existing tests, extended for bell with otp_code, action subcommand decide | MODIFY |
| `home/tests/notif-rofi-test.sh` | Existing tests, extended for icon hint embedded in formatted entry | MODIFY |
| `waybar/config.jsonc` | 3 new `custom/notif-action-{1,2,3}` modules, `group/notif` modules list extended | MODIFY |
| `waybar/ARCHITECTURE.md` | Cache list updated: 5 caches (notif-bell, notif-dnd, notif-action-{1,2,3}) | MODIFY |
| `waybar/TODO.md` | DONE entry | MODIFY |

**Live-system safety:** tasks 1–6 are pure-function extensions to existing files (additions only; existing behavior unchanged). Tasks 7–9 wire the daemon runtime + click runtime + rofi runtime. Tasks 10–11 update Nix/waybar config. Task 12 docs. Task 13 rebuild + acceptance.

---

## Task 1: pango_escape helper + tests

**Files:**
- Modify: `home/scripts/notif-daemon` (add helper after json_escape)
- Modify: `home/tests/notif-state-test.sh` (add cases before the closing tally)

- [ ] **Step 1: Add failing tests**

Open `/etc/nixos/home/tests/notif-state-test.sh`. Insert before the closing tally:

```bash
# ─── pango_escape ─────────────────────────────────────────────────────────
assert_eq "[pango_escape passthrough plain]" \
  "$(pango_escape "Hello world")" "Hello world"
assert_eq "[pango_escape <]" \
  "$(pango_escape "<script>")" "&lt;script&gt;"
assert_eq "[pango_escape >]" \
  "$(pango_escape "a>b")" "a&gt;b"
assert_eq "[pango_escape &]" \
  "$(pango_escape "Tom & Jerry")" "Tom &amp; Jerry"
assert_eq "[pango_escape combined]" \
  "$(pango_escape "<a href=\"x\">&go</a>")" "&lt;a href=\"x\"&gt;&amp;go&lt;/a&gt;"
assert_eq "[pango_escape order: & before < (avoid double-escape)]" \
  "$(pango_escape "<&>")" "&lt;&amp;&gt;"
```

- [ ] **Step 2: Run, confirm fails**

```bash
cd /etc/nixos/home && bash tests/notif-state-test.sh
```

Expected: existing tests pass; new pango_escape tests fail with "command not found".

- [ ] **Step 3: Implement pango_escape**

In `/etc/nixos/home/scripts/notif-daemon`, find `json_escape()` (around line 32). Immediately AFTER its closing brace, insert:

```bash
# ─── pango_escape — escape strings for Pango markup ────────────────────────
# Used when a string will be wrapped in <b>...</b> or similar Pango tags in
# waybar's custom-module text. Order matters: & MUST be escaped BEFORE < and
# >, or the inserted &amp; gets re-escaped to &amp;amp; etc.
pango_escape() {
    local s="$1"
    s="${s//&/&amp;}"
    s="${s//</&lt;}"
    s="${s//>/&gt;}"
    printf '%s' "$s"
}
```

- [ ] **Step 4: Run, confirm pass**

```bash
cd /etc/nixos/home && bash tests/notif-state-test.sh
```

Expected: all tests pass.

- [ ] **Step 5: Commit**

```bash
cd /etc/nixos/home
git add scripts/notif-daemon tests/notif-state-test.sh
git commit -m "$(cat <<'EOF'
notif: add pango_escape helper + tests

P2 wraps the wide-pill app name in <b>...</b> for Pango bold. Raw app
names containing <, >, or & would otherwise inject markup. pango_escape
mirrors json_escape's project pattern: pure bash, single-arg, no globals.
Order rule: ampersand BEFORE angle brackets to avoid double-escape.
EOF
)"
```

---

## Task 2: detect_otp helper + tests

**Files:**
- Modify: `home/scripts/notif-daemon` (add helper near pango_escape)
- Modify: `home/tests/notif-state-test.sh`

- [ ] **Step 1: Add failing tests**

Append to `tests/notif-state-test.sh` before the closing tally:

```bash
# ─── detect_otp ───────────────────────────────────────────────────────────
# Args: summary body — returns the first matching 4-8 digit code, or empty.
# Anchored on keyword + 40-char window.

# Positive cases — keyword + code present
assert_eq "[OTP: 'code 1234']" \
  "$(detect_otp "Verification" "Your code is 1234")" "1234"
assert_eq "[OTP: 6-digit common]" \
  "$(detect_otp "Login" "Your verification code: 348291")" "348291"
assert_eq "[OTP: PIN keyword]" \
  "$(detect_otp "PIN" "Use PIN 5678 to confirm")" "5678"
assert_eq "[OTP: OTP keyword caps]" \
  "$(detect_otp "" "Your OTP is 90210")" "90210"
assert_eq "[OTP: token keyword]" \
  "$(detect_otp "" "Auth token: 1357924")" "1357924"
assert_eq "[OTP: MFA keyword]" \
  "$(detect_otp "MFA code" "12345678 expires soon")" "12345678"
assert_eq "[OTP: 2FA keyword]" \
  "$(detect_otp "" "Your 2FA: 4567")" "4567"
assert_eq "[OTP: code in summary]" \
  "$(detect_otp "Use code 2222 today" "")" "2222"

# Negative cases — no keyword OR no digits
assert_eq "[OTP: no keyword → empty]" \
  "$(detect_otp "Price drop" "Now \$1234 cheaper")" ""
assert_eq "[OTP: no digits → empty]" \
  "$(detect_otp "Verification" "Sent to your phone")" ""
assert_eq "[OTP: keyword but digits too far away (>40 chars) → empty]" \
  "$(detect_otp "Order" "code processed; ............................................. 1234")" ""

# First match wins
assert_eq "[OTP: first match wins]" \
  "$(detect_otp "" "Your code 1111, backup code 2222")" "1111"

# 4-digit minimum
assert_eq "[OTP: 3-digit ignored]" \
  "$(detect_otp "" "code 123")" ""
# 8-digit maximum (9 digits ignored)
assert_eq "[OTP: 9-digit ignored]" \
  "$(detect_otp "" "code 123456789")" ""
```

- [ ] **Step 2: Run, confirm fails**

```bash
cd /etc/nixos/home && bash tests/notif-state-test.sh
```

Expected: detect_otp tests fail.

- [ ] **Step 3: Implement detect_otp**

In `/etc/nixos/home/scripts/notif-daemon`, immediately after `pango_escape()`, insert:

```bash
# ─── detect_otp — extract a 4-8 digit code from notification text ──────────
# Args: summary body
# Returns: first matching code, or empty string.
#
# Rule: a 4-8 digit standalone code preceded within 40 characters by one of
# ~15 OTP keywords. Anchored to avoid false positives (prices, phone numbers,
# timestamps, package tracking). Case-insensitive keyword match via PCRE.
#
# Requires GNU grep with -P. If -P is not available, returns empty (silently
# disables OTP detection rather than producing false output).
detect_otp() {
    local summary="$1" body="$2"
    local combined="$summary $body"
    # Sanity-check PCRE availability — `grep -P ''` on GNU grep succeeds with
    # no input and exit 1 (no match). On busybox grep it fails with exit 2.
    grep -P '' /dev/null 2>/dev/null
    (( $? > 1 )) && return 0
    local keywords='code|codigo|código|codice|OTP|PIN|verification|auth|login|log-in|token|cód|MFA|2FA|one-time|one time'
    local match
    match=$(printf '%s' "$combined" \
        | grep -oP "(?i)(${keywords})[^[:digit:]]{0,40}\b\K\d{4,8}\b" 2>/dev/null \
        | head -1)
    printf '%s' "$match"
}
```

- [ ] **Step 4: Run, confirm pass**

```bash
cd /etc/nixos/home && bash tests/notif-state-test.sh
```

Expected: all tests pass (including the 14 new OTP tests).

- [ ] **Step 5: Commit**

```bash
cd /etc/nixos/home
git add scripts/notif-daemon tests/notif-state-test.sh
git commit -m "$(cat <<'EOF'
notif: add detect_otp helper + tests

Keyword-anchored regex over summary + body for 4-8 digit codes. Keywords
cover code/codigo/codice/OTP/PIN/verification/auth/login/token/MFA/2FA
plus Spanish/Italian variants and "one-time". A 40-char window between
keyword and digit run cuts false positives on prices and phone numbers.
First match wins (most 2FA messages have exactly one code).

Pure function — daemon runtime wires it into on_arrival in task 7.
EOF
)"
```

---

## Task 3: render_bell_for_state extended (pango bold, OTP_CODE, OTP_COPIED)

**Files:**
- Modify: `home/scripts/notif-daemon` (extend renderer)
- Modify: `home/tests/notif-state-test.sh`

The renderer signature gains two args: `OTP_CODE` (string) and `OTP_COPIED` (0/1).

- [ ] **Step 1: Add failing tests**

Append to `tests/notif-state-test.sh` before the closing tally:

```bash
# ─── render_bell_for_state — P2 extensions ────────────────────────────────
# New args: OTP_CODE (string), OTP_COPIED (0/1)

# Transient — pango-bold app name
out=$(render_bell_for_state 1 0 0 "normal" "Slack" "PR review" "body" "" 0)
assert_eq "[bell transient: app wrapped in <b>]" \
  "$(echo "$out" | jq -r '.text')" "<b>Slack</b> · PR review"

# Pango-escape: <, >, & in app name
out=$(render_bell_for_state 1 0 0 "normal" "<script>" "title" "" "" 0)
assert_eq "[bell transient: pango-escape app <script>]" \
  "$(echo "$out" | jq -r '.text')" "<b>&lt;script&gt;</b> · title"

out=$(render_bell_for_state 1 0 0 "normal" "Tom & Jerry" "ep1" "" "" 0)
assert_eq "[bell transient: pango-escape app &]" \
  "$(echo "$out" | jq -r '.text')" "<b>Tom &amp; Jerry</b> · ep1"

# Title also escaped
out=$(render_bell_for_state 1 0 0 "normal" "App" "<b>injected</b>" "" "" 0)
assert_eq "[bell transient: pango-escape title <b>]" \
  "$(echo "$out" | jq -r '.text')" "<b>App</b> · &lt;b&gt;injected&lt;/b&gt;"

# OTP_CODE non-empty → opt-glow-green added
out=$(render_bell_for_state 1 0 0 "normal" "Bank" "Code 1234" "" "1234" 0)
assert_eq "[bell transient OTP: opt-glow-green present]" \
  "$(echo "$out" | jq -r '.class | index("opt-glow-green") != null')" "true"
assert_eq "[bell transient OTP: otp_code field present]" \
  "$(echo "$out" | jq -r '.otp_code')" "1234"

# OTP_CODE empty → no opt-glow-green, otp_code field empty string
out=$(render_bell_for_state 1 0 0 "normal" "App" "title" "" "" 0)
assert_eq "[bell transient no-OTP: no opt-glow-green]" \
  "$(echo "$out" | jq -r '.class | index("opt-glow-green") == null')" "true"
assert_eq "[bell transient no-OTP: otp_code is empty string]" \
  "$(echo "$out" | jq -r '.otp_code')" ""

# OTP_COPIED=1 → text gains " · copied" suffix
out=$(render_bell_for_state 1 0 0 "normal" "Bank" "Code 1234" "" "1234" 1)
assert_eq "[bell transient OTP copied: text has copied suffix]" \
  "$(echo "$out" | jq -r '.text')" "<b>Bank</b> · Code 1234 · copied"

# Critical + OTP composes: opt-pulse-orange AND opt-glow-green
out=$(render_bell_for_state 1 1 0 "critical" "Bank" "Critical" "danger" "9999" 0)
assert_eq "[bell critical+OTP: both opt-pulse-orange and opt-glow-green]" \
  "$(echo "$out" | jq -r '[.class[] | select(. == "opt-pulse-orange" or . == "opt-glow-green")] | length')" "2"

# Rest face emits otp_code as empty string (schema stability)
out=$(render_bell_for_state 0 0 0 "" "" "" "" "" 0)
assert_eq "[bell rest: otp_code field empty string]" \
  "$(echo "$out" | jq -r '.otp_code')" ""
```

- [ ] **Step 2: Run tests, confirm new ones fail**

```bash
cd /etc/nixos/home && bash tests/notif-state-test.sh
```

Expected: existing tests pass; new P2 cases fail because render_bell_for_state still has the P1 signature.

- [ ] **Step 3: Extend render_bell_for_state**

In `/etc/nixos/home/scripts/notif-daemon`, replace the entire `render_bell_for_state` function body with:

```bash
render_bell_for_state() {
    local unread="${1:-0}" critical="${2:-0}" dnd_on="${3:-0}"
    local kind="${4:-}" app="${5:-}" title="${6:-}" body="${7:-}"
    local otp_code="${8:-}" otp_copied="${9:-0}"

    local bell=$'\xef\x83\xb3'
    local -a classes=("opt-pill" "dark")

    # Self-contained escaping: pango_escape BEFORE the <b>...</b> wrap so
    # raw user-supplied text can't inject markup; then json_escape the
    # composed text so the JSON itself stays valid.
    local app_pango title_pango body_esc otp_code_esc
    app_pango=$(pango_escape "$app")
    title_pango=$(pango_escape "$title")
    body_esc=$(json_escape "$body")
    otp_code_esc=$(json_escape "$otp_code")

    if [[ -n $kind ]]; then
        case "$kind" in
            critical)
                classes+=("opt-no" "opt-pulse-orange")
                ;;
            normal)
                # No additional classes — silent normal arrival (Rule 4).
                ;;
            *)
                # Defensive: unknown kind treated as silent normal.
                ;;
        esac
        [[ -n $otp_code ]] && classes+=("opt-glow-green")
        (( dnd_on == 1 )) && classes+=("opt-pushed")

        local classes_json
        _classes_json classes_json "${classes[@]}"

        local app_esc title_esc text_body
        app_esc=$(json_escape "$app_pango")
        title_esc=$(json_escape "$title_pango")
        text_body="<b>${app_esc}</b> · ${title_esc}"
        if (( otp_copied == 1 )); then
            text_body+=" · copied"
        fi
        printf '{"text":"%s","class":%s,"tooltip":"%s","otp_code":"%s"}' \
            "$text_body" "$classes_json" "$body_esc" "$otp_code_esc"
        return 0
    fi

    # Rest face: bell glyph, pin color reflects urgency, no Pango.
    if (( unread > 0 )); then
        if (( critical > 0 )); then
            classes+=("opt-pin-orange")
        else
            classes+=("opt-pin-green")
        fi
    fi
    (( dnd_on == 1 )) && classes+=("opt-pushed")

    local classes_json
    _classes_json classes_json "${classes[@]}"
    printf '{"text":"%s","class":%s,"tooltip":"Notifications","otp_code":""}' \
        "$bell" "$classes_json"
}
```

- [ ] **Step 4: Update existing P1 tests that use the 7-arg signature**

The previous P1 tests call `render_bell_for_state 1 0 0 "normal" "Slack" "PR review" "body"`. They still need to pass. Bash positional args missing default to empty, so `OTP_CODE` defaults to "" and `OTP_COPIED` defaults to 0. Old tests continue to work because the new fields default to no-OTP behavior.

BUT — the existing tests assert that `.text` is `"Slack · PR review"`. With the new bold wrap that's now `"<b>Slack</b> · PR review"`. Find and update the affected P1 test assertions:

```bash
# Search for the old expected text
grep -n '"Slack · PR review"\|" · "' tests/notif-state-test.sh
```

Update assertions that check the literal text (not just `.contains(" · ")`). For example:

```bash
# old:
# assert_eq "[bell transient normal: text]" "$(echo "$out" | jq -r '.text')" "Slack · PR review"
# new:
assert_eq "[bell transient normal: text bold app]" "$(echo "$out" | jq -r '.text')" "<b>Slack</b> · PR review"
```

The `.text | contains(" · ")` assertions still pass — the literal " · " separator is unchanged.

- [ ] **Step 5: Run tests, confirm pass**

```bash
cd /etc/nixos/home && bash tests/notif-state-test.sh
```

Expected: all tests pass.

- [ ] **Step 6: Commit**

```bash
cd /etc/nixos/home
git add scripts/notif-daemon tests/notif-state-test.sh
git commit -m "$(cat <<'EOF'
notif: render_bell_for_state Pango-bold app + OTP fields

Extends the renderer with two new args: OTP_CODE (string, empty when
no code detected) and OTP_COPIED (0/1, for the post-click "copied"
suffix).

Behavior changes:
- Transient face wraps app name in <b>...</b> with pango_escape applied
  to app/title FIRST (so raw user content can't inject markup).
- OTP_CODE non-empty composes opt-glow-green into the class array AND
  embeds the code in a non-standard `otp_code` JSON field that waybar
  ignores but notif-click reads.
- OTP_COPIED=1 appends " · copied" to the text (used during the 500ms
  post-click hold).
- All bell outputs (rest + transient) now emit `otp_code` as an empty
  string when no code is present, keeping the JSON schema stable.

Composes orthogonally with opt-pulse-orange (critical) and opt-pushed
(DND on) — bank/financial critical-urgency notifications can carry
both an OTP and a pulse animation at once.
EOF
)"
```

---

## Task 4: render_action_for_state pure renderer + tests

**Files:**
- Modify: `home/scripts/notif-daemon`
- Modify: `home/tests/notif-state-test.sh`

- [ ] **Step 1: Add failing tests**

Append to `tests/notif-state-test.sh`:

```bash
# ─── render_action_for_state ──────────────────────────────────────────────
# Args: key label

# Basic shape
out=$(render_action_for_state "reply" "Reply")
assert_eq "[action: text is the label]" "$(echo "$out" | jq -r '.text')" "Reply"
assert_eq "[action: class is opt-pill-child + dark + opt-yes]" \
  "$(echo "$out" | jq -r '.class | length')" "3"
assert_eq "[action: opt-pill-child present]" \
  "$(echo "$out" | jq -r '.class | index("opt-pill-child") != null')" "true"
assert_eq "[action: opt-yes present]" \
  "$(echo "$out" | jq -r '.class | index("opt-yes") != null')" "true"
assert_eq "[action: key field is the action key]" \
  "$(echo "$out" | jq -r '.key')" "reply"
assert_eq "[action: tooltip is the label]" \
  "$(echo "$out" | jq -r '.tooltip')" "Reply"

# JSON-injection: quotes in label and key
out=$(render_action_for_state 'key"with' 'Label "with"')
assert_eq "[action: JSON-escapes quote in label]" \
  "$(echo "$out" | jq -r '.text')" 'Label "with"'
assert_eq "[action: JSON-escapes quote in key]" \
  "$(echo "$out" | jq -r '.key')" 'key"with'
```

- [ ] **Step 2: Run, confirm fails**

```bash
cd /etc/nixos/home && bash tests/notif-state-test.sh
```

Expected: render_action_for_state tests fail (function not defined).

- [ ] **Step 3: Implement render_action_for_state**

In `/etc/nixos/home/scripts/notif-daemon`, immediately after the closing brace of `render_dnd_for_state`, insert:

```bash
# ─── render_action_for_state (P2) ──────────────────────────────────────────
# One action child pill. Pure function.
#
# Args:
#   $1 key   — mako action key (passed to `makoctl invoke -n <id> <key>`)
#   $2 label — display text (mako's action label)
#
# The `key` field is a project-internal extension; waybar ignores it but
# notif-click reads it to know which action to invoke.
render_action_for_state() {
    local key="$1" label="$2"
    local label_esc key_esc
    label_esc=$(json_escape "$label")
    key_esc=$(json_escape "$key")
    printf '{"text":"%s","class":["opt-pill-child","dark","opt-yes"],"tooltip":"%s","key":"%s"}' \
        "$label_esc" "$label_esc" "$key_esc"
}
```

- [ ] **Step 4: Run, confirm pass**

```bash
cd /etc/nixos/home && bash tests/notif-state-test.sh
```

Expected: all tests pass.

- [ ] **Step 5: Commit**

```bash
cd /etc/nixos/home
git add scripts/notif-daemon tests/notif-state-test.sh
git commit -m "$(cat <<'EOF'
notif: add render_action_for_state pure renderer + tests

One action child pill: opt-pill-child surface + opt-yes accent (action =
forward intent), label as text and tooltip, action key embedded in a
non-standard `key` JSON field. The field name is the project-internal
contract between notif-daemon (writer) and notif-click (reader); waybar
ignores it.

Renderer is dormant until task 7 wires emit_action_caches() into the
daemon runtime.
EOF
)"
```

---

## Task 5: format_rofi_entry icon hint + tests

**Files:**
- Modify: `home/scripts/lib/notif-rofi-format.sh`
- Modify: `home/tests/notif-rofi-test.sh`

- [ ] **Step 1: Add failing tests**

Append to `tests/notif-rofi-test.sh` before the closing tally:

```bash
# ─── format_rofi_entry icon hint (P2) ─────────────────────────────────────
# The icon hint is appended as rofi's row-metadata format:
#   <display>\0icon\x1f<icon-name>
# where \0 is NUL and \x1f is the ASCII unit separator. We use the
# notification's app_name as the icon-theme lookup key.

out=$(format_rofi_entry "2026-06-10T10:42:00-03:00" "Slack" "Hello" 1 1 0)

# Display portion still present
check "[icon row: display has hh:mm + App · Summary]" \
  test -n "$(printf '%s' "$out" | grep -F '10:42  Slack · Hello')"

# Icon hint appended after NUL + "icon" + US (0x1F)
expected_suffix=$(printf '\0icon\x1fSlack')
check "[icon row: ends with \\0icon\\x1f<app_name>]" \
  test -n "$(printf '%s' "$out" | tr -d '\n' | grep -F "$expected_suffix")"

# Historical entry (UNREAD=0): icon still appended
out=$(format_rofi_entry "2026-06-09T09:00:00-03:00" "firefox" "Page loaded" 1 0 0)
expected_suffix=$(printf '\0icon\x1ffirefox')
check "[historical icon row: ends with \\0icon\\x1f<app_name>]" \
  test -n "$(printf '%s' "$out" | tr -d '\n' | grep -F "$expected_suffix")"

# Empty app — no icon hint suffix would be `\0icon\x1f` (empty icon).
# Acceptable: rofi treats empty icon as no icon.
out=$(format_rofi_entry "2026-06-10T11:00:00-03:00" "" "" 1 0 0)
expected_suffix=$(printf '\0icon\x1f')
check "[empty app: icon hint still emitted (empty value)]" \
  test -n "$(printf '%s' "$out" | tr -d '\n' | grep -F "$expected_suffix")"
```

- [ ] **Step 2: Run, confirm fails**

```bash
cd /etc/nixos/home && bash tests/notif-rofi-test.sh
```

Expected: new icon tests fail.

- [ ] **Step 3: Update format_rofi_entry**

In `/etc/nixos/home/scripts/lib/notif-rofi-format.sh`, replace the entire `format_rofi_entry` function body with:

```bash
format_rofi_entry() {
    local ts="$1" app="$2" summary="$3" urgency="$4" unread="$5" critical="$6"
    local hhmm="${ts:11:5}"
    local tags=""
    if (( unread )); then
        tags+=" · unread"
        (( critical )) && tags+=" · critical"
    fi
    # Rofi row metadata: literal NUL + "icon" + literal US (0x1F) + value.
    # The app_name doubles as the icon-theme lookup key. Rofi resolves it
    # against the freedesktop icon theme via `-show-icons`; unknown names
    # render as text-only rows (no icon column).
    printf '%s  %s · %s%s\0icon\x1f%s' \
        "$hhmm" "$app" "$summary" "$tags" "$app"
}
```

- [ ] **Step 4: Run tests**

```bash
cd /etc/nixos/home && bash tests/notif-rofi-test.sh
```

Expected: all tests pass.

- [ ] **Step 5: Commit**

```bash
cd /etc/nixos/home
git add scripts/lib/notif-rofi-format.sh tests/notif-rofi-test.sh
git commit -m "$(cat <<'EOF'
notif-rofi-format: append icon hint per row

format_rofi_entry now emits rofi's row metadata format:
  HH:MM  App · Summary[ · tags]\0icon\x1f<app_name>

\0 is NUL, \x1f is the unit separator (US). Rofi resolves <app_name>
via the freedesktop icon theme when invoked with -show-icons. Apps
whose D-Bus app_name matches their theme entry get an icon; unknown
apps render as text-only rows (no icon column). No new lookup code.

Tests verify both the icon hint suffix and that the display portion
is unchanged from P1.
EOF
)"
```

---

## Task 6: notif_click_decide — OTP branch + action subcommand + tests

**Files:**
- Modify: `home/scripts/notif-click`
- Modify: `home/tests/notif-click-test.sh`

- [ ] **Step 1: Add failing tests**

Append to `tests/notif-click-test.sh` before the closing tally:

```bash
# ─── bell on transient with otp_code → 'invoke-otp' (P2) ──────────────────
out=$(notif_click_decide bell '{"text":"<b>Bank</b> · Code 1234","class":["opt-pill","dark","opt-glow-green"],"tooltip":"","otp_code":"1234"}')
assert_eq "[bell on transient + otp_code → invoke-otp]" "$out" "invoke-otp"

# Bell transient WITHOUT otp_code → still invoke-and-dismiss
out=$(notif_click_decide bell '{"text":"<b>App</b> · regular","class":["opt-pill","dark"],"tooltip":"","otp_code":""}')
assert_eq "[bell on transient + no otp_code → invoke-and-dismiss]" "$out" "invoke-and-dismiss"

# Bell transient with otp_code="" (empty string) → invoke-and-dismiss
out=$(notif_click_decide bell '{"text":"<b>App</b> · t","class":["opt-pill","dark"],"otp_code":""}')
assert_eq "[bell transient otp_code empty → invoke-and-dismiss]" "$out" "invoke-and-dismiss"

# ─── action subcommand ───────────────────────────────────────────────────
out=$(notif_click_decide action '{"text":"Reply","class":["opt-pill-child","dark","opt-yes"],"key":"reply"}')
assert_eq "[action on populated cache → invoke-action]" "$out" "invoke-action"

# Action on empty cache → noop
out=$(notif_click_decide action '{"text":""}')
assert_eq "[action on empty cache → noop]" "$out" "noop"

# Action with no key field → noop (defensive)
out=$(notif_click_decide action '{"text":"Reply","class":["opt-pill-child","dark","opt-yes"]}')
assert_eq "[action without key field → noop]" "$out" "noop"

# Action with empty string key → noop
out=$(notif_click_decide action '{"text":"Reply","key":""}')
assert_eq "[action with empty key → noop]" "$out" "noop"
```

- [ ] **Step 2: Run, confirm fails**

```bash
cd /etc/nixos/home && bash tests/notif-click-test.sh
```

Expected: new tests fail.

- [ ] **Step 3: Extend notif_click_decide**

In `/etc/nixos/home/scripts/notif-click`, find the `bell)` case branch and the `action)` case (if absent — we add it). Replace the whole `case "$action" in` block with:

```bash
    case "$action" in
        bell)
            if [[ -z $cache_content || $cache_content == '{"text":""}' ]]; then
                printf 'noop'
                return 0
            fi
            if [[ $cache_content != '{"text":'* ]]; then
                printf 'noop'
                return 0
            fi
            # P2: if cache carries a non-empty otp_code, the click should run
            # the OTP-copy flow instead of the standard invoke+dismiss.
            local otp
            otp=$(printf '%s' "$cache_content" | jq -r '.otp_code // empty' 2>/dev/null)
            if [[ -n $otp ]]; then
                printf 'invoke-otp'
                return 0
            fi
            if [[ $cache_content == *' · '* ]]; then
                printf 'invoke-and-dismiss'
            else
                printf 'open-rofi'
            fi
            ;;
        dnd)
            printf 'toggle-dnd'
            ;;
        action)
            # Action click: cache must carry a non-empty `key` field.
            local key
            key=$(printf '%s' "$cache_content" | jq -r '.key // empty' 2>/dev/null)
            if [[ -n $key ]]; then
                printf 'invoke-action'
            else
                printf 'noop'
            fi
            ;;
        invoke|drawer)
            case "$action" in
                invoke)
                    if [[ -z $cache_content || $cache_content == '{"text":""}' ]]; then
                        printf 'noop'; return 0
                    fi
                    if [[ $cache_content != '{"text":'* ]]; then
                        printf 'noop'; return 0
                    fi
                    if [[ $cache_content == *' · '* ]]; then
                        printf 'invoke-latest'
                    else
                        printf 'dismiss-all'
                    fi
                    ;;
                drawer)
                    printf 'noop'
                    ;;
            esac
            ;;
        *)
            printf 'noop'
            ;;
    esac
```

- [ ] **Step 4: Update header doc comment**

The header above `notif_click_decide` already enumerates outputs. Update it to list the two new ones. Find lines that look like the header from task 3 of P1 and add:

```
#   bell  on transient + otp_code → "invoke-otp"   (P2; copy + 500ms + dismiss)
#   action on populated cache    → "invoke-action" (P2; makoctl invoke -n <id> <key>)
```

between the existing bell entries and the dnd entry.

- [ ] **Step 5: Run tests**

```bash
cd /etc/nixos/home && bash tests/notif-click-test.sh
```

Expected: all tests pass.

- [ ] **Step 6: Commit**

```bash
cd /etc/nixos/home
git add scripts/notif-click tests/notif-click-test.sh
git commit -m "$(cat <<'EOF'
notif-click: decide() adds OTP branch + action subcommand

bell on transient cache with non-empty otp_code → "invoke-otp" (the
runtime wires this in task 8 to wl-copy + SIGUSR2 to daemon).

action subcommand on a populated cache (non-empty `key` field) →
"invoke-action". Empty cache or missing key → "noop". Runtime wires
this in task 8 to makoctl invoke -n <id> <key> + dismiss.

Pure decision function still — no I/O. Runtime dispatcher still ignores
the new outputs until task 8.
EOF
)"
```

---

## Task 7: Daemon runtime — OTP detection, action caches, SIGUSR2

**Files:**
- Modify: `home/scripts/notif-daemon`

This is the biggest runtime change in P2. The pure renderers from tasks 1-4 are wired in; new state vars track actions + OTP; SIGUSR2 plumbing handles the post-click 500ms hold.

- [ ] **Step 1: Add new state variables**

Find the existing state-variable block in `/etc/nixos/home/scripts/notif-daemon` (look for `UNREAD_COUNT=0` near the top of the runtime section). After `LAST_DND_RENDERED=""`, add:

```bash
# P2 state
TRANSIENT_OTP_CODE=""              # extracted OTP code (empty when no match)
TRANSIENT_OTP_COPIED=0             # 1 during the 500ms post-click hold
declare -a TRANSIENT_ACTIONS=()    # array of "key:label" pairs (max 3 used)
LAST_ACTION_1_RENDERED=""
LAST_ACTION_2_RENDERED=""
LAST_ACTION_3_RENDERED=""
USR2_PENDING=0
```

- [ ] **Step 2: Add SIGUSR2 trap definition**

Find the existing `trap on_user_signal USR1` line. Immediately after it, add:

```bash
on_user_signal_2() {
    USR2_PENDING=1
}
trap on_user_signal_2 USR2
```

- [ ] **Step 3: Extend query_mako_state to capture the actions array**

Find `query_mako_state()`. After the `NEWEST_BODY=$(...)` line at the end of the function, add:

```bash
    # P2: capture the actions array for the NEWEST_ID notification. mako
    # emits actions as alternating [key, label, key, label, ...] strings.
    NEWEST_ACTIONS_JSON=$(printf '%s' "$json" | jq -c \
        "[.data[0][]? | select(.id.data == $NEWEST_ID)][0].actions.data // []" \
        2>/dev/null) || NEWEST_ACTIONS_JSON='[]'
```

- [ ] **Step 4: Extend on_arrival to extract OTP code + actions**

Find `on_arrival()`. After `TRANSIENT_START=$(date +%s%3N)`, add:

```bash
    # P2: scan summary + body for an OTP code
    TRANSIENT_OTP_CODE=$(detect_otp "$NEWEST_SUMMARY" "$NEWEST_BODY")
    TRANSIENT_OTP_COPIED=0

    # P2: parse the actions JSON array into "key:label" pairs (up to 3)
    TRANSIENT_ACTIONS=()
    if [[ $NEWEST_ACTIONS_JSON != '[]' && -n $NEWEST_ACTIONS_JSON ]]; then
        local pair_count=0
        local arr_len
        arr_len=$(jq -r 'length' <<< "$NEWEST_ACTIONS_JSON" 2>/dev/null) || arr_len=0
        # mako pairs entries as [key0, label0, key1, label1, ...]
        local i=0
        while (( i + 1 < arr_len && pair_count < 3 )); do
            local key_i label_i
            key_i=$(jq -r ".[$i]" <<< "$NEWEST_ACTIONS_JSON" 2>/dev/null) || key_i=""
            label_i=$(jq -r ".[$((i+1))]" <<< "$NEWEST_ACTIONS_JSON" 2>/dev/null) || label_i=""
            TRANSIENT_ACTIONS+=("${key_i}:${label_i}")
            pair_count=$((pair_count + 1))
            i=$((i + 2))
        done
    fi
```

- [ ] **Step 5: Add clear_transient extension**

Find `clear_transient()`. Inside the function, after the existing assignments, add:

```bash
    TRANSIENT_OTP_CODE=""
    TRANSIENT_OTP_COPIED=0
    TRANSIENT_ACTIONS=()
```

- [ ] **Step 6: Add emit_action_caches helper + update emit**

Immediately before `emit()`, add:

```bash
# Write notif-action-{1,2,3} caches based on the current TRANSIENT_ACTIONS
# array. Slot N is the (N-1)th action; missing slots emit {"text":""} so the
# child pills collapse to .empty in waybar.
emit_action_caches() {
    local i changed_any=0
    for i in 1 2 3; do
        local cache="/tmp/waybar-cache/notif-action-$i"
        local last_var="LAST_ACTION_${i}_RENDERED"
        local idx=$((i - 1))
        local content
        if [[ -n $TRANSIENT_KIND && $idx -lt ${#TRANSIENT_ACTIONS[@]} ]]; then
            local pair="${TRANSIENT_ACTIONS[$idx]}"
            local key="${pair%%:*}"
            local label="${pair#*:}"
            content=$(render_action_for_state "$key" "$label")
        else
            content='{"text":""}'
        fi
        write_if_changed "$cache" "$content" "$last_var" && changed_any=1
    done
    return $changed_any
}
```

Then update `emit()` to call it. Replace the body of emit() with:

```bash
emit() {
    query_mako_state
    local bell_json dnd_json
    bell_json=$(render_bell_for_state \
        "$UNREAD_COUNT" "$CRITICAL_COUNT" "$DND_ON" \
        "$TRANSIENT_KIND" "$TRANSIENT_APP" "$TRANSIENT_TITLE" "$TRANSIENT_BODY" \
        "$TRANSIENT_OTP_CODE" "$TRANSIENT_OTP_COPIED")
    dnd_json=$(render_dnd_for_state "$DND_ON")

    local changed=0
    write_if_changed "$CACHE_BELL" "$bell_json" LAST_BELL_RENDERED && changed=1
    write_if_changed "$CACHE_DND" "$dnd_json" LAST_DND_RENDERED && changed=1
    emit_action_caches
    (( $? == 1 )) && changed=1
    if (( changed )); then
        pkill -RTMIN+"$SIGNAL" waybar 2>/dev/null || true
    fi
}
```

- [ ] **Step 7: Add SIGUSR2 drain to the main loop**

Find the main loop's "Drain any USR1" block at the top. Replace it with:

```bash
    # Drain any USR1 that may have been queued (notif-click toggle-dnd path).
    if (( USR1_PENDING )); then
        USR1_PENDING=0
        sleep 0.05
        query_dnd
        emit
    fi
    # Drain any USR2 (notif-click OTP-clicked path). The notif-click writer
    # stores the clicked notification's id at /tmp/notif-otp-clicked so we
    # can verify the signal targets the current transient (not a stale one).
    if (( USR2_PENDING )); then
        USR2_PENDING=0
        if [[ -f /tmp/notif-otp-clicked ]]; then
            local clicked_id
            clicked_id=$(cat /tmp/notif-otp-clicked 2>/dev/null)
            rm -f /tmp/notif-otp-clicked
            if [[ -n $clicked_id && -n $TRANSIENT_KIND && $clicked_id == "$TRANSIENT_ID" ]]; then
                TRANSIENT_OTP_COPIED=1
                # Reset the 5s timer to use as a 500ms "copied" hold.
                TRANSIENT_START=$(date +%s%3N)
                emit
            fi
        fi
    fi
```

- [ ] **Step 8: Extend check_transient_timer for otp_copied**

Find `check_transient_timer()`. Replace its body with:

```bash
check_transient_timer() {
    [[ -z $TRANSIENT_KIND ]] && return 1
    local now elapsed limit
    now=$(date +%s%3N)
    elapsed=$(( now - TRANSIENT_START ))
    if (( TRANSIENT_OTP_COPIED == 1 )); then
        limit=500   # 500ms post-click hold for the "copied" suffix
    else
        limit="$TRANSIENT_MS"
    fi
    if (( elapsed >= limit )); then
        # If we were in the OTP-copied hold, dismiss the notification AS the
        # transient collapses (mako's Dismissed signal then triggers a fresh
        # on_dbus_event → query_mako_state → emit; the bell returns to rest
        # carrying whatever pin color the remaining unread state implies).
        if (( TRANSIENT_OTP_COPIED == 1 )) && (( TRANSIENT_ID > 0 )); then
            makoctl dismiss -n "$TRANSIENT_ID" 2>/dev/null || true
        fi
        clear_transient
        return 0
    fi
    return 1
}
```

- [ ] **Step 9: Run unit tests (sanity — pure helpers still work)**

```bash
cd /etc/nixos/home && bash tests/notif-state-test.sh && bash tests/notif-click-test.sh
```

Expected: every test passes.

- [ ] **Step 10: bash -n the daemon**

```bash
bash -n /etc/nixos/home/scripts/notif-daemon
```

Expected: empty output.

- [ ] **Step 11: Commit**

```bash
cd /etc/nixos/home
git add scripts/notif-daemon
git commit -m "$(cat <<'EOF'
notif-daemon runtime: actions + OTP + SIGUSR2

Wires the P2 pure renderers into the live emit() path:

- query_mako_state captures the actions array (alternating key/label
  strings) into NEWEST_ACTIONS_JSON.
- on_arrival extracts an OTP code via detect_otp(summary, body) and
  parses up to 3 action pairs into TRANSIENT_ACTIONS.
- emit() calls render_bell_for_state with the new 9-arg signature and
  invokes emit_action_caches() for the three child slots.
- emit_action_caches() writes one cache per slot; unpopulated slots
  emit {"text":""} so the children .empty-collapse in waybar.

New SIGUSR2 trap drives the 500ms OTP-copied hold:

- notif-click writes the transient ID to /tmp/notif-otp-clicked and
  signals SIGUSR2.
- Daemon's main-loop drain verifies the clicked id matches the current
  TRANSIENT_ID (defending against stale clicks across rapid notifs),
  flips TRANSIENT_OTP_COPIED=1, resets TRANSIENT_START so the 500ms
  countdown begins, and re-emits.
- check_transient_timer uses 500ms as the limit when OTP_COPIED=1 and
  dismisses the notification when the hold expires (mako's Dismissed
  flow then clears the transient cleanly).

Until config.jsonc grows the three custom/notif-action modules (task 11),
waybar isn't reading these caches yet — they get written but ignored.
EOF
)"
```

---

## Task 8: notif-click runtime — OTP flow + action dispatcher

**Files:**
- Modify: `home/scripts/notif-click`

- [ ] **Step 1: Add OTP flow + action runtime**

In `/etc/nixos/home/scripts/notif-click`, find the runtime `case "$decision" in` block. Replace the whole block (down to the closing `esac`) with:

```bash
case "$decision" in
    invoke-and-dismiss)
        latest_id=$(busctl --user --json=short call \
            org.freedesktop.Notifications /fr/emersion/Mako \
            fr.emersion.Mako ListNotifications 2>/dev/null \
            | jq -r '[.data[0][]?.id.data] | max // empty' 2>/dev/null)
        if [[ -n $latest_id ]]; then
            makoctl invoke -n "$latest_id" 2>/dev/null || true
            makoctl dismiss -n "$latest_id" 2>/dev/null || true
        fi
        ;;
    invoke-otp)
        # P2: extract the OTP code from the bell cache, copy via wl-copy,
        # then signal the daemon to enter the 500ms "copied" hold.
        otp_code=$(jq -r '.otp_code // empty' "$CACHE" 2>/dev/null)
        if [[ -n $otp_code ]]; then
            printf '%s' "$otp_code" | wl-copy 2>/dev/null || true
            # Rendezvous file: the daemon's SIGUSR2 handler reads this ID and
            # only transitions if it matches the current TRANSIENT_ID (so a
            # stale click after rapid noti-replacement is ignored).
            latest_id=$(busctl --user --json=short call \
                org.freedesktop.Notifications /fr/emersion/Mako \
                fr.emersion.Mako ListNotifications 2>/dev/null \
                | jq -r '[.data[0][]?.id.data] | max // empty' 2>/dev/null)
            if [[ -n $latest_id ]]; then
                printf '%s' "$latest_id" > /tmp/notif-otp-clicked
                systemctl --user kill --kill-who=main -s SIGUSR2 notif-daemon.service 2>/dev/null || true
            fi
        fi
        ;;
    open-rofi)
        exec notif-rofi
        ;;
    toggle-dnd)
        makoctl mode -t dnd 2>/dev/null || true
        systemctl --user kill --kill-who=main -s SIGUSR1 notif-daemon.service 2>/dev/null || true
        ;;
    invoke-action)
        # P2: read the action key from the action-N cache; the script's
        # ACTION_N env var (set in the wrapper below) names which cache.
        key=$(jq -r '.key // empty' "$CACHE" 2>/dev/null)
        if [[ -n $key ]]; then
            latest_id=$(busctl --user --json=short call \
                org.freedesktop.Notifications /fr/emersion/Mako \
                fr.emersion.Mako ListNotifications 2>/dev/null \
                | jq -r '[.data[0][]?.id.data] | max // empty' 2>/dev/null)
            if [[ -n $latest_id ]]; then
                makoctl invoke -n "$latest_id" "$key" 2>/dev/null || true
                makoctl dismiss -n "$latest_id" 2>/dev/null || true
            fi
        fi
        ;;
    noop)
        : ;;
    # Legacy decisions
    invoke-latest)
        latest_id=$(busctl --user --json=short call \
            org.freedesktop.Notifications /fr/emersion/Mako \
            fr.emersion.Mako ListNotifications 2>/dev/null \
            | jq -r '[.data[0][]?.id.data] | max // empty' 2>/dev/null)
        if [[ -n $latest_id ]]; then
            makoctl invoke -n "$latest_id" 2>/dev/null || true
            makoctl dismiss -n "$latest_id" 2>/dev/null || true
        fi
        ;;
    dismiss-all)
        makoctl dismiss --all 2>/dev/null || true
        ;;
esac
```

- [ ] **Step 2: Add the `action <N>` subcommand wrapper**

The existing script reads `$1` as the action and uses a fixed `CACHE` global. For `notif-click action 1`, the cache should be `/tmp/waybar-cache/notif-action-1` (not the bell). Add this just above the existing `action="${1:-invoke}"` line:

```bash
# action <N> subcommand: redirect CACHE to /tmp/waybar-cache/notif-action-N
# and rewrite $1 so notif_click_decide sees the canonical "action" subcommand.
if [[ "${1:-}" == "action" && -n "${2:-}" ]]; then
    N="$2"
    case "$N" in
        1|2|3)
            CACHE="${NOTIF_ACTION_CACHE:-/tmp/waybar-cache/notif-action-$N}"
            set -- action
            ;;
        *)
            # Unknown N — fall through to the default 'invoke' which will
            # decide to noop on the bell-cache's content.
            ;;
    esac
fi
```

(Place this BEFORE the `action="${1:-invoke}"` so the `set -- action` rewrites the argv.)

- [ ] **Step 3: Re-run click tests (decide-only tests, still apply)**

```bash
cd /etc/nixos/home && bash tests/notif-click-test.sh
```

Expected: all tests pass.

- [ ] **Step 4: bash -n**

```bash
bash -n /etc/nixos/home/scripts/notif-click
```

Expected: empty output.

- [ ] **Step 5: Commit**

```bash
cd /etc/nixos/home
git add scripts/notif-click
git commit -m "$(cat <<'EOF'
notif-click runtime: invoke-otp + invoke-action paths

invoke-otp: read otp_code from bell cache, wl-copy it, write the latest
mako id to /tmp/notif-otp-clicked as a rendezvous, signal SIGUSR2 to
notif-daemon. Daemon enters the 500ms "copied" hold + dismisses on
expiry.

invoke-action: read key from the action-N cache, run makoctl invoke
-n <latest-id> <key> + dismiss. Subcommand wrapper at the top redirects
CACHE to /tmp/waybar-cache/notif-action-N when the user invokes
`notif-click action <N>` (1, 2, or 3), then rewrites argv so the pure
decide function sees the canonical "action" subcommand.

wl-copy availability is gated by task 10 (Nix module wl-clipboard dep).
EOF
)"
```

---

## Task 9: notif-rofi runtime — `-show-icons` flag

**Files:**
- Modify: `home/scripts/notif-rofi`

- [ ] **Step 1: Add the flag**

In `/etc/nixos/home/scripts/notif-rofi`, find the rofi invocation (the final block, the `pick=$(... rofi -dmenu ...)` line). Change the rofi flags from:

```bash
pick=$(printf '%s' "$rows" | rofi -dmenu -i -p "notifications" -no-custom -theme-str 'window { width: 50%; }' 2>/dev/null) || exit 0
```

to:

```bash
pick=$(printf '%s' "$rows" | rofi -dmenu -i -p "notifications" -no-custom -show-icons -theme-str 'window { width: 50%; }' 2>/dev/null) || exit 0
```

- [ ] **Step 2: bash -n**

```bash
bash -n /etc/nixos/home/scripts/notif-rofi
```

Expected: empty.

- [ ] **Step 3: Commit**

```bash
cd /etc/nixos/home
git add scripts/notif-rofi
git commit -m "$(cat <<'EOF'
notif-rofi: -show-icons so format_rofi_entry's icon hints render

Without -show-icons, rofi ignores the \0icon\x1f<app_name> row metadata.
With it, rofi looks up <app_name> in the freedesktop icon theme and
renders the icon to the left of each row. Apps without a matching theme
entry render text-only (icon column blank).
EOF
)"
```

---

## Task 10: Nix module — wl-clipboard

**Files:**
- Modify: `home/modules/notif-center.nix`

- [ ] **Step 1: Add wl-clipboard to runtimeDeps**

In `/etc/nixos/home/modules/notif-center.nix`, find the `runtimeDeps = with pkgs; [ ... ];` block. Add `wl-clipboard` (and `gnugrep` to guarantee PCRE-capable grep):

```nix
  runtimeDeps = with pkgs; [
    bash
    coreutils
    dbus
    gnugrep
    jq
    mako
    procps
    rofi
    wl-clipboard
  ];
```

- [ ] **Step 2: Verify it parses**

```bash
nix-instantiate --parse /etc/nixos/home/modules/notif-center.nix > /dev/null
```

Expected: no error.

- [ ] **Step 3: Commit**

```bash
cd /etc/nixos/home
git add modules/notif-center.nix
git commit -m "$(cat <<'EOF'
notif-center.nix: wl-clipboard + gnugrep in runtimeDeps

wl-clipboard ships wl-copy (used by notif-click's OTP flow).
gnugrep is added explicitly because OTP detection uses PCRE (grep -P)
which is GNU-specific. If a Nix store override silently swapped grep
for busybox, OTP detection would degrade silently — pinning gnugrep
makes the dependency loud.
EOF
)"
```

---

## Task 11: Waybar config — 3 action modules + group/notif

**Files:**
- Modify: `waybar/config.jsonc`

- [ ] **Step 1: Update group/notif modules list**

Find the existing `"group/notif"` block in `/etc/nixos/home/waybar/config.jsonc`. Change its `modules` array from:

```jsonc
    "modules": [
      "custom/notif-dnd",
      "custom/notif-bell"
    ]
```

to:

```jsonc
    "modules": [
      "custom/notif-action-3",
      "custom/notif-action-2",
      "custom/notif-action-1",
      "custom/notif-dnd",
      "custom/notif-bell"
    ]
```

(Note the order: rightmost-to-leftmost in the group children list corresponds to leftmost-to-rightmost VISUALLY when the drawer expands — because right-zone groups expand LEFT.)

- [ ] **Step 2: Add three custom/notif-action-N modules**

Immediately after the existing `"custom/notif-dnd"` module declaration, add:

```jsonc
  "custom/notif-action-1": {
    "exec": "cat /tmp/waybar-cache/notif-action-1 2>/dev/null || echo '{\"text\":\"\"}'",
    "return-type": "json",
    "format": "{}",
    "interval": "once",
    "signal": 12,
    "tooltip": true,
    "on-click": "notif-click action 1"
  },
  "custom/notif-action-2": {
    "exec": "cat /tmp/waybar-cache/notif-action-2 2>/dev/null || echo '{\"text\":\"\"}'",
    "return-type": "json",
    "format": "{}",
    "interval": "once",
    "signal": 12,
    "tooltip": true,
    "on-click": "notif-click action 2"
  },
  "custom/notif-action-3": {
    "exec": "cat /tmp/waybar-cache/notif-action-3 2>/dev/null || echo '{\"text\":\"\"}'",
    "return-type": "json",
    "format": "{}",
    "interval": "once",
    "signal": 12,
    "tooltip": true,
    "on-click": "notif-click action 3"
  },
```

- [ ] **Step 3: Enable Pango markup on the bell pill text**

waybar's custom-module text defaults to Pango. If your existing `custom/notif-bell` doesn't have `"markup": "none"`, you don't need to add anything — Pango is automatic. If the module ever did explicitly set markup, ensure it stays at the default. (Belt-and-suspenders: confirm the bell's `<b>` rendering during acceptance — task 13 step 4.)

- [ ] **Step 4: Validate JSON**

```bash
cd /etc/nixos/home
sed -E 's://[^"]*$::' waybar/config.jsonc | jq -e . >/dev/null && echo "OK" || echo "BAD"
```

Expected: `OK`.

- [ ] **Step 5: Commit**

```bash
git add waybar/config.jsonc
git commit -m "$(cat <<'EOF'
waybar/config: 3 action child modules under group/notif

group/notif.modules grows from [dnd, bell] to [action-3, action-2,
action-1, dnd, bell] — right-zone groups expand LEFT on hover, so the
rightmost child in the list (bell) is visually rightmost when collapsed,
and the leftmost child in the list (action-3) is visually leftmost when
expanded.

Each custom/notif-action-N reads /tmp/waybar-cache/notif-action-N
(written by notif-daemon), uses signal 12 to wake on RTMIN+12 like the
other notif children, and dispatches click to `notif-click action N`.
EOF
)"
```

---

## Task 12: ARCHITECTURE.md + TODO.md

**Files:**
- Modify: `waybar/ARCHITECTURE.md`
- Modify: `waybar/TODO.md`

- [ ] **Step 1: Update ARCHITECTURE.md cache list**

Open `/etc/nixos/home/waybar/ARCHITECTURE.md`. Find the active-daemons table row for `notif-daemon`. Change its "Cache" column from `/tmp/waybar-cache/{notif-bell, notif-dnd}` to `/tmp/waybar-cache/{notif-bell, notif-dnd, notif-action-{1,2,3}}`. Update the paragraph beneath the table to mention the three action caches alongside the journal/rofi notes.

- [ ] **Step 2: Add the P2 DONE entry to TODO.md**

In `/etc/nixos/home/waybar/TODO.md`, find the `## DONE` header. Insert the new entry IMMEDIATELY ABOVE the topmost existing DONE entry (which should be the 2026-06-10 P1 entry):

```markdown
- **2026-06-10** — **Notification center P2: actions + app icons + 2FA extraction.**
  Composes onto the live P1 architecture: three child action pills
  (`custom/notif-action-{1,2,3}`) join `group/notif` and surface
  mako's `actions` array on hover-revealed wide pills. Wide-pill text
  gains Pango bold for the app name (`<b>App</b> · Title`) with
  `pango_escape` applied to app/title BEFORE the markup wrap so raw
  D-Bus strings can't inject styling. Rofi rows gain icons via the
  native `\0icon\x1f<app_name>` row metadata + `-show-icons` flag —
  no new icon-resolution code. 2FA / OTP extraction runs a keyword-
  anchored regex (`code|OTP|PIN|verification|auth|login|token|MFA|
  2FA|one-time|cód|código|codice` + 40-char window + 4-8 digit code)
  over summary+body on every arrival; matches embed an `otp_code`
  field in the bell cache and add `opt-glow-green` to the class array.
  Click the OTP wide pill → `wl-copy` the code, rendezvous via
  `/tmp/notif-otp-clicked` + SIGUSR2 to notif-daemon, daemon transitions
  to `otp_copied` kind for 500ms (wide-pill text becomes
  `<b>App</b> · Title · copied`), then dismisses cleanly.
  **Hint:** `render_bell_for_state` gained 2 args (OTP_CODE, OTP_COPIED).
  Bell output always emits `otp_code` (empty string when no code) so the
  JSON schema stays stable; waybar ignores the field, notif-click reads it.
  **Hint:** action children embed the mako action key in a non-standard
  `key` field on the action-N cache. The field name is the project-internal
  contract between notif-daemon (writer) and notif-click (reader); if it
  ever changes both files need synchronised updates.
  **Hint:** P2 added SIGUSR2 alongside the P1 SIGUSR1. USR1 = DND mode
  changed, USR2 = OTP-copied transition. Both traps set a *_PENDING
  flag that the main loop drains; both use the 1-second polling
  fallback for delivery races.

```

- [ ] **Step 3: Commit**

```bash
cd /etc/nixos/home
git add waybar/ARCHITECTURE.md waybar/TODO.md
git commit -m "$(cat <<'EOF'
docs: update ARCHITECTURE + TODO for notif P2

notif-daemon cache list grows from 2 to 5 (adds notif-action-{1,2,3}).
TODO gets a DONE entry with Hints covering the renderer signature
extension, the `key` field contract, and the USR1/USR2 split.
EOF
)"
```

---

## Task 13: Rebuild + acceptance + final commit

**Files:** none (verification + closure).

- [ ] **Step 1: Unit suites must be green**

```bash
cd /etc/nixos/home
bash tests/notif-journal-test.sh
bash tests/notif-rofi-test.sh
bash tests/notif-state-test.sh
bash tests/notif-click-test.sh
```

Expected: every file ends with `✓ all N tests passed`.

- [ ] **Step 2: Ask the user to rebuild**

Tell the user:

> Ready for rebuild + restart. Please run:
> ```
> sudo nixos-rebuild switch && systemctl --user restart notif-daemon.service waybar.service
> ```

- [ ] **Step 3: Verify daemon is healthy**

```bash
systemctl --user is-active notif-daemon.service
cat /tmp/waybar-cache/notif-bell; echo
cat /tmp/waybar-cache/notif-dnd; echo
ls -la /tmp/waybar-cache/notif-action-{1,2,3}; echo
```

Expected: daemon `active`; bell cache shows `otp_code:""` field; 3 action caches all `{"text":""}`.

- [ ] **Step 4: Run the live acceptance suite (11 criteria from the spec)**

```bash
set -u
J=/tmp/waybar-cache
F() { jq -e "$1" "$2" >/dev/null 2>&1 && echo "    PASS" || echo "    FAIL ← $1"; }

makoctl dismiss --all; sleep 0.3

echo "[1] Wide-pill bold: text wraps <b>App</b>"
notify-send "p2-bold test"; sleep 0.5
F '.text | startswith("<b>") and contains("</b> · p2-bold test")' $J/notif-bell
makoctl dismiss --all; sleep 0.3

echo
echo "[2] Pango-escape: <script> in app name"
notify-send -a '<script>alert</script>' "title"; sleep 0.5
F '.text | contains("&lt;script&gt;alert&lt;/script&gt;")' $J/notif-bell
makoctl dismiss --all; sleep 0.3

echo
echo "[3] No actions: all action caches empty"
notify-send "no actions"; sleep 0.5
F '.text == ""' $J/notif-action-1
F '.text == ""' $J/notif-action-2
F '.text == ""' $J/notif-action-3
makoctl dismiss --all; sleep 0.3

echo
echo "[4] One action: action-1 populated, 2/3 empty"
notify-send -A reply=Reply "with action"; sleep 0.5
F '.text == "Reply"' $J/notif-action-1
F '.key == "reply"' $J/notif-action-1
F '.text == ""' $J/notif-action-2
makoctl dismiss --all; sleep 0.3

echo
echo "[5] Three actions: all three populated"
notify-send -A a1=A1 -A a2=A2 -A a3=A3 "three"; sleep 0.5
F '.text == "A1"' $J/notif-action-1
F '.text == "A2"' $J/notif-action-2
F '.text == "A3"' $J/notif-action-3
makoctl dismiss --all; sleep 0.3

echo
echo "[7] OTP detected: opt-glow-green + otp_code field"
notify-send "TestApp" "Your verification code is 348291"; sleep 0.5
F '.class | index("opt-glow-green") != null' $J/notif-bell
F '.otp_code == "348291"' $J/notif-bell

echo
echo "[8] OTP click → wl-copy + 'copied' + dismiss"
echo "garbage-pre-click" | wl-copy
notif-click bell; sleep 0.1
F '.text | endswith("· copied")' $J/notif-bell
sleep 0.6
echo "  wl-paste: $(wl-paste 2>/dev/null)"
F '.text == ""' $J/notif-bell || true  # bell may have pin if still unread
echo "  mako unread: $(busctl --user --json=short call org.freedesktop.Notifications /fr/emersion/Mako fr.emersion.Mako ListNotifications 2>/dev/null | jq -r '.data[0] | length')"

echo
echo "[9] OTP false-positive guard: no keyword → no otp_code"
notify-send "Prices" "Now \$1234 cheaper"; sleep 0.5
F '.class | index("opt-glow-green") == null' $J/notif-bell
F '.otp_code == ""' $J/notif-bell
makoctl dismiss --all; sleep 0.3

echo
echo "[11] Critical + OTP: opt-pulse-orange + opt-glow-green"
notify-send --urgency=critical "auth" "Your code 1111"; sleep 0.5
F '.class | index("opt-pulse-orange") != null' $J/notif-bell
F '.class | index("opt-glow-green") != null' $J/notif-bell
makoctl dismiss --all; sleep 0.3
```

Walk through any FAIL with the user. Common issues:
- Wide pill not bold: confirm waybar's `custom/notif-bell` doesn't have an explicit `markup: none`; if so add `markup: pango` or remove the override.
- OTP regex fails: check `grep -P '' /dev/null` exits 0 or 1 (not 2). If 2, gnugrep isn't on PATH — verify task 10's runtimeDeps change.
- wl-paste empty: confirm `wl-clipboard` is installed and the Wayland clipboard server runs in your session.
- Action caches stuck empty even with `-A` flag: confirm mako 1.10's `busctl ListNotifications` reports `actions.data` as a non-empty array. Run:
  ```bash
  notify-send -A test=Test "x"
  busctl --user --json=short call org.freedesktop.Notifications /fr/emersion/Mako fr.emersion.Mako ListNotifications | jq '.data[0][0].actions.data'
  ```
  Expected: `["test", "Test"]`. If different, adjust the actions-parsing in on_arrival.

- [ ] **Step 5: Manual rofi check (criterion 10)**

Open rofi via `notif-click bell` when the bell is at rest (no transient). Verify rows show app icons for apps with theme matches (Slack, Firefox, Discord, etc.) and text-only for others.

- [ ] **Step 6: Final commit if any acceptance fixes needed**

```bash
cd /etc/nixos/home
git status -s
git add -A
git status -s
git commit -m "notif P2: acceptance gate fixes — <describe>" || echo "nothing to commit"
```

---

## Self-review

**Spec coverage:**
- Pango bold + `pango_escape` ✓ (Task 1 + Task 3)
- 3 action child slots ✓ (Tasks 4, 7, 8, 11)
- App icons in rofi ✓ (Tasks 5, 9)
- OTP detection ✓ (Tasks 2, 7)
- OTP click flow with 500ms hold + dismiss ✓ (Tasks 6, 7, 8)
- Critical + OTP composes ✓ (Task 3 tests, Task 13 acceptance criterion 11)
- Non-standard `key` + `otp_code` JSON fields ✓ (Tasks 3, 4)
- `wl-clipboard` + `gnugrep` dependency ✓ (Task 10)
- ARCHITECTURE + TODO updates ✓ (Task 12)

**Placeholder scan:** none found.

**Type consistency:**
- `render_bell_for_state UNREAD CRITICAL DND_ON KIND APP TITLE BODY OTP_CODE OTP_COPIED` — 9 args, used consistently in Task 3 implementation and Task 7 emit().
- `render_action_for_state KEY LABEL` — 2 args, used in Task 4 implementation and Task 7 emit_action_caches().
- `detect_otp SUMMARY BODY` — 2 args, used in Task 2 implementation and Task 7 on_arrival.
- `pango_escape STRING` — 1 arg, used in Task 1 implementation and Task 3 render_bell_for_state.
- Action cache JSON shape: `{"text":<label>,"class":["opt-pill-child","dark","opt-yes"],"tooltip":<label>,"key":<key>}` — same shape in renderer (Task 4) and click decide (Task 6) and click runtime (Task 8).
- Rendezvous file `/tmp/notif-otp-clicked` + SIGUSR2 — same in click runtime (Task 8) and daemon main-loop drain (Task 7).

---

## Execution handoff

Plan complete and saved to `docs/superpowers/plans/2026-06-10-notification-p2.md`. Two execution options:

**1. Subagent-Driven (recommended)** — fresh subagent per task, two-stage review (spec compliance + code quality) between each.

**2. Inline Execution** — execute tasks in this session using executing-plans, batch execution with checkpoints.

Which approach?
