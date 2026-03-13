#!/usr/bin/env python3
"""
collect.py — 每日蒐集 clawhub skills，安全過濾後 commit 到本 repo

執行：python3 collect.py [--dry-run] [--limit N] [--sort newest|trending|downloads]
"""

import json
import os
import re
import subprocess
import sys
import textwrap
from datetime import datetime, timezone
from pathlib import Path

# ── 設定 ──────────────────────────────────────────────────────
REPO_DIR    = Path(__file__).parent.resolve()
SKILLS_DIR  = REPO_DIR / "skills"
STATE_FILE  = REPO_DIR / ".state.json"
CATALOG     = REPO_DIR / "catalog.json"
TELEGRAM_TARGET = "6441309927"

# 安全過濾規則（rule-based 預篩，0 token）
# script 內容若命中這些 pattern → 標記為 suspicious
SECURITY_PATTERNS = [
    # 資料外洩類
    (r'curl.*\$\{?(HOME|ANTHROPIC|OPENAI|API_KEY|SECRET|TOKEN|PASSWORD)', "credential exfil via curl"),
    (r'wget.*\$\{?(HOME|ANTHROPIC|OPENAI|API_KEY|SECRET|TOKEN|PASSWORD)', "credential exfil via wget"),
    (r'(cat|echo)\s+[~$].*\.(env|pem|key|p12|pfx|netrc|aws)', "secret file read"),
    (r'base64.*(\bsecret\b|\bpassword\b|\btoken\b|\bkey\b)', "base64 encoded secret"),
    # 破壞類
    (r'rm\s+-rf\s+[~/]', "destructive rm -rf"),
    (r'dd\s+if=/dev/\w+\s+of=', "disk write"),
    (r'mkfs\b', "filesystem format"),
    # 權限提升
    (r'\bsudo\b', "sudo usage"),
    (r'chmod\s+[0-7]*7[0-7]{2}\b', "world-executable chmod"),
    # 反向 shell
    (r'nc\s+.*-e\s+/bin', "reverse shell nc"),
    (r'/dev/tcp/', "bash /dev/tcp shell"),
    (r'python.*socket.*connect.*exec', "python socket shell"),
    # 自我傳播
    (r'git\s+(push|remote\s+set-url).*https?://.*@', "credential push"),
    (r'ssh-copy-id|\.ssh/authorized_keys', "ssh key injection"),
]

DRY_RUN = "--dry-run" in sys.argv

def run(cmd: list[str], check=True, capture=True) -> subprocess.CompletedProcess:
    return subprocess.run(cmd, capture_output=capture, text=True, check=check)

def load_state() -> dict:
    if STATE_FILE.exists():
        return json.loads(STATE_FILE.read_text())
    return {"seen_slugs": [], "last_run": None, "stats": {"collected": 0, "rejected": 0}}

def save_state(state: dict):
    STATE_FILE.write_text(json.dumps(state, indent=2, ensure_ascii=False))

def clawhub_explore(limit=100, sort="newest") -> list[dict]:
    r = run(["clawhub", "explore", "--json", "--limit", str(limit), "--sort", sort])
    data = json.loads(r.stdout)
    return data.get("items", data) if isinstance(data, dict) else data

def clawhub_inspect_files(slug: str) -> dict | None:
    r = run(["clawhub", "inspect", slug, "--files", "--json"], check=False)
    if r.returncode != 0:
        return None
    # strip leading line like "- Fetching skill"
    raw = r.stdout.strip()
    lines = raw.splitlines()
    json_start = next((i for i, l in enumerate(lines) if l.strip().startswith("{")), 0)
    return json.loads("\n".join(lines[json_start:]))

def clawhub_get_file(slug: str, path: str) -> str | None:
    r = run(["clawhub", "inspect", slug, "--file", path], check=False)
    if r.returncode != 0:
        return None
    raw = r.stdout
    # strip the "- Fetching skill / - Fetching file" header lines
    lines = raw.splitlines()
    content_start = next(
        (i for i, l in enumerate(lines)
         if not l.strip().startswith("-") and l.strip()),
        0
    )
    return "\n".join(lines[content_start:])

def security_check_content(content: str) -> list[str]:
    """Rule-based 安全掃描，回傳問題列表（空 = 安全）"""
    issues = []
    for pattern, label in SECURITY_PATTERNS:
        if re.search(pattern, content, re.IGNORECASE):
            issues.append(label)
    return issues

