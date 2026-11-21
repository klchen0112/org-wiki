import { createUserMessage } from "@deepseek-ai/dsh-llm";
import { call, recall, tools } from "org-wiki-memory-client";

export const name = "org-wiki-memory";
export const inject = ["tools"];

function context(agent, signal, request) {
  return { cwd: agent?.session.header.cwd, session: agent?.session.id, host: "dsh", signal, request };
}
export function apply(ctx) {
  for (const spec of tools) {
    ctx.tools.register({
      name: spec.name, description: spec.description, parameters: spec.inputSchema,
      output: { schema: { type: "string" }, render: (_args, text) => [{ type: "text", text }] },
      async execute(args, exec) {
        return JSON.stringify(await call(spec.name, args, context(exec.agent, exec.signal, exec.callId)));
      },
    });
  }
  ctx.on("agent/pre-step", async ({ agent, turn, step, signal }, next) => {
    const decision = await next();
    if (decision.kind !== "enter" || turn !== 1 || step !== 1 || signal.aborted) return decision;
    const prompt = decision.messages.filter(message => message.source?.kind === "user")
      .flatMap(message => message.content).filter(block => block.type === "text")
      .map(block => block.text).join("\n");
    try {
      const text = await recall(prompt, context(agent, signal));
      if (!text || signal.aborted) return decision;
      return { ...decision, messages: [...decision.messages, createUserMessage({
        content: [{ type: "text", text }],
        source: { kind: name, form: "snapshot", sections: [{ name, text }] },
      })] };
    } catch (error) {
      console.error("Org memory recall unavailable:", error.message);
      return decision;
    }
  }, { prepend: true });
}
