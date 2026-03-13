#!/bin/bash
# ============================================================
# dispatch.sh — 把任務派給 Claude Code，完成後通知 ZERO → Telegram
#
# 模式：
#   預設        claude --print（背景靜默執行，完成通知）
#   --tmux      claude 互動模式，開 tmux session，可 attach 觀看
#   --tmux-attach 同上，並立即 attach 進去
#
# Usage:
#   dispatch.sh "任務"
#   dispatch.sh "任務" --tmux                     # tmux 模式，背景跑
#   dispatch.sh "任務" --tmux-attach              # tmux 模式，立即進去
#   dispatch.sh "任務" --dir /path --model opus
#   dispatch.sh --list / --status <id> / --logs <id> / --kill <id>
#   dispatch.sh --attach <id>                    # attach 到 tmux 任務
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
       dispatch.sh --logs   <task-id>
       dispatch.sh --kill   <task-id>
       dispatch.sh --attach <task-id>

Modes:
  (預設)         --print 模式，背景靜默跑，完成才通知
  --tmux         互動模式，開 tmux session，完成通知
  --tmux-attach  互動模式，開 tmux session 並立即 attach

Options:
  --dir <path>       工作目錄（預設當前目錄）
  --label <name>     任務標籤
  --model <model>    sonnet / opus（預設 sonnet）
  --budget <usd>     最大花費上限（預設 2.0）
  --tools <list>     允許的工具（預設：Bash,Edit,Read,Write,Glob,Grep）
  --notify-zero      通知走 ZERO 處理後再傳 Master
  --silent           不傳通知
EOF
    exit 1
}

