#!/usr/bin/env python3
"""微博 Cookie 管理工具

用法:
    python3 weibo_cookies.py save       # 从 stdin 读取 JSON cookie 数组并保存
    python3 weibo_cookies.py load       # 输出已保存的 cookie（JSON 格式）
    python3 weibo_cookies.py check      # 检查 cookie 是否有效（通过过期时间判断）
    python3 weibo_cookies.py export     # 导出为 openclaw browser cookies set 格式

Cookie 存储位置: ~/.openclaw/data/weibo/cookies.json
"""
import json, sys, os, time
from pathlib import Path

COOKIE_DIR = Path.home() / ".openclaw" / "data" / "weibo"
COOKIE_FILE = COOKIE_DIR / "cookies.json"
META_FILE = COOKIE_DIR / "meta.json"


def save_cookies(cookies_json: str):
    """保存 cookie 到文件"""
    COOKIE_DIR.mkdir(parents=True, exist_ok=True)
    cookies = json.loads(cookies_json) if isinstance(cookies_json, str) else cookies_json
    # 只保留微博相关的 cookie
    weibo_cookies = [c for c in cookies if any(d in c.get("domain", "") for d in ["weibo", "sina"])]
    with open(COOKIE_FILE, "w") as f:
        json.dump(weibo_cookies, f, indent=2, ensure_ascii=False)
    # 保存元信息
    meta = {
        "saved_at": time.strftime("%Y-%m-%d %H:%M:%S"),
        "saved_ts": int(time.time()),
        "cookie_count": len(weibo_cookies),
        "domains": list(set(c.get("domain", "") for c in weibo_cookies))
    }
    with open(META_FILE, "w") as f:
        json.dump(meta, f, indent=2, ensure_ascii=False)
    print(f"Saved {len(weibo_cookies)} cookies at {meta['saved_at']}")
    return True


def load_cookies():
    """加载已保存的 cookie"""
    if not COOKIE_FILE.exists():
        print(json.dumps({"error": "no_cookies", "message": "No saved cookies found. Please login first."}))
        return None
    with open(COOKIE_FILE) as f:
        cookies = json.load(f)
    # 检查是否有过期的 cookie
    now = int(time.time())
    expired = [c["name"] for c in cookies if c.get("expires", -1) > 0 and c["expires"] < now]
    if expired:
        print(json.dumps({"warning": "some_expired", "expired_names": expired}, ensure_ascii=False))
    else:
        print(json.dumps(cookies, indent=2, ensure_ascii=False))
    return cookies


def check_cookies():
    """检查 cookie 有效性"""
    if not COOKIE_FILE.exists():
        print(json.dumps({"valid": False, "reason": "no_cookies"}))
        return False
    with open(COOKIE_FILE) as f:
        cookies = json.load(f)
    # 检查关键 cookie 是否存在
    cookie_names = {c["name"] for c in cookies}
    key_cookies = ["SUB", "SUBP"]
    missing = [k for k in key_cookies if k not in cookie_names]
    if missing:
        print(json.dumps({"valid": False, "reason": "missing_key_cookies", "missing": missing}))
        return False
    # 检查过期
    now = int(time.time())
    sub_cookie = next((c for c in cookies if c["name"] == "SUB"), None)
    if sub_cookie and sub_cookie.get("expires", -1) > 0:
        remaining = sub_cookie["expires"] - now
        hours_left = remaining / 3600
        if remaining < 0:
            print(json.dumps({"valid": False, "reason": "expired", "expired_since_hours": abs(hours_left)}))
            return False
        print(json.dumps({"valid": True, "hours_remaining": round(hours_left, 1), "expires_at": time.strftime("%Y-%m-%d %H:%M:%S", time.localtime(sub_cookie["expires"]))}))
        return True
    # 没有过期时间的情况（session cookie）
    if META_FILE.exists():
        with open(META_FILE) as f:
            meta = json.load(f)
        age_hours = (now - meta.get("saved_ts", now)) / 3600
        print(json.dumps({"valid": True, "type": "session", "age_hours": round(age_hours, 1), "saved_at": meta.get("saved_at", "unknown")}))
    else:
        print(json.dumps({"valid": True, "type": "unknown"}))
    return True


def export_for_openclaw():
    """输出可用于 openclaw browser cookies set 的格式"""
    if not COOKIE_FILE.exists():
        print("ERROR: No saved cookies")
        return
    with open(COOKIE_FILE) as f:
        cookies = json.load(f)
    for c in cookies:
        parts = [f"--name {c['name']}", f"--value '{c['value']}'"]
        if c.get("domain"): parts.append(f"--domain {c['domain']}")
        if c.get("path"): parts.append(f"--path {c['path']}")
        if c.get("secure"): parts.append("--secure")
        if c.get("httpOnly"): parts.append("--httponly")
        print("openclaw browser cookies set " + " ".join(parts))


if __name__ == "__main__":
    if len(sys.argv) < 2:
        print(__doc__)
        sys.exit(1)
    cmd = sys.argv[1]
    if cmd == "save":
        data = sys.stdin.read()
        save_cookies(data)
    elif cmd == "load":
        load_cookies()
    elif cmd == "check":
        check_cookies()
    elif cmd == "export":
        export_for_openclaw()
    else:
        print(f"Unknown command: {cmd}")
        sys.exit(1)