def security_verdict(inspect_data: dict, skill_files: dict[str, str]) -> tuple[bool, list[str]]:
    """
    組合 clawhub 官方 security status + rule-based 掃描
    回傳 (is_safe, reasons)
    """
    reasons = []

    # 1. clawhub 官方安全狀態
    version = inspect_data.get("version") or {}
    sec = version.get("security") or {}
    status = sec.get("status", "unknown")

    if status == "flagged":
        reasons.append(f"clawhub security: {status}")
        return False, reasons

    if status not in ("clean", "unknown"):
        reasons.append(f"clawhub security status: {status}")

    # 2. Rule-based 掃描所有 script 檔案
    for fpath, content in skill_files.items():
        if content is None:
            continue
        # 只掃 scripts/ 和 .sh/.py/.js 等可執行檔
        if not (fpath.startswith("scripts/") or
                any(fpath.endswith(ext) for ext in [".sh", ".py", ".js", ".rb", ".pl"])):
            continue
        issues = security_check_content(content)
        for issue in issues:
            reasons.append(f"{fpath}: {issue}")

    # sudo 在 SKILL.md 中只是說明用途（常見），不算問題
    # 只有在 scripts/ 中才算問題（已在上面過濾）

    is_safe = len(reasons) == 0
    return is_safe, reasons

def collect_skill(slug: str, meta: dict) -> tuple[str, str | None]:
    """
    蒐集單一 skill，回傳 ('ok'|'skipped'|'rejected', reason)
    """
    inspect = clawhub_inspect_files(slug)
    if not inspect:
        return "skipped", "inspect failed"

    version_info = inspect.get("version") or {}
    files_list = version_info.get("files", [])
    if not files_list:
        return "skipped", "no files"

    # 下載所有檔案
    skill_files: dict[str, str] = {}
    for f in files_list:
        content = clawhub_get_file(slug, f["path"])
        skill_files[f["path"]] = content

    # 安全審查
    is_safe, reasons = security_verdict(inspect, skill_files)
    if not is_safe:
        return "rejected", "; ".join(reasons)

    if DRY_RUN:
        return "ok", None

    # 寫入 repo
    skill_out = SKILLS_DIR / slug
    skill_out.mkdir(parents=True, exist_ok=True)

    for fpath, content in skill_files.items():
        if content is None:
            continue
        out_file = skill_out / fpath
        out_file.parent.mkdir(parents=True, exist_ok=True)
        out_file.write_text(content, encoding="utf-8")

    # 寫 meta.json
    owner = inspect.get("owner") or {}
    (skill_out / "meta.json").write_text(json.dumps({
        "slug":        slug,
        "displayName": meta.get("displayName", slug),
        "summary":     meta.get("summary", ""),
        "version":     version_info.get("version", ""),
        "author":      owner.get("handle", "unknown"),
        "downloads":   meta.get("stats", {}).get("downloads", 0),
        "stars":       meta.get("stats", {}).get("stars", 0),
        "updatedAt":   meta.get("updatedAt", 0),
        "collectedAt": datetime.now(timezone.utc).isoformat(),
        "hasWarnings": (version_info.get("security") or {}).get("hasWarnings", False),
    }, indent=2, ensure_ascii=False))

    return "ok", None

def update_readme(catalog_data: list[dict]):
    now = datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M UTC")
    lines = [
        "# Skill Library",
        "",
        f"> 自動蒐集自 [clawhub.com](https://clawhub.com)，每日 12:00 更新。",
        f"> 所有 skill 均經過安全審查，含惡意程式碼、憑證外洩風險者已過濾。",
        f"> 最後更新：**{now}**　共 **{len(catalog_data)}** 個 skills",
        "",
        "## Skills",
        "",
        "| Skill | 說明 | 版本 | 作者 | ⭐ | ↓ |",
        "|-------|------|------|------|----|---|",
    ]
    for s in sorted(catalog_data, key=lambda x: -x.get("stars", 0)):
        slug    = s["slug"]
        name    = s.get("displayName", slug)
        summary = s.get("summary", "")[:80].replace("|", "∣")
        ver     = s.get("version", "")
        author  = s.get("author", "")
        stars   = s.get("stars", 0)
        dls     = s.get("downloads", 0)
        warn    = " ⚠️" if s.get("hasWarnings") else ""
        lines.append(f"| [{name}](skills/{slug}){warn} | {summary} | {ver} | {author} | {stars} | {dls} |")

    (REPO_DIR / "README.md").write_text("\n".join(lines) + "\n", encoding="utf-8")

