---
name: claude-dispatch
description: Dispatch coding or shell tasks to Claude Code CLI in the background, then notify Master via Telegram when done. Use when Master asks to delegate a task to Claude Code, run Claude Code on a project/directory, have Claude Code work autonomously and report back, or queue background AI coding work. NOT for simple one-liner fixes (just edit directly) or tasks that need interactive back-and-forth.
---

# Claude Dispatch

Dispatch tasks to Claude Code (`claude --print`) as background jobs.
On completion, results are sent to Master via Telegram automatically.

## Setup (first time only)

```bash
bash ~/.openclaw/workspace/skills/claude-dispatch/scripts/install.sh
```

This installs `dispatch.sh` and `claude-notify.sh` to `~/scripts/` and creates `~/.claude-tasks/`.

## Dispatching a Task

```bash
dispatch.sh "<task description>" [options]
```

**Key options:**
| Flag | Default | Description |
|------|---------|-------------|
| `--dir <path>` | cwd | Working directory for Claude Code |
| `--label <name>` | first 40 chars | Label shown in notification |
| `--model <model>` | sonnet | `sonnet` or `opus` |
| `--budget <usd>` | 2.0 | Max spend cap in USD |
| `--notify-zero` | off | Route notification through ZERO for summarization |
| `--silent` | off | Don't send any Telegram notification |
| `--tools <list>` | Bash,Edit,Read,Write,Glob,Grep | Allowed tools (comma-separated) |

## Task Management

```bash
dispatch.sh --list               # all tasks + status
dispatch.sh --status <id>        # details + output preview
dispatch.sh --logs <id>          # full output
dispatch.sh --kill <id>          # stop running task
```

## Notification Modes

- **direct** (default): Sends formatted Telegram message to Master immediately on completion
- **--notify-zero**: Routes through ZERO agent for intelligent summarization first
- **--silent**: Stores result locally, no notification

## Workflow

1. Read SKILL.md
2. Run `install.sh` if `dispatch.sh` is not yet in `~/scripts/`
3. Construct the `dispatch.sh` command based on Master's request
4. Run it and report the task ID back to Master
5. Claude Code runs in background — Master gets Telegram notification when done

## Task Data Location

All task state stored in `~/.claude-tasks/<task-id>/`:
- `manifest.json` — metadata (label, model, timing, exit code)
- `output.txt` — full Claude Code output
- `status` — `running` | `done` | `failed` | `killed`
- `pid` — background process PID

## Reference

See `references/examples.md` for common dispatch patterns.
