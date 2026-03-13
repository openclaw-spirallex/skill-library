#!/bin/bash
# ============================================================
# dispatch.sh — 把任務派給 Claude Code，完成後通知 ZERO → Telegram
#
# Usage:
#   dispatch.sh "幫我寫一個 fizzbuzz in Rust"
#   dispatch.sh "重構這個目錄" --dir /path/to/project
#   dispatch.sh "幫我寫測試" --dir ./myapp --label "write-tests" --model opus
#   dispatch.sh --list         # 查看所有任務狀態
#   dispatch.sh --status <id>  # 查看特定任務
# ============================================================

set -e

SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TASKS_DIR="${HOME}/.claude-tasks"
NOTIFY_SCRIPT="${SCRIPTS_DIR}/claude-notify.sh"
TELEGRAM_TARGET="6441309927"

mkdir -p "$TASKS_DIR"

# ── helpers ──────────────────────────────────────────────────
usage() {
    cat << EOF
Usage: dispatch.sh <task> [options]
       dispatch.sh --list
       dispatch.sh --status <task-id>
       dispatch.sh --logs <task-id>
       dispatch.sh --kill <task-id>

Options:
  --dir <path>       工作目錄（預設當前目錄）
  --label <name>     任務標籤（用於通知顯示）
  --model <model>    Claude 模型（sonnet/opus，預設 sonnet）
  --budget <usd>     最大花費上限（USD，預設 2.0）
  --notify-zero      通知走 ZERO 處理後再傳 Master（預設：直接傳 Telegram）
  --silent           只存結果，不傳通知
  --tools <tools>    允許的工具（預設：Bash,Edit,Read,Write,Glob,Grep）
EOF
    exit 1
}

task_status() {
    local id="$1"
    local dir="$TASKS_DIR/$id"
    [ -f "$dir/status" ] && cat "$dir/status" || echo "unknown"
}

