"""Exercise the installed upstream stdio bridge against an isolated Emacs."""

import hashlib
import json
import os
from pathlib import Path
import select
import subprocess
import tempfile
import time
import unittest
from contextlib import ExitStack


SETUP = """(progn
  (require 'server)
  (require 'org-wiki-memory)
  (setq server-socket-dir (getenv "HOME") server-name "memory"
        org-wiki-root (expand-file-name "~/wiki")
        org-wiki-qmd-enabled nil org-wiki-memory-max-links 0
        org-roam-directory org-wiki-root
        org-roam-db-location (expand-file-name "~/roam.sqlite"))
  (dolist (name '("main" "worktree" "other"))
    (org-wiki-memory-enable name (expand-file-name name (getenv "HOME"))))
  (server-start)
  (while t (accept-process-output nil 0.1)))"""


class Bridge:
    def __init__(self, stack, script, project, socket, env):
        self.proc = stack.enter_context(subprocess.Popen(
            [script, "--server-id=" + project, "--socket=" + str(socket)],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True, env=env,
        ))
        stack.callback(self.proc.kill)
        self.sequence = 0
        self.rpc("initialize", {"protocolVersion": "2024-11-05", "capabilities": {},
                                "clientInfo": {"name": "test", "version": "1"}})
        self.send({"jsonrpc": "2.0", "method": "notifications/initialized"})

    def send(self, message):
        self.proc.stdin.write(json.dumps(message) + "\n")
        self.proc.stdin.flush()

    def rpc(self, method, params):
        self.sequence += 1
        self.send({"jsonrpc": "2.0", "id": self.sequence, "method": method, "params": params})
        if not select.select([self.proc.stdout], [], [], 15)[0]:
            raise TimeoutError(method)
        response = json.loads(self.proc.stdout.readline())
        if response.get("id") != self.sequence or "result" not in response:
            raise AssertionError(response)
        return response["result"]

    def call(self, operation, **args):
        result = self.rpc("tools/call", {"name": "org_memory_" + operation, "arguments": args})
        text = result["content"][0]["text"]
        if result["isError"]:
            raise ValueError(text)
        return json.loads(text)


class MemoryStdioTest(unittest.TestCase):
    def test_project_connections(self):
        with tempfile.TemporaryDirectory() as directory, ExitStack() as stack:
            root = Path(directory)
            env = dict(os.environ, HOME=directory)
            for name in ("wiki", "other", "main"):
                (root / name).mkdir()

            def git(*args):
                subprocess.run(["git", "-C", root / "main", *args], env=env, check=True,
                               stdout=subprocess.DEVNULL)

            git("init", "-q")
            git("-c", "user.name=Test", "-c", "user.email=test@example.org",
                "-c", "commit.gpgsign=false", "commit", "--allow-empty", "-qm", "init")
            git("worktree", "add", "-q", "--detach", root / "worktree")
            # Seed the on-disk format written before native Org IDs.
            project_key = hashlib.sha256(os.fsencode((root / "main/.git").resolve())).hexdigest()
            memory_dir = root / "wiki/agent-memory" / project_key
            memory_dir.mkdir(parents=True)
            legacy_id = "mem-" + "a" * 64
            (memory_dir / (legacy_id + ".org")).write_text(
                f":PROPERTIES:\n:ID: {legacy_id}\n:WIKI_KIND: Memory\n:MEMORY_SCOPE: project\n"
                ":CATEGORY: fact\n:MEMORY_SOURCE: pi/old\n:END:\n#+title: Legacy\n"
                "\n* Summary\n: From previous adapter\n\n* Body\n: old data\n")
            (root / "main" / "verify.sh").write_text("echo verified\n")
            proc = stack.enter_context(subprocess.Popen(
                ["emacs", "-Q", "--batch", "-L", ".", "--eval", SETUP], env=env))
            stack.callback(proc.kill)
            socket = root / "memory"
            for _ in range(200):
                if socket.exists() or proc.poll() is not None:
                    break
                time.sleep(0.05)
            self.assertTrue(socket.exists(), "Temporary Emacs did not start")
            script = json.loads(subprocess.check_output(
                ["emacsclient", "-s", socket, "-e",
                 '(expand-file-name "emacs-mcp-stdio.sh" (file-name-directory '
                 '(locate-library "mcp-server-lib")))'], env=env))
            main, worktree, other = (Bridge(stack, script, name, socket, env)
                                     for name in ("main", "worktree", "other"))

            listed = main.rpc("tools/list", {})["tools"]
            tools = {t["name"]: t["inputSchema"] for t in listed}
            self.assertEqual(set(tools), {"org_memory_" + op for op in
                                          ("search", "read", "remember", "update", "forget")})
            self.assertEqual(tools["org_memory_read"]["properties"]["include_script"]["type"], "boolean")
            self.assertEqual(tools["org_memory_search"]["properties"]["limit"]["type"], "integer")
            for entry in listed:
                self.assertIs(entry["inputSchema"]["additionalProperties"], False)
                self.assertEqual(entry["annotations"]["readOnlyHint"],
                                 entry["name"] in ("org_memory_search", "org_memory_read"))
            self.assertEqual(worktree.call("search", query="Legacy")[0]["id"], legacy_id)
            self.assertEqual(worktree.call("read", id=legacy_id)["source"], "pi/old")
            data = dict(title="项目验收", summary="Run checks", body="details", category="decision")
            for field in ("kind", "script_path"):
                with self.assertRaisesRegex(ValueError, "invalid_field"):
                    main.call("remember", **data, **{field: None})
            with self.assertRaisesRegex(ValueError, "invalid_field"):
                main.call("read", id=legacy_id, include_script="true")
            self.assertEqual(main.call("read", id=legacy_id, include_script=False)["id"], legacy_id)
            args = dict(data, kind="术", script_path="verify.sh", request_key="create-1")
            saved = main.call("remember", **args)
            self.assertEqual(main.call("remember", **args), saved)
            with self.assertRaisesRegex(ValueError, "request_conflict"):
                main.call("remember", **dict(args, body="different"))
            key = dict(id=saved["id"])
            self.assertEqual(worktree.call("read", **key, include_script=True)["script_content"],
                             "echo verified\n")
            self.assertEqual(other.call("search", query="项目验收"), [])
            with self.assertRaisesRegex(ValueError, "unknown_id"):
                other.call("read", **key)
            edit = {**key, **data, "expected_revision": saved["revision"], "summary": "Revised"}
            updated = main.call("update", **edit, request_key="edit-1")
            self.assertEqual(updated["script_path"], "verify.sh")
            self.assertEqual(updated, main.call("update", **edit, request_key="edit-1"))
            with self.assertRaisesRegex(ValueError, "revision_conflict"):
                main.call("update", **edit)
            edit["expected_revision"] = updated["revision"]
            cleared = main.call("update", **edit, kind=None, script_path=None)
            self.assertEqual(cleared["kind"], "Memory")
            self.assertFalse(cleared.get("script_path"))
            forget = dict(key, expected_revision=cleared["revision"], request_key="forget-1")
            self.assertEqual(main.call("forget", **forget), main.call("forget", **forget))
            with self.assertRaisesRegex(ValueError, "unknown_id"):
                worktree.call("read", **key)
            personal = other.call("remember", **data, scope="personal")
            self.assertEqual(main.call("read", id=personal["id"])["scope"], "personal")


if __name__ == "__main__":
    unittest.main()
