#!/usr/bin/env python3
"""Фикстуры событий в формате capri-hook.

make_golden.py record <record.py-jsonl> <out.jsonl> <host>  — записи Этапа 0 через make_record
make_golden.py live <events.jsonl> <out.jsonl> <host>       — живой журнал capri-hook
Пути, имя хоста и email обезличиваются.
"""
import importlib.machinery, importlib.util, json, os, re, sys

HERE = os.path.dirname(os.path.abspath(__file__))
loader = importlib.machinery.SourceFileLoader("capri_hook", os.path.join(HERE, "capri-hook"))
spec = importlib.util.spec_from_loader("capri_hook", loader)
ch = importlib.util.module_from_spec(spec)
loader.exec_module(ch)

RULES = [(re.compile(r"/Users/timo\b"), "/Users/user"), (re.compile(r"/home/timofei\b"), "/home/user"),
         (re.compile(r"-Users-timo-"), "-Users-user-"), (re.compile(r"-home-timofei-"), "-home-user-"),
         (re.compile(r"MacBook-Pro-von-Timofei\.local"), "mac.local"), (re.compile(r"\btimoserver\b"), "server"),
         (re.compile(r"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[a-z]{2,}"), "user@example.com")]


def scrub(text):
    for rx, rep in RULES:
        text = rx.sub(rep, text)
    return text


def from_record(rec, host):
    agent, label = rec["label"].split(":", 1)
    env = rec.get("env") or {}
    ch.tmux_info = lambda: ({"pane": env["TMUX_PANE"], "session": "capri-test-" + agent, "window": "0"}
                            if env.get("TMUX_PANE") else None)
    if label == "notify":
        out = ch.make_record("codex", "notify", rec["argv"][0], now=rec["ts"])
    else:
        out = ch.make_record(agent, "hook", rec["stdin"], now=rec["ts"])
    out["host"] = host
    return out


def main(mode, src, dst, host):
    lines = []
    for line in open(src):
        rec = json.loads(line)
        if mode == "record":
            if rec.get("label") == "test":
                continue
            rec = from_record(rec, host)
        else:
            rec["host"] = host
        lines.append(scrub(json.dumps(rec, ensure_ascii=False, separators=(",", ":"))))
    os.makedirs(os.path.dirname(dst), exist_ok=True)
    open(dst, "w").write("\n".join(lines) + "\n")
    print(dst, len(lines))


if __name__ == "__main__":
    main(*sys.argv[1:5])
