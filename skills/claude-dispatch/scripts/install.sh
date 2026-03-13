#!/bin/bash
# install.sh — 安裝 claude-dispatch 到 ~/scripts/
set -e

SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TARGET_DIR="$HOME/scripts"

mkdir -p "$TARGET_DIR" ~/.claude-tasks

cp "$SKILL_DIR/scripts/dispatch.sh"     "$TARGET_DIR/dispatch.sh"
cp "$SKILL_DIR/scripts/claude-notify.sh" "$TARGET_DIR/claude-notify.sh"
chmod +x "$TARGET_DIR/dispatch.sh" "$TARGET_DIR/claude-notify.sh"

# 加到 PATH（若尚未加入）
SHELL_RC="$HOME/.zshrc"
if ! grep -q 'HOME/scripts' "$SHELL_RC" 2>/dev/null; then
    echo 'export PATH="$HOME/scripts:$PATH"' >> "$SHELL_RC"
    echo "✅ 已加入 PATH → $SHELL_RC"
fi

echo "✅ 安裝完成"
echo "   dispatch.sh      → $TARGET_DIR/dispatch.sh"
echo "   claude-notify.sh → $TARGET_DIR/claude-notify.sh"
echo "   任務目錄         → ~/.claude-tasks/"
echo ""
echo "Run: dispatch.sh --help"
