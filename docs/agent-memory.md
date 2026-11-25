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
| `org_memory_remember` | `title, summary, body, category`，可选 `scope, kind, script_path` | 含 ID、内容版本和关联节点 ID 列表 `related_ids` 的记录 |
| `org_memory_search` | 至少提供 `query, category, kind` 中的一项，可选 `situation` 和 `limit`（1–50，默认 5） | 可见记忆的 ID、范围、类型、类别、标题、摘要、版本及可选脚本路径 |
| `org_memory_read` | `id`，可选 `include_script` | 正文、来源、当前版本和 `related_ids`，按需附上脚本 |
| `org_memory_update` | `id, expected_revision, title, summary, body, category`，可选 `kind, script_path` | 含 `related_ids` 的修订记录。省略的可选字段沿用旧值，传 `null` 可清除 |
| `org_memory_forget` | `id, expected_revision` | ID 和遗忘确认 |

类别为 `fact`、`decision`、`lesson`、`preference`。范围为 `project`（默认）或 `personal`。宿主给后端提供当前会话、工具调用 ID 和工作区。Git worktree 共享同一实际 Git common directory；普通目录以真实路径区分。移动仓库会改变它的项目键。Pi 和 DSH 均从当前会话取路径，适用于同一台机器和同一用户。

一个文件保存一条记忆。新建时 Emacs 在文件头调用 `(org-id-get-create)` 生成 ID，默认使用 UUID，也遵循你的 `org-id-method` 和 `org-id-prefix`。可以把工具返回的 `id` 用于 Org 链接和后续读写。同一创建请求重试时只会保存一份文件。旧记忆继续使用原来的 `mem-…` ID。[文件 ID 与重试规则](agent-memory-design.md#由-org-生成记忆文件-id)

新建时记录原始来源，更新时保留原始来源并记录最后编辑的宿主与会话。内容哈希用作版本。更新冲突时先读取最新内容再决定如何修改。插件拒绝覆盖未保存的编辑，使用文件锁和同目录原子替换。遗忘后文件中仅保留遗忘操作指纹和创建键，用于辨别重试。已有聊天记录、用户备份和 Git 历史有各自的保留周期。

Emacs 为记忆检索和普通 Wiki 搜索共用 `org-wiki-search-backend` 和 `org-wiki-qmd-enabled`。按 [qmd 配置步骤](../README.md#optional-qmd-search) 完成索引初始化和同步后，将后端设为 `auto` 或 `qmd` 并启用 qmd。新写入或编辑的记忆在下次同步后进入 qmd 索引。qmd 关闭、失败或没有可用结果时，Emacs 直接搜索已保存的 Org 文件，按标题、摘要和正文匹配度排序。

Pi 和 DSH 在会话首轮自动检索，最多注入五条摘要，共 2,000 个 UTF-16 代码单元。Pi 将摘要作为隐藏的自定义消息记入会话，DSH 使用带来源的消息。当用户要求记住某件事，或模型判断当前结论值得保存时，模型调用 `org_memory_remember` 才会新建记忆；对已有条目的修订通过 `org_memory_update` 写入。Emacs 离线时宿主可继续会话，工具写入返回错误。下一次工具调用会重新连接。

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

检索时用 `query` 写主题，用 `situation` 表达当前任务。以同一个「并发写入」为例，`understand` 优先召回解释冲突成因的「道」，`design` 优先召回如何选择写入策略的「法」，`implement` 优先召回验证并发写入的「术」。Emacs 先找相关候选，再选当前情景的类型；候选中没有该类型时返回其他相关记忆。首轮自动召回从提示中识别明确的情景，意图混合或不明时按相关度排序。显式给出 `kind` 会严格筛选该类型。

实际跑过、值得复现的脚本保存在项目内。已有脚本直接填写仓库相对路径 `script_path`，临时脚本先保存为项目中的独立文件。摘要写验证目的，正文记录命令、预期与实际结果，需要复现特定版本时附提交号。再次验证得到相同结论时复用已有记忆。Emacs 同步 qmd 时索引所引用脚本的当前内容，首轮召回展示摘要和路径。通过 `org_memory_read` 传 `include_script=true` 可按需读取当前脚本。移动工作树或脚本后可以更新引用。

## 验证与回退

在 Nix 开发环境中执行 `make check`，在 Node 环境执行 `npm ci && npm test`。后者启动临时 Emacs socket，验证宿主适配器和 MCP 客户端跨会话读写。设置 `ORG_WIKI_TEST_PI=pi` 将真实 Pi CLI 与离线测试 provider 纳入同一测试。将 `ORG_WIKI_TEST_DSH` 设为能解析宿主 node_modules 的 DSH 安装目录，会额外验证真实 Cordis 的工具注册、执行与 pre-step 注入。

人工验收可在项目 A 让 Pi 记下一条带唯一标记的项目决定，在 DSH 新会话召回并纠正它，回到 Pi 的新会话核对，再从项目 B 按原 ID 读取，应该收到 `unknown_id`。回退时从 Pi 包列表和 DSH patch 移除新入口，重载宿主，并按需恢复此前的包列表。
