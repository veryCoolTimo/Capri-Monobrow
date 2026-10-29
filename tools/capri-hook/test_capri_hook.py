"""Тесты capri-hook. Запуск: python3 -m unittest discover -s tools/capri-hook -v"""
import importlib.machinery
import importlib.util
import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
SCRIPT = os.path.join(HERE, "capri-hook")
FIXTURES = os.path.join(HERE, "..", "..", "apps", "macos", "Tests", "CapriKitTests", "Fixtures", "hooks")

loader = importlib.machinery.SourceFileLoader("capri_hook", SCRIPT)
spec = importlib.util.spec_from_loader("capri_hook", loader)
ch = importlib.util.module_from_spec(spec)
loader.exec_module(ch)


def fixture(name, event):
    for line in open(os.path.join(FIXTURES, name)):
        rec = json.loads(line)
        if rec["label"].endswith(":" + event):
            return rec
    raise KeyError(event)


# Хуки, как на timoserver: у пользователя уже есть свои.
USER_SETTINGS = {
    "model": "opus[1m]",
    "hooks": {
        "PreToolUse": [{"matcher": "Bash", "hooks": [{"type": "command", "command": "~/bin/guard.sh"}]}],
        "SessionStart": [{"hooks": [{"type": "command", "command": "~/bin/start.sh"}]}],
    },
    "enabledPlugins": {"x@y": True},
}


class Base(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="capri-test-")
        self.env = dict(os.environ, CAPRI_HOME=os.path.join(self.tmp, "capri"), HOME=self.tmp,
                        TMUX_TMPDIR=os.path.join(self.tmp, "tmux"))
        self.env.pop("TMUX", None)
        self.env.pop("TMUX_PANE", None)
        os.makedirs(self.env["TMUX_TMPDIR"])

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    def run_hook(self, args, stdin=""):
        return subprocess.run([sys.executable, SCRIPT] + args, input=stdin, capture_output=True, text=True,
                              env=self.env, timeout=60)

    def events(self):
        path = os.path.join(self.env["CAPRI_HOME"], "events.jsonl")
        if not os.path.exists(path):
            return []
        with open(path) as f:
            return [json.loads(l) for l in f]