list_tasks() {
    echo ""
    printf "%-10s %-12s %-6s %-8s %-20s %s\n" "ID" "STATUS" "MODE" "MODEL" "STARTED" "LABEL"
    echo "──────────────────────────────────────────────────────────────────────"
    for d in "$TASKS_DIR"/*/; do
        [ -f "$d/manifest.json" ] || continue
        local id status mode model started label
        id=$(basename "$d")
        status=$(cat "$d/status" 2>/dev/null || echo "?")
        mode=$(python3 -c "import json; d=json.load(open('$d/manifest.json')); print(d.get('mode','print'))" 2>/dev/null || echo "?")
        model=$(python3 -c "import json; d=json.load(open('$d/manifest.json')); print(d.get('model','?'))" 2>/dev/null || echo "?")
        started=$(python3 -c "import json; d=json.load(open('$d/manifest.json')); print(d.get('started_at','?')[:19])" 2>/dev/null || echo "?")
        label=$(python3 -c "import json; d=json.load(open('$d/manifest.json')); print(d.get('label','(no label)'))" 2>/dev/null || echo "?")
        # tmux 任務顯示 session 是否還在跑
        if [ "$mode" = "tmux" ] && [ "$status" = "running" ]; then
            tmux has-session -t "claude-$id" 2>/dev/null && status="running(tmux)" || status="done"
        fi
        printf "%-10s %-12s %-6s %-8s %-20s %s\n" "$id" "$status" "$mode" "$model" "$started" "$label"
    done
    echo ""
}

show_status() {
    local id="$1"
    local dir="$TASKS_DIR/$id"
    [ -d "$dir" ] || { echo "❌ 找不到任務 $id"; exit 1; }
    python3 << PYEOF
import json, os, subprocess
manifest = json.load(open('$dir/manifest.json'))
status = open('$dir/status').read().strip()
mode = manifest.get('mode', 'print')

# tmux 任務：動態偵測是否還在跑
if mode == 'tmux' and status == 'running':
    r = subprocess.run(['tmux','has-session','-t',f'claude-$id'], capture_output=True)
    if r.returncode != 0:
        status = 'done (tmux session ended)'

print(f"Task ID:   {manifest['id']}")
print(f"Label:     {manifest.get('label', '(none)')}")
print(f"Mode:      {mode}")
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
if mode == 'tmux':
    print(f"\nAttach: tmux attach -t claude-$id")
elif os.path.exists('$dir/output.txt'):
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
NOTIFY_MODE="direct"
TOOLS="Bash,Edit,Read,Write,Glob,Grep"
MODE="print"       # print | tmux

case "${1:-}" in
    --list) list_tasks; exit 0 ;;
    --status) show_status "${2:?需要 task id}"; exit 0 ;;
    --logs)
        ID="${2:?需要 task id}"
        cat "$TASKS_DIR/$ID/output.txt" 2>/dev/null || echo "❌ 找不到輸出（tmux 模式無輸出檔）"
        exit 0 ;;
    --attach)
        ID="${2:?需要 task id}"
        SESS="claude-$ID"
        tmux has-session -t "$SESS" 2>/dev/null \
            && exec tmux attach -t "$SESS" \
            || echo "❌ tmux session '$SESS' 不存在（任務已結束）"
        exit 0 ;;
    --kill)
        ID="${2:?需要 task id}"
        TASK_DIR_K="$TASKS_DIR/$ID"
        # 殺 background watcher
        [ -f "$TASK_DIR_K/pid" ] && kill "$(cat "$TASK_DIR_K/pid")" 2>/dev/null || true
        # 殺 tmux session
        tmux kill-session -t "claude-$ID" 2>/dev/null || true
        echo "killed" > "$TASK_DIR_K/status"
        echo "✅ 已停止任務 $ID"
        exit 0 ;;
    -h|--help) usage ;;
    "") usage ;;
    *) TASK="$1"; shift ;;
esac

while [[ $# -gt 0 ]]; do
    case $1 in
        --dir)           WORKDIR="$2";       shift 2 ;;
        --label)         LABEL="$2";         shift 2 ;;
        --model)         MODEL="$2";         shift 2 ;;
        --budget)        BUDGET="$2";        shift 2 ;;
        --notify-zero)   NOTIFY_MODE="zero"; shift ;;
        --silent)        NOTIFY_MODE="silent"; shift ;;
        --tools)         TOOLS="$2";         shift 2 ;;
        --tmux)          MODE="tmux";        shift ;;
        --tmux-attach)   MODE="tmux-attach"; shift ;;
        *) echo "未知參數: $1"; usage ;;
    esac
done

[ -z "$TASK" ] && usage
[ -z "$LABEL" ] && LABEL="$(echo "$TASK" | cut -c1-40)"

# ── 建立任務目錄 ──────────────────────────────────────────────
TASK_ID="$(date +%s | tail -c 6)$(openssl rand -hex 2)"
TASK_DIR="$TASKS_DIR/$TASK_ID"
TMUX_SESSION="claude-$TASK_ID"
mkdir -p "$TASK_DIR"

STARTED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

python3 << PYEOF
import json
manifest = {
    "id":         "$TASK_ID",
    "label":      "$LABEL",
    "task":       """$TASK""",
    "model":      "$MODEL",
    "mode":       "tmux" if "$MODE".startswith("tmux") else "print",
    "workdir":    "$WORKDIR",
    "started_at": "$STARTED_AT",
    "notify":     "$NOTIFY_MODE",
    "tools":      "$TOOLS",
    "tmux_session": "$TMUX_SESSION" if "$MODE".startswith("tmux") else None,
}
json.dump(manifest, open('$TASK_DIR/manifest.json', 'w'), indent=2, ensure_ascii=False)
PYEOF

echo "running" > "$TASK_DIR/status"

# ══════════════════════════════════════════════════════════════
# MODE: print（原本的背景靜默模式）
# ══════════════════════════════════════════════════════════════
if [ "$MODE" = "print" ]; then
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

        python3 << PYEOF
import json
m = json.load(open('$TASK_DIR/manifest.json'))
m['exit_code']    = $EXIT_CODE
m['duration_s']   = $DURATION
m['finished_at']  = "$FINISHED_AT"
m['output_bytes'] = $(wc -c < "$TASK_DIR/output.txt" 2>/dev/null || echo 0)
json.dump(m, open('$TASK_DIR/manifest.json', 'w'), indent=2, ensure_ascii=False)
PYEOF

        [ $EXIT_CODE -eq 0 ] && echo "done" > "$TASK_DIR/status" || echo "failed" > "$TASK_DIR/status"
        [ "$NOTIFY_MODE" != "silent" ] && "$NOTIFY_SCRIPT" "$TASK_ID" "$NOTIFY_MODE"
    ) &

    BGPID=$!
    echo "$BGPID" > "$TASK_DIR/pid"

    echo ""
    echo "✅ 任務已派出（print 模式）"
    echo "   ID:    $TASK_ID"
    echo "   Label: $LABEL"
    echo "   Model: $MODEL"
    echo ""
    echo "   dispatch.sh --status $TASK_ID"
    echo "   dispatch.sh --logs   $TASK_ID"

# ══════════════════════════════════════════════════════════════
# MODE: tmux / tmux-attach（互動模式，開 tmux session）
# ══════════════════════════════════════════════════════════════
else
    # 建立 detached tmux session
    tmux new-session -d -s "$TMUX_SESSION" -x 220 -y 50

    # 寫入任務啟動腳本（在 tmux 內執行）
    RUNNER="$TASK_DIR/tmux-runner.sh"
    cat > "$RUNNER" << RUNNER_EOF
#!/bin/bash
cd "$WORKDIR"
echo "╔══════════════════════════════════════════════════════╗"
echo "║  Claude Dispatch — tmux mode                        ║"
echo "║  Task: $(echo "$LABEL" | cut -c1-50)$([ ${#LABEL} -gt 50 ] && echo "...")                 ║"
echo "║  ID:   $TASK_ID                                     ║"
echo "╚══════════════════════════════════════════════════════╝"
echo ""

claude \
    --model "$MODEL" \
    --max-budget-usd "$BUDGET" \
    --allowedTools "$TOOLS" \
    --permission-mode acceptEdits \
    "$TASK"
EXIT_CODE=\$?

echo ""
echo "═══════════════════════════════════════════"
echo "  Claude 已結束（exit code: \$EXIT_CODE）"
echo "  按任意鍵關閉此視窗..."
echo "═══════════════════════════════════════════"
read -n1 -s
RUNNER_EOF
    chmod +x "$RUNNER"

    # 在 tmux 裡執行 runner
    tmux send-keys -t "$TMUX_SESSION" "bash '$RUNNER'; tmux kill-session -t $TMUX_SESSION" Enter

    # 背景監控：等 tmux session 結束後更新狀態 + 通知
    (
        START_TS=$SECONDS
        # 等 tmux session 消失
        while tmux has-session -t "$TMUX_SESSION" 2>/dev/null; do
            sleep 3
        done
        DURATION=$((SECONDS - START_TS))
        FINISHED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

        python3 << PYEOF
import json
m = json.load(open('$TASK_DIR/manifest.json'))
m['duration_s']  = $DURATION
m['finished_at'] = "$FINISHED_AT"
json.dump(m, open('$TASK_DIR/manifest.json', 'w'), indent=2, ensure_ascii=False)
PYEOF

        echo "done" > "$TASK_DIR/status"
        [ "$NOTIFY_MODE" != "silent" ] && "$NOTIFY_SCRIPT" "$TASK_ID" "$NOTIFY_MODE"
    ) &

    BGPID=$!
    echo "$BGPID" > "$TASK_DIR/pid"

    echo ""
    echo "✅ 任務已派出（tmux 模式）"
    echo "   ID:      $TASK_ID"
    echo "   Session: $TMUX_SESSION"
    echo "   Label:   $LABEL"
    echo "   Model:   $MODEL"
    echo ""
    echo "   進入觀看："
    echo "   tmux attach -t $TMUX_SESSION"
    echo "   dispatch.sh --attach $TASK_ID"
    echo ""
    echo "   完成後自動 Telegram 通知"

    # tmux-attach 模式：直接 attach
    if [ "$MODE" = "tmux-attach" ]; then
        exec tmux attach -t "$TMUX_SESSION"
    fi
fi
