#!/usr/bin/env bash
# sessionEnd hook: save formatted conversation log to COPILOT_LOG_DIR

set -euo pipefail

INPUT=$(cat)
TIMESTAMP=$(echo "$INPUT" | jq -r '.timestamp')
REASON=$(echo "$INPUT" | jq -r '.reason')
SESSION_ID=$(echo "$INPUT" | jq -r '.sessionId // empty')

DEST_DIR="${COPILOT_LOG_DIR:-/tmp/copilot-logs}"
DEST_DIR="${DEST_DIR/#\~/$HOME}"  # Expand leading ~ to $HOME
mkdir -p "$DEST_DIR"

# Convert millisecond timestamp to seconds and format as datetime strings
UNIX_SECS=$((TIMESTAMP / 1000))
DATE_STR=$(date -r "$UNIX_SECS" "+%Y%m%d_%H%M%S" 2>/dev/null || date "+%Y%m%d_%H%M%S")
DATE_DISPLAY=$(date -r "$UNIX_SECS" "+%Y-%m-%d %H:%M:%S" 2>/dev/null || date "+%Y-%m-%d %H:%M:%S")

BASE_NAME="session_${DATE_STR}_${REASON}"

if [ -n "$SESSION_ID" ]; then
    EVENTS_FILE="${HOME}/.copilot/session-state/${SESSION_ID}/events.jsonl"
    if [ -f "$EVENTS_FILE" ]; then
        # Generate Markdown conversation log from events.jsonl
        if ! jq -rs \
          --arg date "$DATE_DISPLAY" \
          --arg reason "$REASON" \
          '
          (map(select(.type == "session.start")) | first | .data.context.cwd // "") as $cwd |
          (map(select(.type == "tool.execution_complete")) | INDEX(.data.toolCallId)) as $tools |

          "# Copilot Session: \($date)\n\n- **CWD:** \($cwd)\n- **Reason:** \($reason)\n\n---\n",

          (.[] |
            if .type == "user.message" then
              "## User\n\n" + .data.content + "\n\n---\n"

            elif .type == "assistant.message" then
              "## Copilot\n\n" +
              (if (.data.reasoningText // "") != "" then
                "> **Thinking:** " + (.data.reasoningText | gsub("\n"; "\n> ")) + "\n\n"
              else "" end) +
              (if (.data.content // "") != "" then .data.content + "\n\n" else "" end) +
              ([ .data.toolRequests[]? |
                  select(.name != "report_intent") |
                  . as $req |
                  ($tools[$req.toolCallId]) as $result |
                  "#### Tool: " + $req.name + "\n\n" +
                  "**Args:** `" + (($req.arguments | tojson) | if length > 500 then .[0:500] + "\u2026" else . end) + "`\n\n" +
                  (if $result != null then
                    (if $result.data.success
                     then "**Result (\u2713):**\n```\n"
                     else "**Result (\u2717):**\n```\n" end) +
                    (($result.data.result.content // "") |
                      if length > 500 then .[0:500] + "\n*(truncated)*" else . end) +
                    "\n```\n\n"
                  else "" end)
               ] | join("")) +
              "---\n"

            else empty
            end
          )
          ' "$EVENTS_FILE" > "${DEST_DIR}/${BASE_NAME}.log" 2>/dev/null; then
          rm -f "${DEST_DIR}/${BASE_NAME}.log"
        fi
    fi
fi

exit 0
