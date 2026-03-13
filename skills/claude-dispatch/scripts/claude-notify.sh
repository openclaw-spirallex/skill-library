#!/bin/bash
# ============================================================
# claude-notify.sh — 任務完成後通知 Master
#
# Usage: claude-notify.sh <task-id> [direct|zero]
# ============================================================

TASK_ID="${1:?需要 task-id}"
NOTIFY_MODE="${2:-direct}"
TASKS_DIR="${HOME}/.claude-tasks"
TASK_DIR="$TASKS_DIR/$TASK_ID"
TELEGRAM_TARGET="6441309927"

[ -d "$TASK_DIR" ] || { echo "❌ 找不到任務目錄: $TASK_DIR"; exit 1; }

# ── 讀取任務資訊 ─────────────────────────────────────────────
read_manifest() {
    python3 -c "
import json
m = json.load(open('$TASK_DIR/manifest.json'))
print(m.get('$1', ''))
" 2>/dev/null
}

LABEL=$(read_manifest label)
STATUS=$(cat "$TASK_DIR/status" 2>/dev/null || echo "unknown")
EXIT_CODE=$(read_manifest exit_code)
DURATION=$(read_manifest duration_s)
MODEL=$(read_manifest model)
TASK_TEXT=$(read_manifest task)
OUTPUT_BYTES=$(read_manifest output_bytes)

# ── 讀取輸出（最後 800 字元，避免超長）────────────────────────
OUTPUT_PREVIEW=""
if [ -f "$TASK_DIR/output.txt" ]; then
    RAW_OUTPUT=$(cat "$TASK_DIR/output.txt")
    RAW_LEN=${#RAW_OUTPUT}
    if [ "$RAW_LEN" -gt 800 ]; then
        OUTPUT_PREVIEW="...(前略)...\n$(tail -c 800 "$TASK_DIR/output.txt")"
    else
        OUTPUT_PREVIEW="$RAW_OUTPUT"
    fi
fi

# ── 組合 Telegram 訊息 ────────────────────────────────────────
if [ "$STATUS" = "done" ]; then
    ICON="✅"
    STATUS_TEXT="完成"
else
    ICON="❌"
    STATUS_TEXT="失敗（exit $EXIT_CODE）"
fi

# 時長格式化
if [ -n "$DURATION" ] && [ "$DURATION" -gt 0 ] 2>/dev/null; then
    if [ "$DURATION" -ge 60 ]; then
        DURATION_STR="$((DURATION/60))m$((DURATION%60))s"
    else
        DURATION_STR="${DURATION}s"
    fi
else
    DURATION_STR="?"
fi

MESSAGE="${ICON} *Claude Code 任務${STATUS_TEXT}*

📋 *任務：* ${LABEL}
🤖 *模型：* ${MODEL}
⏱ *耗時：* ${DURATION_STR}
🆔 *ID：* \`${TASK_ID}\`"

if [ -n "$OUTPUT_PREVIEW" ]; then
    MESSAGE="${MESSAGE}

📄 *輸出：*
\`\`\`
${OUTPUT_PREVIEW}
\`\`\`"
else
    MESSAGE="${MESSAGE}

_(無輸出)_"
fi

MESSAGE="${MESSAGE}

查看完整結果：
\`dispatch.sh --logs ${TASK_ID}\`"

# ── 發送通知 ─────────────────────────────────────────────────
case "$NOTIFY_MODE" in
    direct)
        # 直接傳給 Master
        openclaw message send \
            --channel telegram \
            --target "$TELEGRAM_TARGET" \
            --message "$MESSAGE" \
            2>&1 || echo "⚠  openclaw message send 失敗"
        ;;

    zero)
        # 送給 ZERO 讓他處理後再傳 Master
        # ZERO 收到後會進行智慧摘要再回覆
        ZERO_MSG="[Claude Code 任務完成] ID=$TASK_ID | Status=$STATUS | Label=$LABEL | Duration=${DURATION_STR}

任務內容: ${TASK_TEXT}

輸出摘要:
${OUTPUT_PREVIEW}

請幫我整理重點後通知 Master。"

        openclaw agent \
            --channel telegram \
            --to "$TELEGRAM_TARGET" \
            --message "$ZERO_MSG" \
            --deliver \
            2>&1 || echo "⚠  openclaw agent 失敗"
        ;;
esac

echo "📬 通知已送出（mode=$NOTIFY_MODE）"