class HookModeTests(Base):
    def test_permission_request_is_recorded_silently(self):
        rec = fixture("claude-server.jsonl", "PermissionRequest")
        out = self.run_hook(["claude"], json.dumps(rec["stdin"]))
        self.assertEqual(out.returncode, 0)
        self.assertEqual(out.stdout, "")
        [ev] = self.events()
        self.assertEqual(ev["agent"], "claude")
        self.assertEqual(ev["source"], "hook")
        self.assertEqual(ev["event"], "PermissionRequest")
        self.assertEqual(ev["session_id"], rec["stdin"]["session_id"])
        self.assertEqual(ev["data"]["tool_input"]["command"], "date > stamp.txt && echo done")
        self.assertIsNone(ev["tmux"])

    def test_only_whitelisted_fields_are_kept(self):
        post = {"hook_event_name": "PostToolUse", "session_id": "s", "tool_name": "Write",
                "tool_response": {"stdout": "x" * 10_000}, "tool_input": {"content": "SECRET"}}
        prompt = {"hook_event_name": "UserPromptSubmit", "session_id": "s", "prompt": "мой токен sk-123"}
        perm = {"hook_event_name": "PermissionRequest", "session_id": "s", "tool_name": "Bash",
                "tool_input": {"command": "y" * 5000, "env": "SECRET"}}
        for p in (post, prompt, perm):
            self.run_hook(["claude"], json.dumps(p))
        post_ev, prompt_ev, perm_ev = self.events()
        self.assertEqual(post_ev["data"], {"hook_event_name": "PostToolUse", "session_id": "s", "tool_name": "Write"})
        self.assertNotIn("prompt", prompt_ev["data"])
        self.assertEqual(set(perm_ev["data"]["tool_input"]), {"command"})
        self.assertLessEqual(len(perm_ev["data"]["tool_input"]["command"]), 2001)
        self.assertNotIn("SECRET", open(os.path.join(self.env["CAPRI_HOME"], "events.jsonl")).read())
        self.assertEqual(len(post_ev["id"]), 32)
        self.assertEqual(os.stat(self.env["CAPRI_HOME"]).st_mode & 0o777, 0o700)

    def test_log_lines_are_ascii(self):
        self.run_hook(["claude"], json.dumps({"hook_event_name": "Stop", "session_id": "s",
                                              "last_assistant_message": "привет \ud800"}))
        raw = open(os.path.join(self.env["CAPRI_HOME"], "events.jsonl"), "rb").read()
        raw.decode("ascii")
        self.assertTrue(self.events()[0]["data"]["last_assistant_message"].startswith("привет"))

    def test_garbage_stdin_never_fails(self):
        out = self.run_hook(["codex"], "{not json")
        self.assertEqual(out.returncode, 0)
        self.assertEqual(out.stdout, "")

    def test_concurrent_writers_lose_nothing_across_rotation(self):
        import threading
        path = os.path.join(self.tmp, "events.jsonl")
        archive = []
        real_replace = os.replace

        def recording_replace(src, dst):
            if src == path:
                with open(src) as f:
                    archive.append(f.read())
            real_replace(src, dst)

        old_limit, ch.MAX_LOG_BYTES = ch.MAX_LOG_BYTES, 4096
        ch.os.replace = recording_replace
        results = []
        try:
            def writer(n):
                for i in range(60):
                    results.append(ch.append_event({"w": n, "i": i, "pad": "x" * 40}, path))
            # Потоки делят процесс, но flock берётся на разных fd — как у разных процессов.
            ts = [threading.Thread(target=writer, args=(n,)) for n in range(6)]
            [t.start() for t in ts]
            [t.join() for t in ts]
        finally:
            ch.MAX_LOG_BYTES = old_limit
            ch.os.replace = real_replace
        self.assertTrue(all(results))
        text = "".join(archive) + open(path).read()
        records = [json.loads(l) for l in text.splitlines() if l.strip()]
        self.assertEqual(len(records), 360)
        self.assertEqual({(r["w"], r["i"]) for r in records}, {(n, i) for n in range(6) for i in range(60)})
        self.assertGreater(len(archive), 3)

    def test_rotation_keeps_previous_log(self):
        path = os.path.join(self.env["CAPRI_HOME"], "events.jsonl")
        os.makedirs(os.path.dirname(path))
        with open(path, "w") as f:
            f.write("x" * (ch.MAX_LOG_BYTES - 10) + "\n")
        self.run_hook(["claude"], json.dumps({"hook_event_name": "Stop", "session_id": "s"}))
        self.assertTrue(os.path.exists(path + ".1"))
        self.assertEqual([e["event"] for e in self.events()], ["Stop"])


class NotifyTests(Base):
    def test_notify_is_recorded_and_original_program_is_called(self):
        rec = fixture("codex-mac.jsonl", "notify")
        payload = json.dumps(rec["argv"][0])
        marker = os.path.join(self.tmp, "chained.json")
        prog = [sys.executable, "-c", "import sys; open(%r, 'w').write(sys.argv[-1])" % marker, "turn-ended"]
        out = self.run_hook(["codex-notify", "--"] + prog + [payload])
        self.assertEqual(out.returncode, 0)
        [ev] = self.events()
        self.assertEqual(ev["source"], "notify")
        self.assertEqual(ev["event"], "agent-turn-complete")
        self.assertEqual(ev["session_id"], rec["argv"][0]["thread-id"])
        for _ in range(50):
            if os.path.exists(marker):
                break
            import time; time.sleep(0.1)
        self.assertEqual(json.loads(open(marker).read())["thread-id"], rec["argv"][0]["thread-id"])

    def test_notify_without_chain(self):
        self.run_hook(["codex-notify", json.dumps({"type": "agent-turn-complete", "thread-id": "t"})])
        self.assertEqual(self.events()[0]["session_id"], "t")


