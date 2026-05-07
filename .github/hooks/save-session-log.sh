#!/usr/bin/env bash
# sessionEnd hook: save formatted conversation log to COPILOT_LOG_DIR

set -euo pipefail

INPUT=$(cat)
SESSION_ID=$(echo "$INPUT" | jq -r '.sessionId // empty')
TIMESTAMP=$(echo "$INPUT" | jq -r '.timestamp // 0')
UNIX_SECS=$((TIMESTAMP / 1000))

DEST_DIR="${COPILOT_LOG_DIR:-/tmp/copilot-logs}"
DEST_DIR="${DEST_DIR/#\~/$HOME}"  # Expand leading ~ to $HOME
mkdir -p "$DEST_DIR"

DATE_STR=$(date -r "$UNIX_SECS" "+%Y%m%d_%H%M%S" 2>/dev/null || date "+%Y%m%d_%H%M%S")
DATE_DISPLAY=$(date -r "$UNIX_SECS" "+%Y-%m-%d %H:%M:%S" 2>/dev/null || date "+%Y-%m-%d %H:%M:%S")

BASE_NAME="session_${DATE_STR}"

if [ -n "$SESSION_ID" ]; then
    EVENTS_FILE="${HOME}/.copilot/session-state/${SESSION_ID}/events.jsonl"
    if [ -f "$EVENTS_FILE" ]; then
        cp "$EVENTS_FILE" "${DEST_DIR}/${BASE_NAME}.jsonl"

        if ! jq -rs \
          --arg date "$DATE_DISPLAY" \
          --arg session_id "$SESSION_ID" \
          '
          (map(select(.type == "session.start")) | first | .data.context.cwd // "") as $cwd |
          (map(select(.type == "session.shutdown")) | first) as $shutdown |
          ($shutdown.data.currentModel // "") as $model |
          ($shutdown.data.codeChanges.filesModified // []) as $changed_files |
          (map(select(.type == "user.message" and (.data.source == null or .data.source == "user")))
            | first | .data.content // "" | split("\n") | first // "") as $first_msg |
          ($first_msg | if length > 200 then .[0:200] + "..." else . end) as $description |

          "---\ndate: \"" + $date + "\"\nsession_id: \"" + $session_id + "\"\ndescription: " + ($description | tojson) + "\ndirectory: \"" + $cwd + "\"\nmodel: \"" + $model + "\"\n" +
          (if ($changed_files | length) > 0 then
            "changed_files:\n" + ($changed_files | map("  - " + .) | join("\n")) + "\n"
          else "changed_files: []\n" end) +
          "---\n\n",

          (.[] |
            if .type == "user.message" and (.data.source == null or .data.source == "user") then
              "## User\n\n" + .data.content + "\n\n---\n"

            elif .type == "assistant.message" and (.data.content // "") != "" and (.agentId == null) then
              "## Copilot\n\n" +
              .data.content + "\n\n---\n"

            else empty
            end
          )
          ' "$EVENTS_FILE" > "${DEST_DIR}/${BASE_NAME}.md" 2>/dev/null; then
          rm -f "${DEST_DIR}/${BASE_NAME}.md" "${DEST_DIR}/${BASE_NAME}.jsonl"
        fi
    fi
fi

exit 0
