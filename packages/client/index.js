import { execFile } from "node:child_process";
import { realpath } from "node:fs/promises";
import { promisify } from "node:util";
import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { StdioClientTransport } from "@modelcontextprotocol/sdk/client/stdio.js";

const exec = promisify(execFile);
const string = { type: "string", minLength: 1, maxLength: 500 };
const fields = {
  category: { enum: ["preference", "decision", "lesson", "fact"], type: "string" },
  title: string, summary: string, body: { ...string, maxLength: 16000 },
};
function tool(op, description, properties, required = Object.keys(properties)) {
  return { name: "org_memory_" + op, description,
    inputSchema: { type: "object", properties, required, additionalProperties: false } };
}
export const tools = [
  tool("search", "Find relevant project memories and personal preferences.", {
    query: { ...string, maxLength: 16000 }, limit: { type: "integer", minimum: 1, maximum: 50 },
  }, ["query"]),
  tool("read", "Read a memory and its source by Org ID.", { id: string }),
  tool("remember", "Save an established decision, fact, preference or reusable lesson. Use personal scope only for an explicitly cross-project preference.", {
    ...fields, scope: { type: "string", enum: ["project", "personal"] },
  }, Object.keys(fields)),
  tool("update", "Correct a memory using its current revision.", { id: string, expected_revision: string, ...fields }),
  tool("forget", "Remove a memory from future recall using its current revision.", { id: string, expected_revision: string }),
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
  const deadline = AbortSignal.timeout(5000);
  const options = { timeout: 5000, signal: signal ? AbortSignal.any([signal, deadline]) : deadline };
  try {
    await client.connect(transport, options);
    const result = await client.callTool({ name: "org_memory_dispatch", arguments: {
      operation: name.slice("org_memory_".length),
      context: JSON.stringify({ project, host, session, request }),
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
    const prefix = "\n[[id:" + row.id + "]] ";
    if (text.length + prefix.length >= 2000) break;
    text += prefix + (row.title + " — " + row.summary).slice(0, 2000 - text.length - prefix.length);
  }
  return text;
}
