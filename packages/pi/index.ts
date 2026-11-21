import type { ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent";
import { call, recall, tools } from "org-wiki-memory-client";

function context(ctx: ExtensionContext, request?: string) {
  return { cwd: ctx.cwd, session: ctx.sessionManager.getSessionId(), host: "pi", request, signal: ctx.signal };
}

export default function orgWikiMemory(pi: ExtensionAPI) {
  for (const spec of tools) {
    pi.registerTool({
      name: spec.name, label: spec.name, description: spec.description, parameters: spec.inputSchema,
      async execute(id, args, signal, _update, ctx) {
        const result = await call(spec.name, args, { ...context(ctx, id), signal });
        return { content: [{ type: "text", text: JSON.stringify(result) }], details: result };
      },
    });
  }
  pi.on("before_agent_start", async (event, ctx) => {
    if (event.messageType !== "user") return;
    if (ctx.sessionManager.getBranch().some(entry =>
      (entry.type === "message" && entry.message.role === "assistant") ||
      (entry.type === "custom_message" && entry.customType === "org-wiki-recall"))) return;
    try {
      const text = await recall(event.prompt, context(ctx));
      if (text) return { message: { customType: "org-wiki-recall", content: text, display: false } };
    } catch (error) {
      if (ctx.hasUI) ctx.ui.notify("Org memory recall unavailable: " + String(error), "warning");
    }
  });
}
