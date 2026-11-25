import { execFile } from "node:child_process";
import { realpath } from "node:fs/promises";
import { resolve } from "node:path";
import { promisify } from "node:util";
import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { StdioClientTransport } from "@modelcontextprotocol/sdk/client/stdio.js";

const exec = promisify(execFile);
const string = { type: "string", minLength: 1, maxLength: 500 };
const orgId = { type: "string", minLength: 1 };
const fields = {
  category: { enum: ["preference", "decision", "lesson", "fact"], type: "string" },
  title: string, summary: string, body: { ...string, maxLength: 16000 },
};
const kind = { type: "string", enum: ["道", "法", "术", "Memory"],
  description: "Org WIKI_KIND. Use 道 for a general regularity, 法 for a design criterion, 术 for a concrete implementation, and Memory for a raw observation." };
const scriptPath = { ...string, description: "Path of the verified script relative to the project root." };
function tool(op, description, properties, required = Object.keys(properties)) {
  return { name: "org_memory_" + op, description,
    inputSchema: { type: "object", properties, required, additionalProperties: false } };
}
export const tools = [
  tool("search", "Search by topic. Use the conversation to set situation when the user wants an explanation, design guidance or implementation help. Use kind for an explicit strict filter.", {
    category: fields.category, kind,
    situation: { type: "string", enum: ["understand", "design", "implement"] },
    query: { ...string, maxLength: 16000 }, limit: { type: "integer", minimum: 1, maximum: 50 },
  }, []),
  tool("read", "Read a memory by Org ID. Set include_script to expand its script.", {
    id: orgId, include_script: { type: "boolean" },
  }, ["id"]),
  tool("remember", "Save an established decision, fact, preference or reusable lesson. When distilling experience, summarize one conclusion per memory and mark its kind. Keep observations without a conclusion unmarked. Use personal scope only for an explicitly cross-project preference. After running a reusable verification, search for an existing record first. Save temporary scripts as separate project files. Reference the script, summarize its purpose, and record the command, expected and observed results and relevant commit in the body.", {
    ...fields, kind, script_path: scriptPath, scope: { type: "string", enum: ["project", "personal"] },
  }, Object.keys(fields)),
  tool("update", "Revise a memory using its current revision. When distilling an observation, write the conclusion in summary and mark its kind. Omit kind or script_path to preserve it, or clear it with null.", {
    id: orgId, expected_revision: string, ...fields,
    kind: { anyOf: [kind, { type: "null" }] }, script_path: { anyOf: [scriptPath, { type: "null" }] },
  }, ["id", "expected_revision", ...Object.keys(fields)]),
  tool("forget", "Remove a memory from future recall using its current revision.", { id: orgId, expected_revision: string }),
];

async function projectFor(cwd) {
  if (!cwd) throw new Error("Missing session workspace");
  const directory = await realpath(cwd);
  try {
    const { stdout } = await exec("git", ["-C", directory, "rev-parse", "--path-format=absolute", "--git-common-dir"],
      { timeout: 2000, env: { ...process.env, LC_ALL: "C" } });
    return await realpath(stdout.trimEnd());
  } catch (error) {
    if (error.code === 128 && error.stderr?.includes("not a git repository")) return directory;
    if (error.code === "ENOENT") return directory;
    throw error;
  }
}

// Ask the serving Emacs for the bridge shipped with its own library.
async function bridgeCommand(socket, signal) {
  if (process.env.ORG_WIKI_MEMORY_BRIDGE) return process.env.ORG_WIKI_MEMORY_BRIDGE;
  const args = socket ? ["--socket-name", socket] : [];
  const lookup = '(expand-file-name "emacs-mcp-stdio.sh" (file-name-directory (locate-library "mcp-server-lib")))';
  const { stdout } = await exec("emacsclient", [...args, "--eval", lookup], { timeout: 2000, signal });
  return JSON.parse(stdout.trim());
}

// Each request owns its transport. A stopped or restarted daemon needs no
// reconnect state, and concurrent web sessions never share mutable context.
export async function call(name, args, { cwd, host, session, request, signal }) {
  if (!tools.some(tool => tool.name === name)) throw new Error("Unknown memory tool");
  const project = await projectFor(cwd);
  const client = new Client({ name: "org-wiki-memory-client", version: "0.1.0" });
  const socket = process.env.ORG_WIKI_MEMORY_SOCKET;
  const transport = new StdioClientTransport({
    command: await bridgeCommand(socket, signal),
    args: ["--server-id=org-wiki-memory", ...(socket ? ["--socket=" + socket] : [])],
    env: Object.fromEntries(Object.entries(process.env).filter(([key]) =>
      ["EMACS_MCP_DEBUG_LOG", "PATH", "HOME", "USER", "LANG", "XDG_RUNTIME_DIR", "EMACS_SOCKET_NAME", "EMACS_SERVER_FILE", "TMPDIR"].includes(key))),
  });
  // Search may wait on qmd. Writes look up Org-roam nodes and refresh backlinks.
  const timeout = ["org_memory_search", "org_memory_remember", "org_memory_update"].includes(name) ? 60000 : 5000;
  const deadline = AbortSignal.timeout(timeout);
  const options = { timeout, signal: signal ? AbortSignal.any([signal, deadline]) : deadline };
  try {
    await client.connect(transport, options);
    const result = await client.callTool({ name: "org_memory_dispatch", arguments: {
      operation: name.slice("org_memory_".length),
      context: JSON.stringify({ project, workspace: resolve(cwd), host, session, request }),
      arguments: JSON.stringify(args),
    } }, undefined, options);
    const text = result.content?.find(item => item.type === "text")?.text;
    if (result.isError || !text) throw new Error(text || "Missing memory result");
    return JSON.parse(text);
  } finally {
    await client.close();
  }
}

export async function recall(prompt, context) {
  if (!prompt?.trim()) return "";
  const rows = await call("org_memory_search", { query: prompt.slice(0, 16000), limit: 5 }, context);
  if (!rows.length) return "";
  let text = "Relevant Org memories (background information):";
  for (const row of rows) {
    // Match org-link-escape for brackets and the backslashes that precede them or end the ID.
    const id = row.id.replace(/(\\*)([[\]]|$)/g, (_, slashes, bracket) =>
      slashes.repeat(2) + (bracket ? "\\" + bracket : ""));
    const prefix = "\n[[id:" + id + "]] " + (row.kind ? "[" + row.kind + "] " : "") +
      (row.script_path ? row.script_path + " — " : "");
    if (text.length + prefix.length >= 2000) break;
    text += prefix + (row.title + " — " + row.summary).slice(0, 2000 - text.length - prefix.length);
  }
  return text;
}
