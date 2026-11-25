import test from "node:test";
import assert from "node:assert/strict";
import { spawn, execFile } from "node:child_process";
import { promisify } from "node:util";
import { once } from "node:events";
import { mkdtemp, mkdir, rm, stat, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";
import { setTimeout as delay } from "node:timers/promises";
import * as dshPlugin from "../packages/dsh/index.js";
import { createRequire } from "node:module";
import pi from "../packages/pi/index.ts";
import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { StdioClientTransport } from "@modelcontextprotocol/sdk/client/stdio.js";

test("Pi, DSH and a scoped stdio client use one saved corpus", { timeout: 60000 }, async t => {
  const dir = await mkdtemp(path.join(tmpdir(), "org-memory-"));
  const cwd = path.join(dir, "project");
  const other = path.join(dir, "other");
  const wiki = path.join(dir, "wiki");
  await Promise.all([mkdir(cwd), mkdir(other), mkdir(wiki)]);
  await writeFile(path.join(wiki, "checks.org"),
    ":PROPERTIES:\n:ID: acceptance-check\n:ROAM_ALIASES: \"make check\"\n:END:\n#+title: Project acceptance\n");
  const socket = path.join(dir, "test-server");
  process.env.ORG_WIKI_MEMORY_SOCKET = socket;
  delete process.env.ORG_WIKI_MEMORY_BRIDGE;
  const setup = `(progn (require 'server) (require 'org-wiki-memory) (require 'org-roam)
    (setq org-wiki-root (expand-file-name "wiki" (getenv "MEMORY_TEST_DIR"))
          org-roam-directory org-wiki-root
          org-roam-db-location (expand-file-name "roam.sqlite" (getenv "MEMORY_TEST_DIR"))
          org-id-prefix "org[test]"
          org-id-locations-file (expand-file-name "ids" (getenv "MEMORY_TEST_DIR"))
          server-socket-dir (getenv "MEMORY_TEST_DIR") server-name "test-server")
    (org-roam-db-sync) (org-wiki-memory-enable) (server-start)
    (while t (accept-process-output nil 0.1)))`;
  const emacs = spawn("emacs", ["-Q", "--batch", "-L", process.cwd(), "--eval", setup],
    { env: { ...process.env, MEMORY_TEST_DIR: dir }, stdio: ["ignore", "ignore", "pipe"] });
  let diagnostics = "";
  emacs.stderr.on("data", chunk => { diagnostics += chunk; });
  const exited = once(emacs, "exit");
  t.after(async () => {
    emacs.kill("SIGKILL");
    await exited;
    await rm(dir, { recursive: true, force: true });
  });
  for (let i = 0; !(await stat(socket).catch(() => false)); i++) {
    assert.ok(i < 100 && emacs.exitCode === null, "Failed to start temporary Emacs: " + diagnostics);
    await delay(50);
  }
  const piTools = new Map(), piHooks = new Map(), dshTools = new Map(), dshHooks = new Map();
  pi({ registerTool: tool => piTools.set(tool.name, tool), on: (key, fn) => piHooks.set(key, fn) });
  dshPlugin.apply({ tools: { register: tool => dshTools.set(tool.name, tool) }, on: (key, fn) => dshHooks.set(key, fn) });
  const piCtx = { cwd, sessionManager: { getSessionId: () => "pi-session", getBranch: () => [] } };
  const exec = { agent: { session: { header: { cwd }, id: "dsh-session" } }, signal: new AbortController().signal };
  const record = { title: "项目验收", summary: "用 make check 验收", category: "decision", body: "Run make check." };
  const script = "printf '%s\\n' verification_marker\n";
  await writeFile(path.join(cwd, "verify.sh"), script);
  const save = () => piTools.get("org_memory_remember").execute("save",
    { ...record, kind: "术", script_path: "verify.sh" }, exec.signal, null, piCtx);
  const { details: saved } = await save();
  assert.match(saved.id, /^org\[test\]:[a-f\d]{8}(?:-[a-f\d]{4}){3}-[a-f\d]{12}$/i);
  const linkTo = id => "[[id:" + id.replace("org[test]", "org\\[test\\]") + "]]";
  assert.equal(saved.title, record.title);
  assert.deepEqual(saved.related_ids, ["acceptance-check"]);
  assert.equal((await save()).details.id, saved.id);
  const search = (args, ctx = piCtx) => piTools.get("org_memory_search").execute("search", args, exec.signal, null, ctx);
  assert.deepEqual((await search({ kind: "术", category: "decision" })).details.map(row => row.id), [saved.id]);
  assert.deepEqual((await search({ kind: "道" })).details, []);
  assert.deepEqual((await search({ query: "verification_marker" }, { ...piCtx, cwd: other })).details, []);
  const recalled = await piHooks.get("before_agent_start")({ prompt: "verification_marker", messageType: "user" }, piCtx);
  assert.ok(recalled.message.content.includes(linkTo(saved.id)));
  assert.match(recalled.message.content, /verify\.sh/);
  assert.doesNotMatch(recalled.message.content, /verification_marker/);
  const expanded = JSON.parse(await dshTools.get("org_memory_read").execute({ id: saved.id, include_script: true }, exec));
  assert.deepEqual(expanded.related_ids, saved.related_ids);
  assert.equal(expanded.script_content, script);
  if (process.env.ORG_WIKI_TEST_PI) {
    const invocation = promisify(execFile)(process.env.ORG_WIKI_TEST_PI, [
      "--offline", "--mode", "json", "--no-session", "--no-approve", "-ne", "-ns", "-np", "-nc",
      "--no-builtin-tools", "-e", path.resolve("packages/pi/index.ts"), "-e", path.resolve("tests/pi-provider.ts"),
      "--provider", "memory-fixture", "--model", "local", "如何验收？"
    ], { cwd, timeout: 20000, env: { ...process.env, PI_CODING_AGENT_DIR: path.join(dir, "pi") } });
    invocation.child.stdin.end();
    const { stdout, stderr } = await invocation;
    assert.doesNotMatch(stderr, /Extension error|Failed to load extension/i);
    const events = stdout.trim().split("\n").map(line => JSON.parse(line));
    const end = events.find(e => e.type === "tool_execution_end" && e.toolName === "org_memory_search");
    assert.ok(end && !end.isError, JSON.stringify(events).slice(-3000));
    assert.match(JSON.stringify(end.result), /make check/);
  }
  const proposed = { kind: "enter", messages: [{ source: { kind: "user" }, content: [{ type: "text", text: "如何验收？" }] }] };
  const hook = dshHooks.get("agent/pre-step");
  const entered = await hook({ ...exec, turn: 1, step: 1 }, async () => proposed);
  assert.match(entered.messages.at(-1).content[0].text, /make check/);
  assert.equal(await hook({ ...exec, turn: 2, step: 1 }, async () => proposed), proposed);
  if (process.env.ORG_WIKI_TEST_DSH) {
    const resolve = createRequire(path.join(process.env.ORG_WIKI_TEST_DSH, "package.json")).resolve;
    const load = name => import(resolve("@deepseek-ai/" + name));
    const [{ Context }, { SystemPrompt }, { ToolRuntime }, { agentEvents }] =
      await Promise.all(["cordis", "dsh-system-prompt", "dsh-tools", "dsh-agent"].map(load));
    const ctx = new Context();
    await ctx.plugin(SystemPrompt, {});
    await ctx.plugin(ToolRuntime, { mode: "native" });
    await ctx.plugin(dshPlugin, {});
    assert.ok(ctx.tools.schemas().some(tool => tool.name === "org_memory_search"));
    const result = await ctx.tools.execute({ ...exec, name: "org_memory_read",
      callId: "runtime-read", arguments: { id: saved.id } });
    assert.match(JSON.stringify(result), /make check/);
    const enter = await agentEvents(ctx, exec.agent).waterfall("agent/pre-step",
      { turn: 1, step: 1, signal: exec.signal, messages: proposed.messages }, async () => proposed);
    assert.match(enter.messages.at(-1).content[0].text, /make check/);
  }
  const personal = JSON.parse(await dshTools.get("org_memory_remember").execute({
    ...record, scope: "personal", category: "preference", title: "评审语言", summary: "使用中文评审"
  }, { ...exec, callId: "preference" }));
  const personalAnswer = await piHooks.get("before_agent_start")({ prompt: "评审语言", messageType: "user" },
    { ...piCtx, cwd: other });
  assert.match(personalAnswer.message.content, /中文评审/);
  assert.ok(personalAnswer.message.content.includes(linkTo(personal.id)));
  const updated = JSON.parse(await dshTools.get("org_memory_update").execute({
    ...record, summary: "改用 make verify 验收", id: saved.id, expected_revision: saved.revision,
  }, { ...exec, callId: "edit" }));
  const answer = await piHooks.get("before_agent_start")({ prompt: "怎么验收", messageType: "user" }, piCtx);
  assert.equal(updated.kind, "术");
  assert.equal(updated.script_path, "verify.sh");
  assert.match(answer.message.content, /make verify/);
  const client = new Client({ name: "test", version: "1" });
  await client.connect(new StdioClientTransport({ command: process.execPath,
    args: [path.resolve("packages/client/stdio.js"), other], env: process.env }));
  t.after(() => client.close());
  assert.equal((await client.listTools()).tools.length, 5);
  const read = await client.callTool({ name: "org_memory_read", arguments: { id: saved.id } });
  assert.equal(read.isError, true);
  assert.match(read.content[0].text, /unknown_id/);
  await piTools.get("org_memory_forget").execute("forget", { id: saved.id, expected_revision: updated.revision },
    exec.signal, null, piCtx);
  await piTools.get("org_memory_forget").execute("forget-pref", { id: personal.id, expected_revision: personal.revision },
    exec.signal, null, piCtx);
  assert.equal(await hook({ ...exec, turn: 1, step: 1 }, async () => proposed), proposed);
  process.env.ORG_WIKI_MEMORY_SOCKET = path.join(dir, "unavailable");
  assert.equal(await hook({ ...exec, turn: 1, step: 1 }, async () => proposed), proposed);
  await assert.rejects(save);
  process.env.ORG_WIKI_MEMORY_SOCKET = socket;
  assert.equal((await piTools.get("org_memory_search").execute("retry", { query: "验收" },
    exec.signal, null, piCtx)).details.length, 0);
});
