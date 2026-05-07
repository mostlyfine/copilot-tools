#!/usr/bin/env bats
# Tests for save-session-log.sh

SCRIPT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)/.github/hooks/save-session-log.sh"

# ── helpers ──────────────────────────────────────────────────────────────────

setup() {
  DEST_DIR="$(mktemp -d)"
  FAKE_HOME="$(mktemp -d)"
  SESSION_ID="test-session-abc123"
  SESSION_DIR="${FAKE_HOME}/.copilot/session-state/${SESSION_ID}"
  mkdir -p "$SESSION_DIR"

  # 2026-04-28 17:37:34 UTC = 1745860654 sec = 1745860654000 ms
  TIMESTAMP_MS=1745860654000
  HOOK_INPUT=$(jq -cn \
    --argjson ts "$TIMESTAMP_MS" \
    --arg sessionId "$SESSION_ID" \
    --arg reason "user_terminated" \
    '{timestamp: $ts, sessionId: $sessionId, reason: $reason}')

  export COPILOT_LOG_DIR="$DEST_DIR"
  export HOME="$FAKE_HOME"
}

teardown() {
  rm -rf "$DEST_DIR" "$FAKE_HOME"
}

_write_events() {
  cat > "${SESSION_DIR}/events.jsonl"
}

_run_hook() {
  echo "$HOOK_INPUT" | bash "$SCRIPT"
}

