#!/usr/bin/env python3
"""Спайк: codex app-server по stdio JSON-RPC.

initialize -> account/read -> account/rateLimits/read -> thread/start (ephemeral)
-> turn/start с коротким промптом -> ждём turn/completed.
Весь обмен пишется в JSONL (--log). auth.json не читаем: аккаунт только через API.
"""
import argparse, json, os, subprocess, sys, threading, time, queue

p = argparse.ArgumentParser()
p.add_argument("--codex", default="codex")
p.add_argument("--log", default="/tmp/capri-app-server.jsonl")
p.add_argument("--prompt", default="Reply with exactly one word: pong")
p.add_argument("--no-turn", action="store_true")
p.add_argument("--model", default=None, help="по умолчанию — первая модель из model/list с isDefault")
p.add_argument("--timeout", type=float, default=120)
args = p.parse_args()

proc = subprocess.Popen([args.codex, "app-server"], stdin=subprocess.PIPE,
                        stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, bufsize=1)
log = open(args.log, "w")
inbox = queue.Queue()
t0 = time.time()

def record(direction, msg):
    log.write(json.dumps({"t": round(time.time() - t0, 3), "dir": direction, "msg": msg}, ensure_ascii=False) + "\n")
    log.flush()

def reader():
    for line in proc.stdout:
        line = line.strip()
        if not line:
            continue
        try:
            msg = json.loads(line)
        except ValueError:
            record("in-raw", line); continue
        record("in", msg)
        inbox.put(msg)
    inbox.put(None)

def stderr_reader():
    for line in proc.stderr:
        record("stderr", line.rstrip())

threading.Thread(target=reader, daemon=True).start()
threading.Thread(target=stderr_reader, daemon=True).start()

next_id = 0
def send(method, params=None, notify=False):
    global next_id
    msg = {"method": method}
    if params is not None:
        msg["params"] = params
    if not notify:
        next_id += 1
        msg["id"] = next_id
    record("out", msg)
    proc.stdin.write(json.dumps(msg) + "\n"); proc.stdin.flush()
    return msg.get("id")

notifications = []
def wait_for(pred, timeout):
    deadline = time.time() + timeout
    while time.time() < deadline:
        try:
            m = inbox.get(timeout=max(0.1, deadline - time.time()))
        except queue.Empty:
            break
        if m is None:
            raise SystemExit("app-server закрыл stdout")
        if "id" in m and "method" in m:   # запрос сервера (approval и т.п.) — отказываем
            print("server request:", m["method"]); 
            resp = {"id": m["id"], "result": {"decision": "decline"}}
            record("out", resp); proc.stdin.write(json.dumps(resp) + "\n"); proc.stdin.flush()
            continue
        if "method" in m:
            notifications.append(m["method"])
        if pred(m):
            return m
    raise SystemExit(f"timeout; notifications so far: {notifications}")

def call(method, params=None, timeout=30):
    rid = send(method, params)
    t = time.time()
    m = wait_for(lambda m: m.get("id") == rid and "method" not in m, timeout)
    print(f"{method}: {round((time.time()-t)*1000)} ms", "ERROR " + json.dumps(m["error"]) if "error" in m else "")
    return m.get("result")

init = call("initialize", {"clientInfo": {"name": "capri_spike", "title": "Capri spike", "version": "0.0.1"},
                           "capabilities": {"experimentalApi": False, "requestAttestation": False}})
print("initialize ->", json.dumps(init)[:300])
send("initialized", notify=True)
acct = call("account/read", {"refreshToken": False})
a = (acct or {}).get("account") or {}
print("account ->", a.get("type"), a.get("planType"), "email set" if a.get("email") else "no email",
      "requiresOpenaiAuth=", (acct or {}).get("requiresOpenaiAuth"))
rl = call("account/rateLimits/read")
print("rateLimits ->", json.dumps(rl)[:400])
models = call("model/list", {}) or {}
data = models.get("data") or []
print("models ->", [(m.get("model") or m.get("id"), m.get("isDefault")) for m in data][:12])
model = args.model or next((m.get("model") or m.get("id") for m in data if m.get("isDefault")), None)
if not args.no_turn:
    th = call("thread/start", {"cwd": "/tmp", "approvalPolicy": "never", "sandbox": "read-only",
                               "ephemeral": True, "model": model}, timeout=60)
    tid = th["thread"]["id"]
    print("thread ->", tid, "model:", th.get("model"))
    t = time.time()
    call("turn/start", {"threadId": tid, "input": [{"type": "text", "text": args.prompt, "text_elements": []}]})
    done = wait_for(lambda m: m.get("method") == "turn/completed", args.timeout)
    print("turn/completed in", round(time.time() - t, 1), "s; status:", done["params"].get("turn", {}).get("status"))
    # финальный ответ агента из item/completed
    with open(args.log) as f:
        for line in f:
            r = json.loads(line)
            m = r["msg"]
            if r["dir"] == "in" and isinstance(m, dict) and m.get("method") == "item/completed":
                it = m["params"].get("item", {})
                if it.get("type") == "agentMessage":
                    print("agent says:", it.get("text"))
    from collections import Counter
    print("notifications:", dict(Counter(notifications)))
proc.stdin.close()
proc.terminate()
