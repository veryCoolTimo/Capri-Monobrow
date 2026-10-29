#!/usr/bin/env python3
"""Превращает сырые записи record.py в обезличенные фикстуры.

make-fixtures.py <events.jsonl> <screens-dir> <out-dir> <host-alias>
Пишет <out>/<agent>-<host>.jsonl и <out>/screens/<host>-<name>.txt.
"""
import json, os, re, sys

src, screens, out, alias = sys.argv[1:5]
KEEP_ENV = {"TMUX", "TMUX_PANE", "CLAUDE_CODE_SESSION_ID", "CLAUDE_PROJECT_DIR", "TERM_PROGRAM"}
RULES = [
    (re.compile(r"/Users/timo\b"), "/Users/user"),
    (re.compile(r"/home/timofei\b"), "/home/user"),
    (re.compile(r"-Users-timo-"), "-Users-user-"),
    (re.compile(r"-home-timofei-"), "-home-user-"),
    (re.compile(r"MacBook-Pro-von-Timofei\.local"), "mac.local"),
    (re.compile(r"\btimoserver\b"), "server"),
    (re.compile(r"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[a-z]{2,}"), "user@example.com"),
]

def scrub(text):
    for rx, rep in RULES:
        text = rx.sub(rep, text)
    return text

os.makedirs(os.path.join(out, "screens"), exist_ok=True)
by_agent = {}
for line in open(src):
    r = json.loads(line)
    if r["label"] == "test":
        continue
    r["env"] = {k: v for k, v in r.get("env", {}).items() if k in KEEP_ENV}
    r.pop("ppid", None)
    r["host"] = alias
    agent = r["label"].split(":")[0]
    by_agent.setdefault(agent, []).append(scrub(json.dumps(r, ensure_ascii=False)))
for agent, lines in by_agent.items():
    with open(os.path.join(out, f"{agent}-{alias}.jsonl"), "w") as f:
        f.write("\n".join(lines) + "\n")
    print(agent, len(lines))
for name in sorted(os.listdir(screens)):
    text = scrub(open(os.path.join(screens, name)).read()).rstrip() + "\n"
    open(os.path.join(out, "screens", f"{alias}-{name}"), "w").write(text)