class MergeTests(unittest.TestCase):
    CMD = "/home/u/.capri/bin/capri-hook claude"

    def test_ours_are_appended_after_user_hooks(self):
        merged = ch.merged_hooks(USER_SETTINGS["hooks"], ch.CLAUDE_EVENTS, self.CMD)
        self.assertEqual(merged["SessionStart"][0], USER_SETTINGS["hooks"]["SessionStart"][0])
        self.assertTrue(ch.is_ours(merged["SessionStart"][1]["hooks"][0]))
        self.assertEqual(merged["PreToolUse"], USER_SETTINGS["hooks"]["PreToolUse"])
        self.assertEqual(merged["PermissionRequest"][0]["matcher"], "*")
        self.assertNotIn("matcher", merged["Stop"][0])

    def test_install_is_idempotent_and_uninstall_restores(self):
        once = ch.merged_hooks(USER_SETTINGS["hooks"], ch.CLAUDE_EVENTS, self.CMD)
        twice = ch.merged_hooks(once, ch.CLAUDE_EVENTS, self.CMD)
        self.assertEqual(once, twice)
        self.assertEqual(ch.strip_ours(twice), USER_SETTINGS["hooks"])

    def test_reinstall_keeps_our_entry_in_place(self):
        once = ch.merged_hooks(USER_SETTINGS["hooks"], ch.CLAUDE_EVENTS, self.CMD)
        once["SessionStart"].append({"hooks": [{"type": "command", "command": "~/later.sh"}]})
        again = ch.merged_hooks(once, ch.CLAUDE_EVENTS, self.CMD)
        self.assertEqual(again["SessionStart"], once["SessionStart"])
        self.assertEqual(ch.hooks_after_ours(again), ["SessionStart"])

    def test_changed_command_replaces_old_entry(self):
        once = ch.merged_hooks(USER_SETTINGS["hooks"], ch.CLAUDE_EVENTS, "/old/capri-hook claude")
        again = ch.merged_hooks(once, ch.CLAUDE_EVENTS, self.CMD)
        self.assertEqual(sum(ch.group_is_ours(g) for g in again["Stop"]), 1)
        self.assertEqual(again["Stop"][-1]["hooks"][0]["command"], self.CMD)

    def test_quoted_path_with_space_is_ours(self):
        cmd = ch.hook_command("/Users/u/My Dir/.capri/bin/capri-hook", "claude")
        self.assertEqual(cmd, "'/Users/u/My Dir/.capri/bin/capri-hook' claude")
        self.assertTrue(ch.is_ours({"command": cmd}))
        self.assertFalse(ch.is_ours({"command": "~/bin/capri-hooks-backup.sh"}))

    def test_uninstall_keeps_user_hook_sharing_a_group(self):
        mixed = {"Stop": [{"hooks": [{"type": "command", "command": "~/mine.sh"},
                                     {"type": "command", "command": self.CMD}]}]}
        self.assertEqual(ch.strip_ours(mixed), {"Stop": [{"hooks": [{"type": "command", "command": "~/mine.sh"}]}]})