_log_file() {
  ls "$DEST_DIR"/*.md 2>/dev/null | head -1
}

# ── tests ─────────────────────────────────────────────────────────────────────

@test "basic: .jsonl copy is created (existing behavior preserved)" {
  _write_events <<'EVENTS'
{"type":"session.start","data":{"sessionId":"test-session-abc123","startTime":"2026-04-28T17:37:34.000Z","context":{"cwd":"/home/user/project"}},"timestamp":"2026-04-28T17:37:34.000Z","id":"e1","parentId":null}
{"type":"user.message","data":{"content":"Hello!"},"timestamp":"2026-04-28T17:37:35.000Z","id":"e2","parentId":"e1"}
EVENTS
  _run_hook
  ls "$DEST_DIR"/*.jsonl
}

@test "basic: .md file is created from events.jsonl" {
  _write_events <<'EVENTS'
{"type":"session.start","data":{"sessionId":"test-session-abc123","startTime":"2026-04-28T17:37:34.000Z","context":{"cwd":"/home/user/project"}},"timestamp":"2026-04-28T17:37:34.000Z","id":"e1","parentId":null}
{"type":"user.message","data":{"content":"Hello!"},"timestamp":"2026-04-28T17:37:35.000Z","id":"e2","parentId":"e1"}
{"type":"assistant.message","data":{"content":"Hi there!","reasoningText":"","toolRequests":[]},"timestamp":"2026-04-28T17:37:36.000Z","id":"e3","parentId":"e2"}
EVENTS
  _run_hook
  LOG=$(_log_file)
  [ -n "$LOG" ]
  grep -q '## User' "$LOG"
  grep -q 'Hello!' "$LOG"
  grep -q '## Copilot' "$LOG"
  grep -q 'Hi there!' "$LOG"
}

@test "header: frontmatter contains cwd" {
  _write_events <<'EVENTS'
{"type":"session.start","data":{"sessionId":"test-session-abc123","startTime":"2026-04-28T17:37:34.000Z","context":{"cwd":"/home/user/myproject"}},"timestamp":"2026-04-28T17:37:34.000Z","id":"e1","parentId":null}
EVENTS
  _run_hook
  LOG=$(_log_file)
  grep -q '/home/user/myproject' "$LOG"
}

@test "thinking: [Thinking] block is NOT output even when reasoningText is non-empty" {
  _write_events <<'EVENTS'
{"type":"session.start","data":{"sessionId":"test-session-abc123","startTime":"2026-04-28T17:37:34.000Z","context":{"cwd":"/tmp"}},"timestamp":"2026-04-28T17:37:34.000Z","id":"e1","parentId":null}
{"type":"assistant.message","data":{"content":"Done.","reasoningText":"The user wants a greeting.","toolRequests":[]},"timestamp":"2026-04-28T17:37:36.000Z","id":"e2","parentId":"e1"}
EVENTS
  _run_hook
  LOG=$(_log_file)
  ! grep -q 'Thinking' "$LOG"
  ! grep -q 'The user wants a greeting.' "$LOG"
}

@test "thinking: no Thinking block when reasoningText is empty" {
  _write_events <<'EVENTS'
{"type":"session.start","data":{"sessionId":"test-session-abc123","startTime":"2026-04-28T17:37:34.000Z","context":{"cwd":"/tmp"}},"timestamp":"2026-04-28T17:37:34.000Z","id":"e1","parentId":null}
{"type":"assistant.message","data":{"content":"Done.","reasoningText":"","toolRequests":[]},"timestamp":"2026-04-28T17:37:36.000Z","id":"e2","parentId":"e1"}
EVENTS
  _run_hook
  LOG=$(_log_file)
  ! grep -q 'Thinking' "$LOG"
}

@test "tools: no tool blocks are output" {
  _write_events <<'EVENTS'
{"type":"session.start","data":{"sessionId":"test-session-abc123","startTime":"2026-04-28T17:37:34.000Z","context":{"cwd":"/tmp"}},"timestamp":"2026-04-28T17:37:34.000Z","id":"e1","parentId":null}
{"type":"assistant.message","data":{"content":"Found it.","reasoningText":"","toolRequests":[{"toolCallId":"call-3","name":"report_intent","arguments":{"intent":"Searching files"},"type":"function"},{"toolCallId":"call-4","name":"grep","arguments":{"pattern":"bar"},"type":"function"}]},"timestamp":"2026-04-28T17:37:36.000Z","id":"e2","parentId":"e1"}
{"type":"tool.execution_complete","data":{"toolCallId":"call-3","success":true,"result":{"content":"Intent logged"},"toolTelemetry":{}},"timestamp":"2026-04-28T17:37:37.000Z","id":"e3","parentId":"e2"}
{"type":"tool.execution_complete","data":{"toolCallId":"call-4","success":true,"result":{"content":"src/bar.ts:5: bar"},"toolTelemetry":{}},"timestamp":"2026-04-28T17:37:37.000Z","id":"e4","parentId":"e2"}
EVENTS
  _run_hook
  LOG=$(_log_file)
  grep -q 'Found it.' "$LOG"
  ! grep -q 'report_intent' "$LOG"
  ! grep -q '#### Tool: grep' "$LOG"
  ! grep -qF '**Args:**' "$LOG"
  ! grep -q 'src/bar.ts' "$LOG"
}

@test "no session_id: no .md file created" {
  HOOK_INPUT=$(jq -cn \
    --argjson ts "$TIMESTAMP_MS" \
    --arg reason "user_terminated" \
    '{timestamp: $ts, reason: $reason}')
  echo "$HOOK_INPUT" | bash "$SCRIPT"
  [ -z "$(_log_file)" ]
}

@test "no events.jsonl: no .md file created" {
  # SESSION_DIR exists but events.jsonl does not
  _run_hook
  [ -z "$(_log_file)" ]
}

@test "resilience: malformed jsonl does not fail the hook" {
  printf '{"type":"user.message","data":{"content":"hi"},"timestamp":"2026-04-28T17:37:35.000Z","id":"e1","parentId":null}\nNOT_JSON\n' \
    > "${SESSION_DIR}/events.jsonl"
  run _run_hook
  [ "$status" -eq 0 ]
}

@test "thinking: multi-line reasoningText is NOT output" {
  _write_events <<'EVENTS'
{"type":"session.start","data":{"sessionId":"test-session-abc123","startTime":"2026-04-28T17:37:34.000Z","context":{"cwd":"/tmp"}},"timestamp":"2026-04-28T17:37:34.000Z","id":"e1","parentId":null}
{"type":"assistant.message","data":{"content":"Done.","reasoningText":"Line one.\nLine two.","toolRequests":[]},"timestamp":"2026-04-28T17:37:36.000Z","id":"e2","parentId":"e1"}
EVENTS
  _run_hook
  LOG=$(_log_file)
  ! grep -q '^> Line two\.' "$LOG"
}

@test "process log is NOT copied to .md (old behavior removed)" {
  # Create a fake process log
  mkdir -p "${FAKE_HOME}/.copilot/logs"
  echo "process-log-content" > "${FAKE_HOME}/.copilot/logs/process-test.log"

  _write_events <<'EVENTS'
{"type":"session.start","data":{"sessionId":"test-session-abc123","startTime":"2026-04-28T17:37:34.000Z","context":{"cwd":"/tmp"}},"timestamp":"2026-04-28T17:37:34.000Z","id":"e1","parentId":null}
EVENTS
  _run_hook
  LOG=$(_log_file)
  # .log should NOT contain raw process log content
  [ -z "$LOG" ] || ! grep -q 'process-log-content' "$LOG"
}

@test "skill-context: source=skill-* message is NOT output" {
  _write_events <<'EVENTS'
{"type":"session.start","data":{"sessionId":"test-session-abc123","startTime":"2026-04-28T17:37:34.000Z","context":{"cwd":"/tmp"}},"timestamp":"2026-04-28T17:37:34.000Z","id":"e1","parentId":null}
{"type":"user.message","data":{"content":"Hello!","source":"user"},"timestamp":"2026-04-28T17:37:35.000Z","id":"e2","parentId":"e1"}
{"type":"user.message","data":{"content":"<skill-context name=\"my-skill\">\nskill content here\n</skill-context>","source":"skill-my-skill"},"timestamp":"2026-04-28T17:37:36.000Z","id":"e3","parentId":"e2"}
EVENTS
  _run_hook
  LOG=$(_log_file)
  ! grep -q 'skill content here' "$LOG"
  ! grep -q 'skill-context' "$LOG"
  grep -q 'Hello!' "$LOG"
}

@test "skill-context: source=user message IS output" {
  _write_events <<'EVENTS'
{"type":"session.start","data":{"sessionId":"test-session-abc123","startTime":"2026-04-28T17:37:34.000Z","context":{"cwd":"/tmp"}},"timestamp":"2026-04-28T17:37:34.000Z","id":"e1","parentId":null}
{"type":"user.message","data":{"content":"User typed this","source":"user"},"timestamp":"2026-04-28T17:37:35.000Z","id":"e2","parentId":"e1"}
EVENTS
  _run_hook
  LOG=$(_log_file)
  grep -q 'User typed this' "$LOG"
}

@test "skill-context: backward compat - message without source field IS output" {
  _write_events <<'EVENTS'
{"type":"session.start","data":{"sessionId":"test-session-abc123","startTime":"2026-04-28T17:37:34.000Z","context":{"cwd":"/tmp"}},"timestamp":"2026-04-28T17:37:34.000Z","id":"e1","parentId":null}
{"type":"user.message","data":{"content":"Legacy message no source"},"timestamp":"2026-04-28T17:37:35.000Z","id":"e2","parentId":"e1"}
EVENTS
  _run_hook
  LOG=$(_log_file)
  grep -q 'Legacy message no source' "$LOG"
}

@test "skill-context: description uses first user message (not skill message)" {
  _write_events <<'EVENTS'
{"type":"session.start","data":{"sessionId":"test-session-abc123","startTime":"2026-04-28T17:37:34.000Z","context":{"cwd":"/tmp"}},"timestamp":"2026-04-28T17:37:34.000Z","id":"e1","parentId":null}
{"type":"user.message","data":{"content":"<skill-context name=\"brainstorming\">\nbig skill block\n</skill-context>","source":"skill-brainstorming"},"timestamp":"2026-04-28T17:37:35.000Z","id":"e2","parentId":"e1"}
{"type":"user.message","data":{"content":"What the user actually typed","source":"user"},"timestamp":"2026-04-28T17:37:36.000Z","id":"e3","parentId":"e2"}
EVENTS
  _run_hook
  LOG=$(_log_file)
  grep -q 'What the user actually typed' "$LOG"
  ! grep -q 'big skill block' "$LOG"
}

@test "tools: tool-only assistant message is NOT output" {
  _write_events <<'EVENTS'
{"type":"session.start","data":{"sessionId":"test-session-abc123","startTime":"2026-04-28T17:37:34.000Z","context":{"cwd":"/tmp"}},"timestamp":"2026-04-28T17:37:34.000Z","id":"e1","parentId":null}
{"type":"assistant.message","data":{"content":"","reasoningText":"","toolRequests":[{"toolCallId":"call-1","name":"grep","arguments":{"pattern":"foo"},"type":"function"}]},"timestamp":"2026-04-28T17:37:36.000Z","id":"e2","parentId":"e1"}
{"type":"tool.execution_complete","data":{"toolCallId":"call-1","success":true,"result":{"content":"src/foo.ts:1: foo"},"toolTelemetry":{}},"timestamp":"2026-04-28T17:37:37.000Z","id":"e3","parentId":"e2"}
EVENTS
  _run_hook
  LOG=$(_log_file)
  [ -z "$LOG" ] || ! grep -q '## Copilot' "$LOG"
}

@test "changed_files: ~/.copilot/ files ARE included (no exclusion)" {
  _write_events <<'EVENTS'
{"type":"session.start","data":{"sessionId":"test-session-abc123","startTime":"2026-04-28T17:37:34.000Z","context":{"cwd":"/home/user/project"}},"timestamp":"2026-04-28T17:37:34.000Z","id":"e1","parentId":null}
{"type":"user.message","data":{"content":"Do something"},"timestamp":"2026-04-28T17:37:35.000Z","id":"e2","parentId":"e1"}
{"type":"session.shutdown","data":{"currentModel":"claude","codeChanges":{"filesModified":["/home/user/project/main.ts","/home/user/.copilot/session-state/abc/plan.md"]}},"timestamp":"2026-04-28T17:37:40.000Z","id":"e5","parentId":"e4"}
EVENTS
  _run_hook
  LOG=$(_log_file)
  grep -q 'main.ts' "$LOG"
  grep -q 'session-state/abc/plan.md' "$LOG"
}

@test "tools: mixed message outputs text only" {
  _write_events <<'EVENTS'
{"type":"session.start","data":{"sessionId":"test-session-abc123","startTime":"2026-04-28T17:37:34.000Z","context":{"cwd":"/tmp"}},"timestamp":"2026-04-28T17:37:34.000Z","id":"e1","parentId":null}
{"type":"assistant.message","data":{"content":"Here is the result.","reasoningText":"","toolRequests":[{"toolCallId":"call-1","name":"bash","arguments":{"command":"ls"},"type":"function"}]},"timestamp":"2026-04-28T17:37:36.000Z","id":"e2","parentId":"e1"}
{"type":"tool.execution_complete","data":{"toolCallId":"call-1","success":true,"result":{"content":"file1.txt\nfile2.txt"},"toolTelemetry":{}},"timestamp":"2026-04-28T17:37:37.000Z","id":"e3","parentId":"e2"}
EVENTS
  _run_hook
  LOG=$(_log_file)
  grep -q 'Here is the result.' "$LOG"
  ! grep -q '#### Tool: bash' "$LOG"
  ! grep -qF '**Args:**' "$LOG"
  ! grep -q 'file1.txt' "$LOG"
}
