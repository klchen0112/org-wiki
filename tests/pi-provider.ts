// Deterministic offline provider for the real Pi CLI integration test.
import { createAssistantMessageEventStream } from "@earendil-works/pi-ai";

export default function fixture(pi) {
  pi.registerProvider("memory-fixture", {
    api: "memory-fixture", baseUrl: "http://127.0.0.1:0", apiKey: "fixture",
    models: [{ id: "local", name: "Local fixture", reasoning: false, input: ["text"],
      cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 }, contextWindow: 32000, maxTokens: 1000 }],
    streamSimple(model, context) {
      const stream = createAssistantMessageEventStream();
      const finished = context.messages.some(message => message.role === "toolResult");
      const message = { role: "assistant", api: model.api, provider: model.provider, model: model.id,
        timestamp: Date.now(), stopReason: finished ? "stop" : "toolUse",
        usage: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0,
          cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 } },
        content: finished ? [{ type: "text", text: "complete" }] :
          [{ type: "toolCall", id: "fixture-search", name: "org_memory_search", arguments: { query: "验收" } }] };
      stream.push({ type: "start", partial: message });
      stream.push({ type: "done", reason: message.stopReason, message });
      stream.end();
      return stream;
    },
  });
}
