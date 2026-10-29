#!/usr/bin/env python3
"""Спайк: записывает вызов хука/notify как есть. Аргумент 1 — метка источника.

stdin (JSON хука) и argv (notify Codex передаёт JSON последним аргументом) + полезные
переменные окружения -> одна строка в $CAPRI_SPIKE_LOG (по умолчанию рядом со скриптом).
Всегда выходит с 0 и ничего не печатает в stdout, чтобы не влиять на сессию.
"""
import json, os, sys, time, socket
try:
    label = sys.argv[1] if len(sys.argv) > 1 else "?"
    raw = "" if sys.stdin.isatty() else sys.stdin.read()
    try:
        stdin = json.loads(raw) if raw.strip() else None
    except ValueError:
        stdin = raw
    argv = sys.argv[2:]
    parsed_argv = []
    for a in argv:
        try:
            parsed_argv.append(json.loads(a))
        except ValueError:
            parsed_argv.append(a)
    env = {k: v for k, v in os.environ.items()
           if k.startswith(("TMUX", "CLAUDE", "CODEX", "TERM_PROGRAM")) and "TOKEN" not in k and "KEY" not in k}
    rec = {"ts": time.time(), "host": socket.gethostname(), "label": label, "argv": parsed_argv,
           "stdin": stdin, "env": env, "ppid": os.getppid()}
    path = os.environ.get("CAPRI_SPIKE_LOG") or os.path.join(os.path.dirname(os.path.abspath(__file__)), "events.jsonl")
    with open(path, "a") as f:
        f.write(json.dumps(rec, ensure_ascii=False) + "\n")
except Exception:
    pass
sys.exit(0)
