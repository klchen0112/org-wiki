# 通过 Emacs MCP 共享 Org 记忆

Pi、DeepSeek Harness（DSH）和其他支持 stdio MCP 的客户端按需读写同一份项目记忆和个人偏好。Emacs 把记录保存在 `org-wiki-root/agent-memory/`。[共享记忆设计](agent-memory-design.md)

## 实现依据

| 软件包 | 记忆如何工作 | 本项目采用的部分 |
| --- | --- | --- |
| `pi-memory`，`@zosmaai/pi-llm-wiki` | 前者维护 Markdown 长期记忆、日志和草稿，并可借助 qmd 检索。后者把来源和观察整理为可复用页面，支持个人与项目召回。 | 可编辑文件、项目与个人范围、来源字段。[Pi Memory](https://github.com/jayzeng/pi-memory) · [Pi LLM Wiki](https://github.com/zosmaai/pi-llm-wiki) |
| `@seangle/pi-remember`，`@seangle/dsh-remember` | 两个宿主对同一文件核心注册工具，通过 Pi 的启动事件和 DSH 的 pre-step 事件提供上下文。 | 参考其跨宿主共享工具的做法。[Agents Remember](https://github.com/Esensats/agents-remember) |
| `@letta-ai/letta-agent-sdk` | MemFS 用 Git 管理文件，常用内容随提示加载，深层资料按索引读取。 | 搜索返回短摘要，正文按 ID 读取。[Letta MemFS](https://docs.letta.com/concepts/memfs) |
| `mem0ai` | 从对话提取事实，根据用户等条件搜索，按记忆 ID 更新、删除。 | 由正在对话的 agent 主动提炼，使用明确的更新、遗忘操作。[Mem0](https://docs.mem0.ai/open-source/python-quickstart) |
| `langgraph-checkpoint-postgres`，`graphiti-core` | LangGraph Store 以 namespace 和 key 保存跨会话记录。Graphiti 从有时间和来源的事件构建可修订关系。 | 命名空间、稳定 ID、来源和内容版本。首版直接搜索已落盘的 Org 文件。[LangGraph](https://docs.langchain.com/oss/python/langgraph/add-memory) · [Graphiti](https://github.com/getzep/graphiti) |

## 安装与项目绑定

在提供本地 socket 的 Emacs 中加载 org-wiki 和支持 `:param-schemas` 的 mcp-server-lib 0.5。为每个工作区注册一个服务名。

```elisp
(require 'server)
(unless (server-running-p) (server-start))
(require 'org-wiki-memory)
(org-wiki-memory-enable "memory-wiki" (expand-file-name "~/open/org-wiki"))
```

在 Emacs 中运行 `M-x mcp-server-lib-install` 安装上游脚本。下例中的脚本路径需替换为安装后显示的绝对路径。多个 Emacs 实例可通过额外参数 `--socket=名称或绝对路径` 选择。[上游桥接说明](https://github.com/laurynas-biveinis/mcp-server-lib.el#client-registration)

### 标准 MCP 接入

在对应宿主中执行一条注册命令。项目范围由 Emacs 中的服务名绑定决定，共用同一配置的会话都会访问该工作区。

```sh
pi mcp add org-wiki-memory --local -- /absolute/path/to/emacs-mcp-stdio.sh --server-id=memory-wiki
codex mcp add org-wiki-memory -- /absolute/path/to/emacs-mcp-stdio.sh --server-id=memory-wiki
claude mcp add --scope local --transport stdio org-wiki-memory -- /absolute/path/to/emacs-mcp-stdio.sh --server-id=memory-wiki
```

DSH 可在目标 profile 配置通用 MCP 客户端。

```yaml
- insert:
    - id: org-wiki-memory-mcp
      name: "@deepseek-ai/dsh-mcp-client"
      config:
        serverName: org_wiki_memory
        transport: stdio
        command: /absolute/path/to/emacs-mcp-stdio.sh
        args: ["--server-id=memory-wiki"]
```

从旧版本迁移时，将原来的无参数 `(org-wiki-memory-enable)` 改为上面的显式绑定，重启 Emacs。将客户端配置中的 `packages/client/stdio.js` 和项目路径替换为上游脚本和服务名，并移除 Pi 和 DSH 的 org-wiki 原生插件配置。绑定到原工作区后即可读回旧记录。

### ChatGPT 桌面本地会话

在已配置的桌面应用中，打开插件目录并选择本地来源 **Org Wiki**。在新的本地 Work 会话里选择 **Org Wiki Memory**，然后输入“搜索这个项目与验收有关的记忆”。桌面插件复用五个记忆工具。将桌面插件的 stdio 命令切换到上游脚本并把项目服务绑定到 `~/open/org-wiki`，同一项目中的 Pi、DSH 和 Codex 可以读回这里保存的决定。[本地插件安装说明](https://developers.openai.com/plugins/build/plugins)

从 chatgpt.com 访问这台机器上的记忆时，可用 Secure MCP Tunnel 转发现有 stdio 命令，并在目标 ChatGPT 工作区添加自定义 MCP 服务。网页接入需要单独关联账号与隧道。[Secure MCP Tunnel](https://developers.openai.com/api/docs/guides/secure-mcp-tunnels)

## 工具和数据

| 工具 | 参数 | 返回值 |
| --- | --- | --- |
| `org_memory_remember` | `title, summary, body, category`，可选 `scope, kind, script_path, request_key` | 含 ID、内容版本和关联节点 ID 列表 `related_ids` 的记录 |
| `org_memory_search` | 至少提供 `query, category, kind` 中的一项，可选 `situation` 和 `limit`（1–50，默认 5） | 可见记忆的 ID、范围、类型、类别、标题、摘要、版本及可选脚本路径 |
| `org_memory_read` | `id`，可选 `include_script` | 正文、来源、当前版本和 `related_ids`，按需附上脚本 |
| `org_memory_update` | `id, expected_revision, title, summary, body, category`，可选 `kind, script_path, request_key` | 含 `related_ids` 的修订记录。省略的可选字段沿用旧值，传 `null` 可清除 |
| `org_memory_forget` | `id, expected_revision`，可选 `request_key` | ID 和遗忘确认 |

类别为 `fact`、`decision`、`lesson`、`preference`。范围为 `project`（默认）或 `personal`。Git worktree 共享 Git 公共目录，普通目录以真实路径区分。移动仓库会改变项目键。三个写工具都接受可选字符串 `request_key`。重试时沿用服务名、键和参数。省略该键时，Emacs 为本次调用生成新键。

一个文件保存一条记忆。新建时 Emacs 在文件头调用 `(org-id-get-create)` 生成 ID，默认使用 UUID，也遵循你的 `org-id-method` 和 `org-id-prefix`。可以把工具返回的 `id` 用于 Org 链接和后续读写。同一创建请求重试时只会保存一份文件。旧记忆继续使用原来的 `mem-…` ID。[文件 ID 与重试规则](agent-memory-design.md#由-org-生成记忆文件-id)

新建时记录原始来源，更新时保留原始来源并记录最后编辑的服务来源（`mcp/<服务名>`）。内容哈希用作版本。更新冲突时先读取最新内容再决定如何修改。Emacs 拒绝覆盖未保存的编辑，使用文件锁和同目录原子替换。遗忘后文件中仅保留遗忘操作指纹和创建键，用于辨别重试。已有聊天记录、用户备份和 Git 历史有各自的保留周期。

Emacs 为记忆检索和普通 Wiki 搜索共用 `org-wiki-search-backend` 和 `org-wiki-qmd-enabled`。按 [qmd 配置步骤](../README.md#optional-qmd-search) 完成索引初始化和同步后，将后端设为 `auto` 或 `qmd` 并启用 qmd。新写入或编辑的记忆在下次同步后进入 qmd 索引。qmd 关闭、失败或没有可用结果时，Emacs 直接搜索已保存的 Org 文件，按标题、摘要和正文匹配度排序。

客户端按需调用 `org_memory_search`。如需在涉及历史决定时优先检索，可把该要求写入项目指令。

范围规则在记忆服务上生效。普通 wiki 的五个通用只读工具仍服务于整个个人 Org 语料。需按项目提供记忆的客户端，应只挂载项目绑定的记忆工具。旧 Pi 记忆目录离线保留，切换配置不会导入或删除数据。

## 写入时关联 Org-roam 节点

Pi、DSH 和标准 MCP 客户端保存或修订记忆时，Emacs 会用记忆的标题、摘要和正文匹配已有 Org-roam 节点。写出节点标题、`ROAM_ALIASES` 别名或显式 `id:` 链接即可。匹配在本地使用已建立的 Org-roam 索引，覆盖文件节点和标题节点，包括没有 `WIKI_KIND` 的普通笔记。

假设库中已有 SQLite 节点（ID 为 `sqlite-id`，别名为“嵌入引擎”）和“来源记录”节点（ID 为 `source-id`）。用 `org_memory_remember` 保存下面这条记忆。

```json
{
  "title": "离线索引",
  "summary": "离线索引使用嵌入引擎。",
  "body": "验证依据见 [[id:source-id][实验]]。",
  "category": "decision"
}
```

正文中的显式 ID 优先于摘要中的别名，所以返回的 `related_ids` 为 `["source-id", "sqlite-id"]`。记忆文件中的链接使用目标节点的标题，每个链接附上命中处的原文片段。

```org
* Relations
- [[id:source-id][来源记录]]
  : 验证依据见 [[id:source-id][实验]]。
- [[id:sqlite-id][SQLite]]
  : 离线索引使用嵌入引擎。
```

如果多个可见节点共用一个名称，Emacs 会跳过这个名称。要指向其中一个，可以在记忆中写明它的 ID。项目记忆可关联本项目记忆、个人记忆和普通笔记。个人记忆可关联个人记忆和普通笔记。逐步匹配规则和过滤示例见[写入时的节点匹配](agent-memory-design.md#写入时的节点匹配)。

每条记忆默认最多保留 **5 个不同目标**。例如，`(setq org-wiki-memory-max-links 1)` 使上例只保留 `source-id`。设为 0 后，新建或修订的记忆会省略自动关系。

用 `org_memory_read` 查看已保存的 `related_ids`。如果记忆文件也在 Org-roam 的索引范围内，还可以打开目标节点，在反链中找到这条记忆。若目标笔记刚改过标题或别名，可先保存该笔记并运行 `M-x org-roam-db-sync`，再更新记忆以重新匹配。

## 分类与验证脚本

每条总结选一个 `kind`，直接存为 Org 属性 `WIKI_KIND`。「道」记通用规律，「法」记设计准则，「术」记具体实施。原始观察和旧客户端省略类型的写入使用 `Memory`。`category` 仍可区分事实、决策、经验和偏好。

检索时用 `query` 写主题，用 `situation` 表达当前任务。以同一个「并发写入」为例，`understand` 优先召回解释冲突成因的「道」，`design` 优先召回如何选择写入策略的「法」，`implement` 优先召回验证并发写入的「术」。Emacs 先找相关候选，再选当前情景的类型；候选中没有该类型时返回其他相关记忆。搜索也可从查询中识别明确的情景，意图混合或不明时按相关度排序。显式给出 `kind` 会严格筛选该类型。

实际跑过、值得复现的脚本保存在项目内。已有脚本直接填写仓库相对路径 `script_path`，临时脚本先保存为项目中的独立文件。摘要写验证目的，正文记录命令、预期与实际结果，需要复现特定版本时附提交号。再次验证得到相同结论时复用已有记忆。Emacs 同步 qmd 时索引所引用脚本的当前内容，搜索结果展示摘要和路径。通过 `org_memory_read` 传 `include_script=true` 可按需读取当前脚本。移动工作树或脚本后可以更新引用。

## 验证与回退

在仓库中运行 `nix develop --command make test-memory-stdio` 验证真实 stdio 接入，运行 `nix develop --command make check` 检查整个 Elisp 包。

断开记忆服务时，从客户端移除该 stdio 配置即可。已有 Org 文件可继续在 Emacs 中打开。
