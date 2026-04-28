#!/usr/bin/env bats
# Tests for copilot-send
# Interface: copilot-send <id> [message] [flags]

SCRIPT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)/copilot-send"

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

# =============================================================================
# Integration tests – run copilot-send directly (no "send" subcommand prefix)
# =============================================================================

@test "send: missing id exits non-zero with 'missing <id>' message" {
  run bash "$SCRIPT"
  [ "$status" -ne 0 ]
  [[ "$output" == *"missing <id>"* ]]
}

@test "send: non-numeric id exits non-zero with plain-number hint" {
  run bash "$SCRIPT" abc "hello"
  [ "$status" -ne 0 ]
  [[ "$output" == *"plain number"* ]]
}

@test "send: pane not found exits non-zero" {
  run bash "$SCRIPT" 99 "hello"
  [ "$status" -ne 0 ]
  [[ "$output" == *"not found"* ]]
}

@test "send: not-idle pane is rejected" {
  export MOCK_PANE_TITLE="🤖 running task"
  run bash "$SCRIPT" 12 "hello"
  [ "$status" -ne 0 ]
  [[ "$output" == *"not idle"* ]]
}

@test "send: waiting_for_input pane is allowed" {
  export MOCK_PANE_TITLE="🤖 reviewing task"
  export MOCK_CAPTURE_PANE="│ ❯ 1. Yes │
│ ↑↓ to navigate · Enter to select │
╰──────────────────────────────────╯"
  run bash "$SCRIPT" 12 "hello"
  [ "$status" -eq 0 ]
}

@test "send: empty stdin is rejected with 'empty message'" {
  run bash -c "printf '' | bash '$SCRIPT' 12"
  [ "$status" -ne 0 ]
  [[ "$output" == *"empty message"* ]]
}

@test "send: message exceeding 102400 bytes is rejected" {
  big="$(head -c 102401 /dev/zero | tr '\0' 'x')"
  run bash "$SCRIPT" 12 "$big"
  [ "$status" -ne 0 ]
  [[ "$output" == *"too large"* ]]
}

@test "send: stdin pipe succeeds for idle pane" {
  run bash -c "echo 'hello from stdin' | bash '$SCRIPT' 12"
  [ "$status" -eq 0 ]
}

# =============================================================================
# P2 – error message after paste succeeds but send-keys fails
# =============================================================================

@test "send: error after paste clarifies message was pasted but Enter not sent" {
  cat > "$MOCK_BIN/tmux" << 'MOCK_EOF'
#!/usr/bin/env bash
case "$1" in
  list-sessions)   echo "main" ;;
  has-session)     exit 0 ;;
  list-panes)
    if [[ "$*" == *"pane_current_command"* ]]; then
      echo "%12|node|/home/user/project|1234|idle title"
    else
      echo "%12"
    fi ;;
  display-message) echo "idle title" ;;
  load-buffer)     cat > /dev/null; exit 0 ;;
  paste-buffer)    exit 0 ;;
  send-keys)       exit 1 ;;
  delete-buffer)   exit 0 ;;
  *) exit 1 ;;
esac
MOCK_EOF
  chmod +x "$MOCK_BIN/tmux"

  run bash "$SCRIPT" 12 "hello"
  [ "$status" -ne 0 ]
  [[ "$output" == *"pasted"* ]] || [[ "$output" == *"manually"* ]]
}

# =============================================================================
# Regression – paste-buffer must NOT use bracket paste (-p)
# =============================================================================

@test "send: paste-buffer is called without -p flag (no bracket paste)" {
  local log="$MOCK_BIN/tmux-calls.log"
  cat > "$MOCK_BIN/tmux" << MOCK_EOF
#!/usr/bin/env bash
echo "\$*" >> "$log"
case "\$1" in
  list-sessions)   echo "main" ;;
  has-session)     exit 0 ;;
  list-panes)
    if [[ "\$*" == *"pane_current_command"* ]]; then
      echo "%12|node|/home/user/project|1234|idle title"
    else
      echo "%12"
    fi ;;
  display-message)
    if [[ "\$*" == *"#S"* ]]; then echo "test-session"
    else echo "idle title"; fi ;;
  load-buffer)     cat > /dev/null; exit 0 ;;
  paste-buffer)    exit 0 ;;
  send-keys)       exit 0 ;;
  delete-buffer)   exit 0 ;;
  capture-pane)    echo "" ;;
  *) exit 1 ;;
esac
MOCK_EOF
  chmod +x "$MOCK_BIN/tmux"

  run bash "$SCRIPT" 12 "hello"
  [ "$status" -eq 0 ]

  # Verify paste-buffer was called
  grep -q "paste-buffer" "$log"
  # Verify -p flag is NOT present in the paste-buffer call
  local paste_call
  paste_call=$(grep "paste-buffer" "$log")
  [[ "$paste_call" != *" -p "* ]]
  [[ "$paste_call" != *" -p" ]]
}

# =============================================================================
# Regression – -- terminator behaviour
# =============================================================================

@test "send: -- terminates flag parsing; positional args after -- are accepted" {
  run bash "$SCRIPT" -- 12 "hello"
  [ "$status" -eq 0 ]
}

@test "send: argument with a leading dash after -- is not treated as a flag" {
  run bash "$SCRIPT" -- 12 "--not-a-flag"
  [ "$status" -eq 0 ]
}
