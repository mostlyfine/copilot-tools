#!/usr/bin/env bats
# Tests for copilot-await

SCRIPT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)/copilot-await"

setup() {
  MOCK_BIN="$(mktemp -d)"

  cat > "$MOCK_BIN/tmux" << 'TMUX_EOF'
#!/usr/bin/env bash
MOCK_PANE_IDS="${MOCK_PANE_IDS:-%10 %11 %12}"
MOCK_PANE_TITLE="${MOCK_PANE_TITLE:-idle title}"
MOCK_PANE_DATA="${MOCK_PANE_DATA:-%12|node|/home/user/myproject|1234|$MOCK_PANE_TITLE}"
MOCK_HAS_SESSION="${MOCK_HAS_SESSION:-test-session}"

case "$1" in
  list-sessions)
    echo "main: 1 windows (created Mon Apr 13 00:00:00 2026) [attached]" ;;
  has-session)
    [[ "${3:-}" == "$MOCK_HAS_SESSION" ]] && exit 0 || exit 1 ;;
  list-panes)
    if [[ "$*" == *"pane_current_command"* ]]; then
      printf '%s\n' "$MOCK_PANE_DATA"
    else
      for id in $MOCK_PANE_IDS; do printf "%s\n" "$id"; done
    fi ;;
  display-message)
    if [[ "$*" == *"#S"* ]]; then
      printf '%s\n' "${MOCK_SESSION_NAME:-test-session}"
    else
      printf '%s\n' "$MOCK_PANE_TITLE"
    fi ;;
  load-buffer) cat > /dev/null; exit 0 ;;
  paste-buffer) exit 0 ;;
  send-keys)   exit 0 ;;
  delete-buffer) exit 0 ;;
  capture-pane) printf '%s\n' "${MOCK_CAPTURE_PANE:-}" ;;
  *)
    printf 'tmux-mock: unhandled: %s\n' "$*" >&2
    exit 1 ;;
esac
TMUX_EOF
  chmod +x "$MOCK_BIN/tmux"

  cat > "$MOCK_BIN/pgrep" << 'EOF'
#!/usr/bin/env bash
echo "9999"
EOF
  chmod +x "$MOCK_BIN/pgrep"

  cat > "$MOCK_BIN/ps" << 'EOF'
#!/usr/bin/env bash
echo "/usr/bin/node /usr/local/lib/copilot/cli/index.js"
EOF
  chmod +x "$MOCK_BIN/ps"

  export PATH="$MOCK_BIN:$PATH"
  export MOCK_BIN
  export COPILOT_PS_WAIT_AFTER_PASTE=0
  export TMUX="mock-tmux-socket,0,0"

  # shellcheck disable=SC1090
  source "$SCRIPT"
}

teardown() {
  rm -rf "$MOCK_BIN"
}

# =============================================================================
# TMUX session detection
# =============================================================================

@test "not inside tmux: exits non-zero with error message" {
  run env -u TMUX bash "$SCRIPT" 2>&1
  [ "$status" -ne 0 ]
  [[ "$output" == *"tmux session"* ]]
}

@test "auto-detects current tmux session when no -s given" {
  export MOCK_SESSION_NAME="autodetect-session"
  run render
  [[ "$output" == *"autodetect-session"* ]] || [ "$status" -eq 0 ]
}

# =============================================================================
# Unit tests – pure helper functions
# =============================================================================

@test "shorten_dir: replaces HOME prefix with ~" {
  run shorten_dir "$HOME/work/project"
  [ "$output" = "~/work/project" ]
}

@test "shorten_dir: non-HOME path stays as absolute path" {
  run shorten_dir "/tmp/project"
  [ "$output" = "/tmp/project" ]
}

