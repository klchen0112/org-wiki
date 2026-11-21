# Pi 与 DeepSeek Harness 共享 Org 记忆

Pi 和 DSH 可以通过标准 MCP 共享项目决定与个人偏好，也可以使用原生插件自动召回。两种方式都把记忆保存在 Emacs 的 `org-wiki-root/agent-memory/`，可直接编辑 Org 文件。接入选择、调用链路及存储边界见[共享记忆设计](agent-memory-design.md)。

## 实现依据

| 软件包 | 记忆如何工作 | 本项目采用的部分 |
| --- | --- | --- |
| `pi-memory`，`@zosmaai/pi-llm-wiki` | 前者维护 Markdown 长期记忆、日志和草稿，并可借助 qmd 检索。后者把来源和观察整理为可复用页面，支持个人与项目召回。 | 可编辑文件、项目与个人范围、来源字段。[Pi Memory](https://github.com/jayzeng/pi-memory) · [Pi LLM Wiki](https://github.com/zosmaai/pi-llm-wiki) |
| `@seangle/pi-remember`，`@seangle/dsh-remember` | 两个宿主对同一文件核心注册工具，通过 Pi 的启动事件和 DSH 的 pre-step 事件提供上下文。 | 宿主只负责会话身份、工具和首轮注入。[Agents Remember](https://github.com/Esensats/agents-remember) |
| `@letta-ai/letta-agent-sdk` | MemFS 用 Git 管理文件，常用内容随提示加载，深层资料按索引读取。 | 首轮注入短摘要，正文按 ID 读取。[Letta MemFS](https://docs.letta.com/concepts/memfs) |
| `mem0ai` | 从对话提取事实，根据用户等条件搜索，按记忆 ID 更新、删除。 | 由正在对话的 agent 主动提炼，使用明确的更新、遗忘操作。[Mem0](https://docs.mem0.ai/open-source/python-quickstart) |
| `langgraph-checkpoint-postgres`，`graphiti-core` | LangGraph Store 以 namespace 和 key 保存跨会话记录。Graphiti 从有时间和来源的事件构建可修订关系。 | 命名空间、稳定 ID、来源和内容版本。首版直接搜索已落盘的 Org 文件。[LangGraph](https://docs.langchain.com/oss/python/langgraph/add-memory) · [Graphiti](https://github.com/getzep/graphiti) |

## 安装

本仓库提供三个本地 npm workspace。下例使用绝对路径，依赖 Node 24、Git、Emacs、org-wiki 及 mcp-server-lib 0.4 或更新版本。先在仓库根目录运行 `npm ci`。Pi 1.5.2 和 DSH 0.2.1-rc.3 是本版验证目标。

在提供本地 socket 的 Emacs 初始化文件中启用后端。记忆服务只需注册一次。

```elisp
(add-to-list 'load-path "/absolute/path/to/org-wiki")
(require 'server)
(unless (server-running-p) (server-start))
(require 'org-wiki-memory)
(org-wiki-memory-enable)
```

插件通过 PATH 上的 `emacsclient` 自动定位当前 Emacs 安装的 stdio 脚本。自定义安装可以将 `ORG_WIKI_MEMORY_BRIDGE` 设为已安装脚本的绝对路径。有多个 Emacs 时，`ORG_WIKI_MEMORY_SOCKET` 可指定目标 socket 的名称或绝对路径。DSH Web 服务需要能访问同一 socket。[上游桥接说明](https://github.com/laurynas-biveinis/mcp-server-lib.el#client-registration)

### 标准 MCP 接入

在目标项目的根目录运行以下命令，Pi 会把服务登记到当前项目的 `.pi/mcp.json`。最后一个参数绑定记忆的项目范围。

```sh
pi mcp add org-wiki-memory --local -- /absolute/path/to/org-wiki/packages/client/stdio.js "$PWD"
```

DSH 可将同一入口交给其 MCP 客户端，在目标 profile 加载下面的 Cordis overlay。一个服务实例绑定一个项目。

```yaml
- insert:
    - id: org-wiki-memory-mcp
      name: "@deepseek-ai/dsh-mcp-client"
      config:
        serverName: org_wiki_memory
        transport: stdio
        command: /absolute/path/to/org-wiki/packages/client/stdio.js
        args: ["/absolute/path/to/project"]
```

### 原生插件接入

**Pi** 可在该 checkout 执行 `pi -e "$PWD/packages/pi/index.ts"` 试用。持久安装用 `pi install /absolute/path/to/org-wiki/packages/pi`，使用 Nix 管理 Pi 时，把该目录加入声明式包列表。切换到唯一记忆实现时，移除原列表中的 `npm:pi-memory` 和 `pi-llm-wiki` 路径。宿主现用的通用 MCP 适配器可以继续提供其他服务。[Pi 扩展](https://docs.pi.dev/latest/extensions)

**DSH** 使用 Cordis 宿主插件。在所选 profile 的 Cordis patch 列表追加下列条目。同时给 tui 和 web 启用时，在用户级 `$DSH_HOME/cordis.patch.yml` 注册一次即可（默认目录为 `~/.dsh`）。对应的 Home Manager 选项是 `programs.dsh.patch`。Nix 启动器可能重建 managed profile 内的文件。绝对入口让 Node 从本 checkout 的 workspace 解析依赖。可先用 `dsh --profile nix-tui --patch /absolute/path/overlay.yml --dump-config` 检查组合。

```yaml
- insert:
    - id: org-wiki-memory
      name: /absolute/path/to/org-wiki/packages/dsh/index.js
```

DSH 自带的 `@deepseek-ai/dsh-mcp-client` 也可以启动下述项目绑定的 stdio 命令，提供按需工具。需要自动摘要的 tui/web profile 使用原生插件，只挂载一份工具。[DSH 记忆 MCP 配置](https://deepseek-harness.github.io/deepseek-harness/guide/mcp-memory)

### 其他 MCP 客户端

Codex 和 Claude Code 可直接连接项目绑定的 stdio 入口。最后一个参数是会话要访问的工作区。请按项目注册，尤其是宿主同时服务多个仓库时。

```sh
codex mcp add org-wiki-memory -- /absolute/path/to/org-wiki/packages/client/stdio.js /absolute/path/to/project
claude mcp add --scope local --transport stdio org-wiki-memory -- /absolute/path/to/org-wiki/packages/client/stdio.js /absolute/path/to/project
```

[Codex MCP](https://developers.openai.com/codex/mcp) · [Claude Code MCP](https://code.claude.com/docs/en/mcp)

## 工具和数据

| 工具 | 参数 | 返回值 |
| --- | --- | --- |
| `org_memory_remember` | `title, summary, body, category`，可选 `scope` | 含 ID 和内容版本的记录 |
| `org_memory_search` | `query`，可选 `limit`（1–50，默认 5） | 可见记录的摘要、版本与 ID |
| `org_memory_read` | `id` | 正文、来源、当前版本 |
| `org_memory_update` | `id, expected_revision, title, summary, body, category` | 修订后的记录 |
| `org_memory_forget` | `id, expected_revision` | ID 和遗忘确认 |

类别为 `fact`、`decision`、`lesson`、`preference`。范围为 `project`（默认）或 `personal`。宿主给后端提供当前会话、工具调用 ID 和工作区。Git worktree 共享同一实际 Git common directory；普通目录以真实路径区分。移动仓库会改变它的项目键。Pi 和 DSH 均从当前会话取路径，适用于同一台机器和同一用户。

一个文件保存一条记忆。新建时记录原始来源，更新时保留原始来源并记录最后编辑的宿主与会话。内容哈希用作版本。更新冲突时先读取最新内容再决定如何修改。插件拒绝覆盖未保存的编辑，使用文件锁和同目录原子替换。遗忘后原文件仅包含操作指纹，可用于辨别重试。已有聊天记录、用户备份和 Git 历史有各自的保留周期。

默认召回最多五条、共 2,000 个 UTF-16 代码单元。首轮无匹配时跳过注入。搜索按同范围内的标题、摘要、正文匹配度排序，支持英文词和中文相邻字对。写入后立即可检索，无需启动 qmd 或额外模型。记忆摘要属于背景资料，Pi 将其作为隐藏的自定义消息记入会话，DSH 使用带来源的消息。Emacs 离线时宿主可继续会话，工具写入返回错误；下一次工具调用会重新连接。

范围规则在记忆服务上生效。普通 wiki 的五个通用只读工具仍服务于整个个人 Org 语料。需按项目提供记忆的客户端，应只挂载项目绑定的记忆工具。旧 Pi 记忆目录离线保留，切换配置不会导入或删除数据。

## 验证与回退

在 Nix 开发环境中执行 `make check`，在 Node 环境执行 `npm ci && npm test`。后者启动临时 Emacs socket，验证宿主适配器和 MCP 客户端跨会话读写。设置 `ORG_WIKI_TEST_PI=pi` 将真实 Pi CLI 与离线测试 provider 纳入同一测试。将 `ORG_WIKI_TEST_DSH` 设为能解析宿主 node_modules 的 DSH 安装目录，会额外验证真实 Cordis 的工具注册、执行与 pre-step 注入。

人工验收可在项目 A 让 Pi 记下一条带唯一标记的项目决定，在 DSH 新会话召回并纠正它，回到 Pi 的新会话核对，再从项目 B 按原 ID 读取，应该收到 `unknown_id`。回退时从 Pi 包列表和 DSH patch 移除新入口，重载宿主，并按需恢复此前的包列表。