class InstallerTests(Base):
    def setUp(self):
        super().setUp()
        self.settings = os.path.join(self.tmp, ".claude", "settings.json")
        os.makedirs(os.path.dirname(self.settings))
        self.original = json.dumps(USER_SETTINGS, indent=2) + "\n"
        open(self.settings, "w").write(self.original)

    def install(self, *extra):
        return self.run_hook(["install", "--no-codex", "--claude-settings", self.settings] + list(extra))

    def test_dry_run_shows_diff_and_writes_nothing(self):
        out = self.install("--dry-run")
        self.assertEqual(out.returncode, 0, out.stderr)
        self.assertIn("+", out.stdout)
        self.assertIn("capri-hook claude", out.stdout)
        self.assertEqual(open(self.settings).read(), self.original)
        self.assertFalse(os.path.exists(os.path.join(self.env["CAPRI_HOME"], "bin", "capri-hook")))

    def test_install_backs_up_copies_itself_and_uninstall_restores(self):
        os.makedirs(self.env["CAPRI_HOME"], exist_ok=True)
        os.chmod(self.env["CAPRI_HOME"], 0o775)      # каталог от старой версии
        out = self.install()
        self.assertEqual(out.returncode, 0, out.stderr)
        backups = [f for f in os.listdir(os.path.dirname(self.settings)) if ".capri-bak-" in f]
        self.assertEqual(len(backups), 1)
        self.assertTrue(os.access(os.path.join(self.env["CAPRI_HOME"], "bin", "capri-hook"), os.X_OK))
        for d in [self.env["CAPRI_HOME"], os.path.join(self.env["CAPRI_HOME"], "bin")]:
            self.assertEqual(os.stat(d).st_mode & 0o777, 0o700, d)
        data = json.load(open(self.settings))
        self.assertEqual(data["model"], "opus[1m]")
        self.assertEqual(sorted(json.loads(self.run_hook(["status"]).stdout)["claude"]), sorted(ch.CLAUDE_EVENTS))
        self.assertIn("без изменений", self.install().stdout)
        self.run_hook(["uninstall", "--no-codex", "--claude-settings", self.settings])
        self.assertEqual(json.load(open(self.settings)), USER_SETTINGS)

    def test_invalid_json_is_refused_without_writing(self):
        open(self.settings, "w").write('{"hooks": {} // comment\n}')
        out = self.install()
        self.assertEqual(out.returncode, 1)
        self.assertIn("не JSON", out.stdout)
        self.assertNotIn("Traceback", out.stderr)
        self.assertEqual(open(self.settings).read(), '{"hooks": {} // comment\n}')

    def test_concurrent_change_aborts_write(self):
        with self.assertRaises(ch.InstallError):
            ch.write_with_backup(self.settings, "{}", "{\"x\": 1}", "t")
        self.assertEqual(open(self.settings).read(), self.original)

    def test_uninstall_without_file_creates_nothing(self):
        os.remove(self.settings)
        self.run_hook(["uninstall", "--no-codex", "--claude-settings", self.settings])
        self.assertFalse(os.path.exists(self.settings))

    def test_missing_settings_file_is_created(self):
        os.remove(self.settings)
        self.install()
        self.assertEqual(sorted(json.load(open(self.settings))["hooks"]), sorted(ch.CLAUDE_EVENTS))


@unittest.skipUnless(ch.find_codex(), "codex не установлен")
class CodexTrustTests(Base):
    def test_codex_hooks_are_written_and_trusted_by_codex_itself(self):
        codex_home = os.path.join(self.tmp, ".codex")
        os.makedirs(codex_home)
        open(os.path.join(codex_home, "config.toml"), "w").write('[hooks.state."other:key:0:0"]\ntrusted_hash = "sha256:x"\n')
        self.env["PATH"] = os.path.dirname(ch.find_codex()) + os.pathsep + self.env["PATH"]
        out = self.run_hook(["install", "--no-claude", "--codex-home", codex_home])
        self.assertEqual(out.returncode, 0, out.stdout + out.stderr)
        self.assertIn("доверие выставлено", out.stdout)
        config = open(os.path.join(codex_home, "config.toml")).read()
        self.assertIn("other:key:0:0", config)
        server = ch.AppServer(ch.find_codex(), codex_home)
        try:
            hooks = server.call("hooks/list", {"cwds": [self.tmp]})["data"][0]["hooks"]
        finally:
            server.close()
        ours = [h for h in hooks if ch.OURS.search(h.get("command") or "")]
        # Старые Codex (0.147) не знают Interrupt: доверие у всех, что он распознал.
        self.assertGreaterEqual(len(ours), len(ch.CODEX_EVENTS) - 1)
        self.assertTrue(all(h["trustStatus"] == "trusted" for h in ours))
        self.assertIn("доверие выставлено %d" % len(ours), out.stdout)


class AgentDetectionTests(unittest.TestCase):
    def test_agent_of(self):
        self.assertEqual(ch.agent_of("claude --settings x"), "claude")
        self.assertEqual(ch.agent_of("/Users/u/.local/share/claude/versions/2.1.310 --model haiku"), "claude")
        self.assertEqual(ch.agent_of("node /home/u/.local/bin/codex -a on-request"), None)
        self.assertEqual(ch.agent_of("/home/u/.local/lib/node_modules/@openai/codex/node_modules/@openai/codex-linux-x64/vendor/x86_64-unknown-linux-musl/bin/codex -a x"), "codex")
        self.assertEqual(ch.agent_of("/opt/homebrew/bin/codex"), "codex")
        self.assertEqual(ch.agent_of("vim codex.md"), None)
        self.assertEqual(ch.agent_of("/bin/bash ./start-codex.sh"), None)

    def test_pane_agent_walks_children(self):
        children = {"10": ["11"], "11": ["12"]}
        self.assertEqual(ch.pane_agent("10", children, {"12": "codex"}), "codex")
        self.assertIsNone(ch.pane_agent("10", children, {}))