def send_telegram(msg: str):
    subprocess.run([
        "openclaw", "message", "send",
        "--channel", "telegram",
        "--target", TELEGRAM_TARGET,
        "--message", msg
    ], capture_output=True)

def main():
    limit = 100
    sort  = "newest"
    for i, arg in enumerate(sys.argv[1:]):
        if arg == "--limit" and i + 2 < len(sys.argv):
            limit = int(sys.argv[i + 2])
        if arg == "--sort" and i + 2 < len(sys.argv):
            sort = sys.argv[i + 2]

    print(f"[skill-collector] start  dry_run={DRY_RUN}  limit={limit}  sort={sort}")

    state = load_state()
    seen  = set(state.get("seen_slugs", []))

    # 取得最新 skill 列表
    items = clawhub_explore(limit=limit, sort=sort)
    new_items = [x for x in items if x["slug"] not in seen]
    print(f"  fetched={len(items)}  new={len(new_items)}")

    if not new_items:
        print("  → 今日無新 skill，結束")
        state["last_run"] = datetime.now(timezone.utc).isoformat()
        save_state(state)
        return

    SKILLS_DIR.mkdir(exist_ok=True)

    results = {"ok": [], "rejected": [], "skipped": []}

    for meta in new_items:
        slug = meta["slug"]
        print(f"  [{slug}] checking...")
        status, reason = collect_skill(slug, meta)
        results[status].append({"slug": slug, "reason": reason})
        seen.add(slug)
        if status == "ok":
            print(f"    ✅ collected")
        elif status == "rejected":
            print(f"    ❌ rejected: {reason}")
        else:
            print(f"    ⚠  skipped: {reason}")

    # 更新 catalog.json
    if not DRY_RUN:
        catalog_data = []
        for skill_dir in sorted(SKILLS_DIR.iterdir()):
            meta_file = skill_dir / "meta.json"
            if meta_file.exists():
                catalog_data.append(json.loads(meta_file.read_text()))
        CATALOG.write_text(json.dumps(catalog_data, indent=2, ensure_ascii=False))
        update_readme(catalog_data)

    # 儲存 state
    state["seen_slugs"]        = sorted(seen)
    state["last_run"]          = datetime.now(timezone.utc).isoformat()
    state["stats"]["collected"] = state["stats"].get("collected", 0) + len(results["ok"])
    state["stats"]["rejected"]  = state["stats"].get("rejected", 0) + len(results["rejected"])
    save_state(state)

    # Git commit + push
    if not DRY_RUN and results["ok"]:
        os.chdir(REPO_DIR)
        run(["git", "add", "-A"])
        commit_msg = (
            f"[auto] {datetime.now(timezone.utc).strftime('%Y-%m-%d')}: "
            f"+{len(results['ok'])} skills "
            f"({len(results['rejected'])} rejected)"
        )
        run(["git", "commit", "-m", commit_msg])
        run(["git", "push", "origin", "main"])
        print(f"  git push done: {commit_msg}")

    # Telegram 通知
    ok_names    = ", ".join(x["slug"] for x in results["ok"][:8])
    rej_details = "\n".join(f"  • {x['slug']}: {x['reason']}" for x in results["rejected"][:5])

    if results["ok"] or results["rejected"]:
        msg_lines = [
            f"📦 *Skill Library 今日更新*",
            f"",
            f"✅ 收錄：**{len(results['ok'])}** 個",
        ]
        if results["ok"]:
            msg_lines.append(f"   {ok_names}{'...' if len(results['ok']) > 8 else ''}")
        if results["rejected"]:
            msg_lines.append(f"\n❌ 過濾（安全疑慮）：**{len(results['rejected'])}** 個")
            if rej_details:
                msg_lines.append(rej_details)
        if results["skipped"]:
            msg_lines.append(f"⚠️ 略過：{len(results['skipped'])} 個")
        msg_lines.append(f"\nhttps://github.com/openclaw-spirallex/skill-library")
        send_telegram("\n".join(msg_lines))

    print(f"[skill-collector] done. ok={len(results['ok'])} rejected={len(results['rejected'])} skipped={len(results['skipped'])}")

if __name__ == "__main__":
    main()
