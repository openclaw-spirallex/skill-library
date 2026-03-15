---
name: opennotebook
description: Control a self-hosted open-notebook instance (NotebookLM alternative) via the `onb` CLI or direct API calls. Use when user sends /opennotebook command or asks to manage notebooks, sources, notes, or perform search/RAG queries on their personal knowledge base. Supports: list/create/delete notebooks, add URL or file sources, show insights, list/create notes, semantic search, ask questions (RAG), check source processing status.
---

# OpenNotebook Skill

Manage [open-notebook](https://github.com/lfnovo/open-notebook) — a self-hosted NotebookLM alternative.

## Setup

### CLI (onb)
The `onb` CLI wraps the open-notebook REST API. Install once:

```bash
pip3 install click requests rich --break-system-packages -q
# onb lives at ~/scripts/onb (or wherever you placed it)
```

### Config
```bash
export OPEN_NOTEBOOK_URL=http://localhost:5055  # default
```

## Command Mapping

Parse args after `/opennotebook` and run the corresponding command:

| User input | CLI command |
|---|---|
| `list` / `notebooks` | `onb nb list` |
| `nb create <title>` | `onb nb create "<title>"` |
| `nb show <id>` | `onb nb show <id>` |
| `nb delete <id>` | `onb nb delete <id>` |
| `sources [--nb <id>]` | `onb src list [--notebook <id>]` |
| `src show <id>` | `onb src show <id>` |
| `src status <id>` | `onb src status <id>` |
| `insights <id>` | `onb src insights <id>` |
| `src delete <id>` | `onb src delete <id>` |
| `add url <url> [--nb <id>]` | `onb src add url "<url>" [--nb <id>]` |
| `add file <path> [--nb <id>]` | `onb src add file "<path>" [--nb <id>]` |
| `notes [--nb <id>]` | `onb note list [--notebook <id>]` |
| `note show <id>` | `onb note show <id>` |
| `note delete <id>` | `onb note delete <id>` |
| `search <query> [--nb <id>]` | `onb search "<query>" [--nb <id>]` |
| `ask <question> [--nb <id>]` | `onb ask "<question>" [--nb <id>]` |
| `status` | `curl -s $OPEN_NOTEBOOK_URL/health` |

## Direct API Fallback

If `onb` is unavailable, use curl directly:

```bash
BASE=http://localhost:5055

# List notebooks
curl -s $BASE/api/notebooks

# Add URL source
curl -s -X POST $BASE/api/sources \
  -H "Content-Type: application/json" \
  -d '{"content_state":{"url":"URL"},"notebook_ids":[],"transformations":[],"embed":true}'

# Ask a question (RAG)
curl -s -X POST $BASE/api/search/ask/simple \
  -H "Content-Type: application/json" \
  -d '{"question":"YOUR QUESTION"}'

# Semantic search
curl -s -X POST $BASE/api/search \
  -H "Content-Type: application/json" \
  -d '{"query":"YOUR QUERY"}'
```

## Output Formatting (Telegram)

Reformat `onb` rich table output as bullet lists:

**Notebooks:**
```
📚 Notebooks (2)
• notebook:abc123… — My Research
• notebook:def456… — ECG Study
```

**Sources:**
```
📄 Sources (3)
• source:hc5n4vjt… — Spirallex ECG V12.pdf [done]
• source:ce5q15bv… — Takens' Theorem [done]
```

**Ask/Search:** Return the answer directly; truncate at ~500 chars if needed.

**Insights:** Show each insight type + first ~300 chars.

## Notes
- IDs are SurrealDB format: `notebook:xyubmkn8u0m25mmpumz8` — copy full ID for operations
- Sources take time to process after adding — use `src status <id>` to poll
- `ask` uses RAG (retrieval-augmented generation) over all indexed sources
- Cloudflare Tunnel users: set `API_URL=https://your-domain.com` in docker-compose to avoid port 5055 exposure issues
