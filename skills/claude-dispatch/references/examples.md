# Common Dispatch Patterns

## Fix a bug in a repo
```bash
dispatch.sh "找出並修復 src/auth.py 裡的 JWT expiry bug" \
  --dir ~/projects/myapp \
  --label "fix-jwt-bug" \
  --model sonnet
```

## Write tests
```bash
dispatch.sh "為 utils/ 下所有函式寫 pytest 單元測試，存到 tests/" \
  --dir ~/projects/myapp \
  --label "write-unit-tests" \
  --model opus \
  --budget 5.0
```

## Code review / audit
```bash
dispatch.sh "審查 src/ 的安全性問題，輸出 Markdown 報告到 SECURITY_AUDIT.md" \
  --dir ~/projects/myapp \
  --label "security-audit" \
  --model opus \
  --tools "Bash,Read,Glob,Grep"
```

## Refactor
```bash
dispatch.sh "把所有 callback 改成 async/await，保持功能不變" \
  --dir ~/projects/legacy \
  --label "async-refactor" \
  --budget 8.0
```

## Generate documentation
```bash
dispatch.sh "幫所有 public function 加 docstring，並生成 README.md" \
  --dir ~/projects/lib \
  --label "add-docs" \
  --silent
```

## Data processing / one-shot script
```bash
dispatch.sh "寫一個 Python 腳本把 data/input.csv 轉成 JSON，輸出到 data/output.json，然後執行它" \
  --dir ~/projects/data-pipeline \
  --label "csv-to-json"
```

## Notify through ZERO for long tasks (intelligent summarization)
```bash
dispatch.sh "分析整個 codebase 架構，輸出詳細設計文件" \
  --dir ~/projects/big-app \
  --label "architecture-analysis" \
  --model opus \
  --budget 15.0 \
  --notify-zero
```