list_tasks() {
    echo ""
    printf "%-10s %-12s %-8s %-20s %s\n" "ID" "STATUS" "MODEL" "STARTED" "LABEL"
    echo "────────────────────────────────────────────────────────────────"
    for d in "$TASKS_DIR"/*/; do
        [ -f "$d/manifest.json" ] || continue
        local id status model started label
        id=$(basename "$d")
        status=$(cat "$d/status" 2>/dev/null || echo "?")
        model=$(python3 -c "import json; d=json.load(open('$d/manifest.json')); print(d.get('model','?'))" 2>/dev/null || echo "?")
        started=$(python3 -c "import json; d=json.load(open('$d/manifest.json')); print(d.get('started_at','?')[:19])" 2>/dev/null || echo "?")
        label=$(python3 -c "import json; d=json.load(open('$d/manifest.json')); print(d.get('label','(no label)'))" 2>/dev/null || echo "?")
        printf "%-10s %-12s %-8s %-20s %s\n" "$id" "$status" "$model" "$started" "$label"
    done
    echo ""
}

show_status() {
    local id="$1"
    local dir="$TASKS_DIR/$id"
    [ -d "$dir" ] || { echo "❌ 找不到任務 $id"; exit 1; }
    python3 << PYEOF
import json, os
manifest = json.load(open('$dir/manifest.json'))
status = open('$dir/status').read().strip()
print(f"Task ID:   {manifest['id']}")
print(f"Label:     {manifest.get('label', '(none)')}")
print(f"Status:    {status}")
print(f"Model:     {manifest['model']}")
print(f"Dir:       {manifest['workdir']}")
print(f"Started:   {manifest['started_at']}")
if 'finished_at' in manifest:
    print(f"Finished:  {manifest['finished_at']}")
if 'duration_s' in manifest:
    print(f"Duration:  {manifest['duration_s']}s")
if 'exit_code' in manifest:
    print(f"Exit code: {manifest['exit_code']}")
task = manifest.get('task','')
print(f"\nTask:\n  {task[:200]}{'...' if len(task)>200 else ''}")
if os.path.exists('$dir/output.txt'):
    output = open('$dir/output.txt').read()
    print(f"\nOutput preview:\n{output[:500]}{'...' if len(output)>500 else ''}")
PYEOF
}

# ── parse args ────────────────────────────────────────────────
TASK=""
WORKDIR="$(pwd)"
LABEL=""
MODEL="sonnet"
BUDGET="2.0"
NOTIFY_MODE="direct"    # direct | zero | silent
TOOLS="Bash,Edit,Read,Write,Glob,Grep"

case "${1:-}" in
    --list) list_tasks; exit 0 ;;
    --status) show_status "${2:?需要 task id}"; exit 0 ;;
    --logs)
        ID="${2:?需要 task id}"
        cat "$TASKS_DIR/$ID/output.txt" 2>/dev/null || echo "❌ 找不到輸出"
        exit 0 ;;
    --kill)
        ID="${2:?需要 task id}"
        if [ -f "$TASKS_DIR/$ID/pid" ]; then
            PID=$(cat "$TASKS_DIR/$ID/pid")
            kill "$PID" 2>/dev/null && echo "✅ 已停止 PID $PID" || echo "⚠  進程不存在"
            echo "killed" > "$TASKS_DIR/$ID/status"
        fi
        exit 0 ;;
    -h|--help) usage ;;
    "") usage ;;
    *) TASK="$1"; shift ;;
esac

while [[ $# -gt 0 ]]; do
    case $1 in
        --dir)          WORKDIR="$2";      shift 2 ;;
        --label)        LABEL="$2";        shift 2 ;;
        --model)        MODEL="$2";        shift 2 ;;
        --budget)       BUDGET="$2";       shift 2 ;;
        --notify-zero)  NOTIFY_MODE="zero"; shift ;;
        --silent)       NOTIFY_MODE="silent"; shift ;;
        --tools)        TOOLS="$2";        shift 2 ;;
        *) echo "未知參數: $1"; usage ;;
    esac
done

[ -z "$TASK" ] && usage
[ -z "$LABEL" ] && LABEL="$(echo "$TASK" | cut -c1-40)"

# ── 建立任務目錄 ──────────────────────────────────────────────
TASK_ID="$(date +%s | tail -c 6)$(openssl rand -hex 2)"
TASK_DIR="$TASKS_DIR/$TASK_ID"
mkdir -p "$TASK_DIR"

STARTED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

python3 << PYEOF
import json
manifest = {
    "id":         "$TASK_ID",
    "label":      "$LABEL",
    "task":       """$TASK""",
    "model":      "$MODEL",
    "workdir":    "$WORKDIR",
    "started_at": "$STARTED_AT",
    "notify":     "$NOTIFY_MODE",
    "tools":      "$TOOLS",
}
json.dump(manifest, open('$TASK_DIR/manifest.json', 'w'), indent=2, ensure_ascii=False)
PYEOF

echo "running" > "$TASK_DIR/status"

# ── 背景執行 claude ───────────────────────────────────────────
(
    START_TS=$SECONDS
    cd "$WORKDIR"

    claude \
        --print \
        --model "$MODEL" \
        --max-budget-usd "$BUDGET" \
        --allowed-tools "$TOOLS" \
        --dangerously-skip-permissions \
        "$TASK" \
        > "$TASK_DIR/output.txt" 2>&1
    EXIT_CODE=$?

    DURATION=$((SECONDS - START_TS))
    FINISHED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

    # 更新 manifest
    python3 << PYEOF
import json
m = json.load(open('$TASK_DIR/manifest.json'))
m['exit_code']    = $EXIT_CODE
m['duration_s']   = $DURATION
m['finished_at']  = "$FINISHED_AT"
m['output_bytes'] = $(wc -c < "$TASK_DIR/output.txt" 2>/dev/null || echo 0)
json.dump(m, open('$TASK_DIR/manifest.json', 'w'), indent=2, ensure_ascii=False)
PYEOF

    if [ $EXIT_CODE -eq 0 ]; then
        echo "done" > "$TASK_DIR/status"
    else
        echo "failed" > "$TASK_DIR/status"
    fi

    # 通知
    if [ "$NOTIFY_MODE" != "silent" ]; then
        "$NOTIFY_SCRIPT" "$TASK_ID" "$NOTIFY_MODE"
    fi
) &

BGPID=$!
echo "$BGPID" > "$TASK_DIR/pid"

echo ""
echo "✅ 任務已派出"
echo "   ID:    $TASK_ID"
echo "   Label: $LABEL"
echo "   Model: $MODEL"
echo "   Dir:   $WORKDIR"
echo ""
echo "查看進度："
echo "   dispatch.sh --status $TASK_ID"
echo "   dispatch.sh --logs   $TASK_ID"