class PaneFilterTests(Base):
    def test_only_sessions_prefix(self):
        fake = os.path.join(self.tmp, "bin")
        os.makedirs(fake)
        with open(os.path.join(fake, "tmux"), "w") as f:
            f.write("#!/bin/sh\nprintf '%%1\\tcapri-test-a\\t0\\tclaude\\t1\\t/p\\tt\\t80\\t24\\n%%2\\twork\\t0\\tclaude\\t2\\t/p\\tt\\t80\\t24\\n'\n")
        os.chmod(os.path.join(fake, "tmux"), 0o755)
        old = os.environ["PATH"]
        os.environ["PATH"] = fake + os.pathsep + old
        try:
            ch.SESSION_PREFIX = "capri-test-"
            self.assertEqual([p["pane"] for p in ch.list_panes()], ["%1"])
            ch.SESSION_PREFIX = None
            self.assertEqual(len(ch.list_panes()), 2)
        finally:
            os.environ["PATH"] = old


class FollowerTests(Base):
    def test_follow_survives_rotation(self):
        path = os.path.join(self.tmp, "events.jsonl")
        open(path, "w").write('{"a":1}\n{"a":2}\n')
        f = ch.Follower(path)
        self.assertEqual(f.open_at_end(), [b'{"a":1}', b'{"a":2}'])
        open(path, "a").write('{"a":3}\n')
        self.assertEqual(f.poll(), [b'{"a":3}'])
        os.replace(path, path + ".1")
        open(path, "w").write('{"a":4}\n')
        self.assertEqual(f.poll(), [b'{"a":4}'])
        open(path, "a").write('{"a":5')
        self.assertEqual(f.poll(), [])
        open(path, "a").write('}\n')
        self.assertEqual(f.poll(), [b'{"a":5}'])

    def test_tail_written_just_before_rotation_is_not_lost(self):
        path = os.path.join(self.tmp, "events.jsonl")
        open(path, "w").write('{"a":1}\n')
        f = ch.Follower(path)
        f.open_at_end()
        open(path, "a").write('{"a":2}\n')
        os.replace(path, path + ".1")
        open(path, "w").write('{"a":3}\n')
        self.assertEqual(f.poll(), [b'{"a":2}', b'{"a":3}'])

    def test_snapshot_keeps_last_events_per_session_including_rotated(self):
        path = os.path.join(self.tmp, "events.jsonl")
        with open(path + ".1", "w") as f:
            f.write(json.dumps({"session_id": "old", "event": "PermissionRequest"}) + "\n")
        current = [json.dumps({"session_id": "busy", "i": i}).encode() for i in range(100)]
        snap = [json.loads(l) for l in ch.snapshot_lines(current, path, per_session=30)]
        self.assertEqual(snap[0]["session_id"], "old")
        self.assertEqual(len(snap), 31)
        self.assertEqual(snap[-1]["i"], 99)

    def test_stream_once_emits_snapshot(self):
        self.run_hook(["claude"], json.dumps({"hook_event_name": "Stop", "session_id": "s"}))
        out = self.run_hook(["stream", "--once"])
        msgs = [json.loads(l) for l in out.stdout.splitlines()]
        self.assertEqual([m["kind"] for m in msgs], ["hello", "event", "panes", "snapshot-end"])
        self.assertEqual(msgs[0]["proto"], ch.PROTO)
        self.assertIn("now", msgs[0])
        out = self.run_hook(["stream", "--once", "--no-replay"])
        self.assertEqual([json.loads(l)["kind"] for l in out.stdout.splitlines()], ["hello", "panes", "snapshot-end"])


if __name__ == "__main__":
    unittest.main()