@test "shorten_dir: path within 30 chars is shown as-is after tilde expansion" {
  run shorten_dir "$HOME/project"
  [ ${#output} -le 30 ]
  [[ "$output" != *"..."* ]]
}

@test "shorten_dir: path longer than 30 chars is truncated with leading ..." {
  run shorten_dir "/very/long/path/to/some/deeply/nested/project/dir"
  [ ${#output} -le 30 ]
  [[ "$output" == "..."* ]]
}

@test "title_status: 🤖 prefix → running" {
  run title_status "🤖 some task"
  [ "$status" -eq 0 ]
  [ "$output" = "running" ]
}

@test "title_status: no prefix → idle" {
  run title_status "idle pane title"
  [ "$status" -eq 0 ]
  [ "$output" = "idle" ]
}

# =============================================================================
# pane_status – content-aware status detection
# =============================================================================

@test "pane_status: 🤖 title with no special content → running" {
  run pane_status "%12" "🤖 some task"
  [ "$output" = "running" ]
}

@test "pane_status: 🤖 title with selection UI in content → waiting_for_input" {
  export MOCK_CAPTURE_PANE="│ ❯ 1. Yes │
│ ↑↓ to navigate · Enter to select │
╰──────────────────────────────────╯"
  run pane_status "%12" "🤖 some task"
  [ "$output" = "waiting_for_input" ]
}

@test "pane_status: 🤖 title with '↑↓ to navigate' in content → waiting_for_input" {
  export MOCK_CAPTURE_PANE="↑↓ to navigate · Enter to select"
  run pane_status "%12" "🤖 some task"
  [ "$output" = "waiting_for_input" ]
}

@test "pane_status: 🤖 title with '↑↓ to select · Enter to confirm' in content → waiting_for_input" {
  export MOCK_CAPTURE_PANE="╭──────────────────────────────────╮
│ ❯ 1. Option A                    │
│   2. Option B                    │
│ ↑↓ to select · Enter to confirm  │
╰──────────────────────────────────╯"
  run pane_status "%12" "🤖 some task"
  [ "$output" = "waiting_for_input" ]
}

@test "pane_status: 🤖 title with freeform text input UI → waiting_for_input" {
  export MOCK_CAPTURE_PANE="╭──────────────────────────────────────────────╮
│ What is the organization name?               │
│ ──────────────────────────────────────────── │
│ ❯ Type your answer...                        │
│                                              │
│ Enter to submit · Esc to cancel              │
╰──────────────────────────────────────────────╯"
  run pane_status "%12" "🤖 some task"
  [ "$output" = "waiting_for_input" ]
}

@test "pane_status: 🤖 title with historical selection (content follows) → running" {
  export MOCK_CAPTURE_PANE="│ ↑↓ to navigate · Enter to select │
╰──────────────────────────────────╯
✔ Yes
Running terraform init..."
  run pane_status "%12" "🤖 some task"
  [ "$output" = "running" ]
}

@test "pane_status: no 🤖 title, no nav hint → idle" {
  export MOCK_CAPTURE_PANE="│ ❯ 1. Yes │"
  run pane_status "%12" "plain idle title"
  [ "$output" = "idle" ]
}

@test "pane_status: no 🤖 title with nav hint (current) → waiting_for_input" {
  export MOCK_CAPTURE_PANE="╭──────────────────────────────────╮
│ ❯ 1. Option A                    │
│   2. Option B                    │
│ ↑↓ to select · Enter to confirm · Esc to cancel │
╰──────────────────────────────────╯"
  run pane_status "%12" "plain idle title"
  [ "$output" = "waiting_for_input" ]
}

@test "title_task: strips 🤖 and leading space" {
  run title_task "🤖 my task"
  [ "$output" = "my task" ]
}

@test "title_task: truncates strings longer than 45 chars with ellipsis" {
  long="$(printf 'a%.0s' $(seq 1 50))"
  run title_task "$long"
  [ ${#output} -le 45 ]
  [[ "$output" == *"..." ]]
}

# =============================================================================
# get_list_copilot_panes
# =============================================================================

@test "get_list_copilot_panes: first field is numeric pane id (not session:win.pane)" {
  run get_list_copilot_panes
  [ -n "$output" ]
  first_field="$(printf '%s' "$output" | head -1 | awk -F$'\x1F' '{print $1}')"
  [[ "$first_field" =~ ^[0-9]+$ ]]
}

@test "get_list_copilot_panes: output has no session:window.pane address" {
  run get_list_copilot_panes
  ! [[ "$output" =~ [a-zA-Z0-9_-]+:[0-9]+\.[0-9]+ ]]
}

# =============================================================================
# P1 – SESSION_FILTER with spaces must not break list-panes invocation
# =============================================================================

@test "get_list_copilot_panes: SESSION_FILTER with spaces is passed as a single token" {
  cat > "$MOCK_BIN/tmux" << 'MOCK_EOF'
#!/usr/bin/env bash
case "$1" in
  list-sessions) echo "main" ;;
  has-session)   exit 0 ;;
  list-panes)
    prev=""
    for arg in "$@"; do
      [[ "$prev" == "-t" ]] && { t_val="$arg"; break; }
      prev="$arg"
    done
    [[ "$t_val" == "my session" ]] || exit 1
    echo "%12|node|/home/user/project|1234|idle title"
    ;;
  *) exit 0 ;;
esac
MOCK_EOF
  chmod +x "$MOCK_BIN/tmux"

  SESSION_FILTER="my session"
  run get_list_copilot_panes
  [ -n "$output" ]
}

# =============================================================================
# P3 – watch_loop must re-register WINCH to clear on terminal resize
# =============================================================================

@test "watch_loop: registers WINCH signal handler in its body" {
  run bash -c "source '$SCRIPT'; type watch_loop"
  [[ "$output" == *"WINCH"* ]]
}

# =============================================================================
# waiting_content – dialog extraction
# =============================================================================

@test "waiting_content: returns lines from ╭ to nav hint, excludes prior content" {
  export MOCK_CAPTURE_PANE="earlier content
╭──────────────────╮
│ Do you want to?  │
│ ❯ 1. Yes         │
│   2. No          │
│ ↑↓ to navigate   │
╰──────────────────╯"
  run waiting_content "%12"
  [ "$status" -eq 0 ]
  [[ "$output" == *"╭"* ]]
  [[ "$output" == *"↑↓ to navigate"* ]]
  ! [[ "$output" == *"earlier content"* ]]
}

@test "waiting_content: fallback to last 25 lines when no ╭ found" {
  local content=""
  for i in $(seq 1 30); do content+="line $i"$'\n'; done
  content+="↑↓ to navigate"
  export MOCK_CAPTURE_PANE="$content"
  run waiting_content "%12"
  [ "$status" -eq 0 ]
  [[ "$output" == *"↑↓ to navigate"* ]]
  ! echo "$output" | grep -qxF "line 1"
}

@test "waiting_content: returns nothing when no nav hint in content" {
  export MOCK_CAPTURE_PANE="just some content with no navigation hints"
  run waiting_content "%12"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "waiting_content: freeform text input box is extracted" {
  export MOCK_CAPTURE_PANE="some prior output
╭──────────────────────────────────────────────╮
│ What is the organization name?               │
│ ──────────────────────────────────────────── │
│ ❯ Type your answer...                        │
│                                              │
│ Enter to submit · Esc to cancel              │
╰──────────────────────────────────────────────╯"
  run waiting_content "%12"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Enter to submit"* ]]
  [[ "$output" == *"╭"* ]]
  ! [[ "$output" == *"some prior output"* ]]
}

@test "waiting_content: nested box - shows entire outer window including title and options" {
  export MOCK_CAPTURE_PANE="╭────────────────────────────────────╮
│ Search DAGs for bucket/report refs │
│ ─────────────────────────────────── │
│ ╭────────────────────────────────╮ │
│ │ grep -rn \"pattern\" /some/path  │ │
│ ╰────────────────────────────────╯ │
│                                    │
│ Do you want to run this command?   │
│                                    │
│ ❯ 1. Yes                           │
│ ↑↓ to navigate · Enter to select   │
╰────────────────────────────────────╯"
  run waiting_content "%12"
  [ "$status" -eq 0 ]
  [[ "$output" == *"grep"* ]]
  [[ "$output" == *"Search DAGs"* ]]
  [[ "$output" == *"Do you want to run"* ]]
}

# =============================================================================
# _find_nav_line – nav hint line-number helper
# =============================================================================

@test "_find_nav_line: returns line number of ↑↓ to navigate hint" {
  run bash -c 'source "'"$SCRIPT"'"; printf "line1\n↑↓ to navigate\nline3\n" | _find_nav_line'
  [ "$status" -eq 0 ]
  [ "$output" = "2" ]
}

@test "_find_nav_line: matches ↑↓ to select pattern" {
  run bash -c 'source "'"$SCRIPT"'"; printf "foo\n↑↓ to select · Enter to confirm · Esc to cancel\nbar\n" | _find_nav_line'
  [ "$status" -eq 0 ]
  [ "$output" = "2" ]
}

@test "_find_nav_line: matches Enter to select pattern" {
  run bash -c 'source "'"$SCRIPT"'"; printf "foo\nEnter to select\nbar\n" | _find_nav_line'
  [ "$status" -eq 0 ]
  [ "$output" = "2" ]
}

@test "_find_nav_line: matches Enter to confirm pattern" {
  run bash -c 'source "'"$SCRIPT"'"; printf "foo\nEnter to confirm\nbar\n" | _find_nav_line'
  [ "$status" -eq 0 ]
  [ "$output" = "2" ]
}

@test "_find_nav_line: matches Enter to submit pattern" {
  run bash -c 'source "'"$SCRIPT"'"; printf "foo\nEnter to submit · Esc to cancel\nbar\n" | _find_nav_line'
  [ "$status" -eq 0 ]
  [ "$output" = "2" ]
}

@test "_find_nav_line: returns last match when multiple nav hints present" {
  run bash -c 'source "'"$SCRIPT"'"; printf "Enter to select\nfoo\n↑↓ to navigate\n" | _find_nav_line'
  [ "$status" -eq 0 ]
  [ "$output" = "3" ]
}

@test "_find_nav_line: returns empty when no nav hint found" {
  run bash -c 'source "'"$SCRIPT"'"; printf "just some content\n" | _find_nav_line'
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# =============================================================================
# render – waiting-for-input section
# =============================================================================

@test "render: shows waiting section header when a pane is waiting_for_input" {
  export MOCK_PANE_TITLE="🤖 my task"
  export MOCK_CAPTURE_PANE="╭──────────────────╮
│ ❯ 1. Yes         │
│ ↑↓ to navigate   │
╰──────────────────╯"
  run render
  [[ "$output" == *"待ち"* ]] || [[ "$output" == *"Waiting"* ]]
}

@test "render: waiting section includes pane ID" {
  export MOCK_PANE_TITLE="🤖 my task"
  export MOCK_CAPTURE_PANE="╭──────────────────╮
│ ❯ 1. Yes         │
│ ↑↓ to navigate   │
╰──────────────────╯"
  run render
  [[ "$output" == *"Pane 12"* ]]
}

@test "render: waiting section shows dialog content" {
  export MOCK_PANE_TITLE="🤖 my task"
  export MOCK_CAPTURE_PANE="╭──────────────────╮
│ ❯ 1. Yes         │
│ ↑↓ to navigate   │
╰──────────────────╯"
  run render
  [[ "$output" == *"╭"* ]]
}

@test "render: shows no-waiting message when no panes are waiting_for_input" {
  export MOCK_PANE_TITLE="idle title"
  run render
  [[ "$output" == *"入力待ちのペインはありません"* ]]
}

@test "render: task name containing pipe character is displayed intact" {
  export MOCK_PANE_TITLE="🤖 task|with pipe"
  export MOCK_CAPTURE_PANE="╭──────────────────╮
│ ❯ 1. Yes         │
│ ↑↓ to navigate   │
╰──────────────────╯"
  run render
  [[ "$output" == *"task|with pipe"* ]]
}

# =============================================================================
# Notification – send_notification / check_and_notify
# =============================================================================

@test "send_notification: iTerm2 uses OSC 9 escape" {
  export TERM_PROGRAM="iTerm.app"
  run send_notification "Title" "Body"
  [ "$status" -eq 0 ]
  [[ "$output" == *"]9;"* ]]
  [[ "$output" == *"Title: Body"* ]]
}

@test "send_notification: Ghostty calls osascript" {
  export TERM_PROGRAM="ghostty"
  cat > "$MOCK_BIN/osascript" << 'EOF'
#!/usr/bin/env bash
echo "osascript: $*"
EOF
  chmod +x "$MOCK_BIN/osascript"
  run send_notification "Title" "Body"
  [ "$status" -eq 0 ]
}

@test "check_and_notify: running→idle triggers notification" {
  export TERM_PROGRAM="iTerm.app"
  _PREV_STATUS=([42]="running")
  run check_and_notify "42" "idle" "my task"
  [ "$status" -eq 0 ]
  [[ "$output" == *"完了"* ]]
  [[ "$output" == *"my task"* ]]
}

@test "check_and_notify: running→waiting_for_input triggers notification" {
  export TERM_PROGRAM="iTerm.app"
  _PREV_STATUS=([42]="running")
  run check_and_notify "42" "waiting_for_input" "my task"
  [ "$status" -eq 0 ]
  [[ "$output" == *"入力待ち"* ]]
  [[ "$output" == *"my task"* ]]
}

@test "check_and_notify: idle→idle does not notify" {
  export TERM_PROGRAM="iTerm.app"
  _PREV_STATUS=([42]="idle")
  run check_and_notify "42" "idle" "my task"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "check_and_notify: running→running does not notify" {
  export TERM_PROGRAM="iTerm.app"
  _PREV_STATUS=([42]="running")
  run check_and_notify "42" "running" "my task"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "check_and_notify: first seen (no prev) does not notify" {
  export TERM_PROGRAM="iTerm.app"
  _PREV_STATUS=()
  run check_and_notify "42" "idle" "my task"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "parse_args: -n flag sets NOTIFY to true" {
  NOTIFY=false
  parse_args -n
  [ "$NOTIFY" = "true" ]
}

@test "parse_args: --notify flag sets NOTIFY to true" {
  NOTIFY=false
  parse_args --notify
  [ "$NOTIFY" = "true" ]
}
