# qmd CLI 契约与验证

本文供维护者复现 `org-wiki-qmd.el` 的外部程序契约。qmd **2.8.3（facd35e）** 和 **2.9.0** 均使用下方的无模型集成检查验证。支持新版本前须重新运行真实 CLI 检查。

## 隔离与配置

每个知识库有独立的缓存、配置和数据库。所有进程使用参数列表运行，不经过 shell。适配器显式传入 `--index NAME`，并为子进程设置以下路径：

| 设置 | 集成拥有的路径 |
| --- | --- |
| 工作目录和 `PWD` | 知识库专用派生缓存目录 |
| `QMD_CONFIG_DIR` | 缓存下的 `config/` |
| `INDEX_PATH` | 缓存下的 `qmd/index.sqlite` |
| `XDG_CACHE_HOME` | 缓存下的 `runtime/` |

setup 生成 JSON 格式的 YAML 配置，仅声明专用 collection、`nodes/` 目录和 `*.md` mask，不包含更新钩子。实测 `qmd update` 能从此配置创建并更新 collection。配置摘要写入 setup 状态；配置变化后搜索和同步均要求重新 setup，避免执行额外 collection 或更新钩子。重复 setup 不开启搜索，也不使已有的完整索引失效；中断的 setup 可重试。

`update` 会更新配置中的所有 collection，因此隔离配置是必要条件，不能仅靠搜索时的 `-c` 选项。知识库身份、索引名和 collection 一起记录在缓存拥有者文件中。

## 搜索参数和输出

适配器采用以下命令形式；`NAME`、`COLLECTION`、`COUNT` 和 `QUERY` 分别由配置、结果上限和查询字符串替换：

```text
qmd --index NAME search --format json -c COLLECTION -n COUNT -- QUERY
```

`vsearch` 和 `query` 使用相同的结果输出与 collection 参数。所有选项放在 `--` 前，整段查询作为最后一个参数，支持空格、引号、中文、`$` 和以 `-` 开头的字符串。关键词语法由 qmd 解释；以 `-` 开头的关键词可能表示排除词，但不会被解释为 CLI 选项。

实测 JSON 顶层为数组，空命中为 `[]`，成功退出码为 0。每项包含 `docid`、`score`、`file`、`line`、`title` 和 `snippet`。适配器保留数组顺序，只使用 `file` 映射 canonical ID，不把分数或片段暴露为 Org 正文。允许无关新增字段。

实测命名索引的文件字段形如 `qmd://wiki/HASH.md?index=wiki-test`。只接受专用 collection、当前索引和 manifest 中的安全缓存文件名；目录穿越、其他 collection、其他索引及未知缓存文件均被排除。默认名为 `index` 的索引可省略查询参数。

真实关键词输出保存在 [qmd 2.8.3 搜索 fixture](qmd-search-result-2.8.3.json)。该 fixture 使用临时测试语料，不包含个人知识库内容。

## 模型与就绪状态

关键词检查不准备模型，也不访问网络。向量模式要求在 `org-wiki-qmd-models` 中显式提供预下载的本地 GGUF 路径：`vsearch` 需要 `:embed` 和用于查询扩展的 `:generate`，`query` 还需要 `:rerank`。显式 embedding 维护只需要 `:embed`。适配器在搜索前检查所需模型，并为子进程显式设置相应模型变量，不沿用调用者的远程模型配置。

embed 通过 `qmd embed -c COLLECTION` 维护向量；模型摘要变化或没有可信的上次成功记录时增加 `--force`。qmd 自身的向量指纹不包含模型文件的大小或修改时间，因此原路径替换模型也必须重建。成功后记录文档代次和本地模型路径、大小及修改时间的摘要；开始 embedding 前清除旧模型记录，防止中断后将部分更新的向量当作可复用数据。搜索前检查模型存在且摘要相同；缺少 embedding、文件丢失或模型配置变化均回退，不在查询中下载模型。每次 sync 保守地取消向量就绪状态，需要重新 embed，但保留模型记录以便模型未变时继续增量维护。

维护锁记录启动器及其子进程，并检查启动器独立进程组中的成员，覆盖启动器先退出、子进程被重新托管的情况。启动器退出不代表维护结束；仍有活跃子进程时保留锁，标记 Emacs 任务已退出。只有子进程均结束后，后续维护才能接管该锁。

## 复现检查

将待验证版本的 qmd 放在 PATH 中，在项目开发环境中运行无模型检查。

```sh
make test-qmd-integration
```

检查覆盖隔离 setup、真实 JSON、参数边界、节点过滤、Emacs/MCP/gptel 一致性、ID 读取与跳转、新 Emacs 进程中的未完成状态检测，以及删除同步。

准备三个本地 GGUF 模型后，设置以下环境变量并运行语义检查。将每个 `ABSOLUTE_*_PATH` 替换为对应模型的绝对路径：

```sh
export ORG_WIKI_QMD_EMBED_MODEL=ABSOLUTE_EMBED_MODEL_PATH
export ORG_WIKI_QMD_GENERATE_MODEL=ABSOLUTE_GENERATE_MODEL_PATH
export ORG_WIKI_QMD_RERANK_MODEL=ABSOLUTE_RERANK_MODEL_PATH
make test-qmd-semantic
```

确认检查打印 `qmd integration: ... passed`。该检查使用独立临时索引，不修改已有 qmd 配置或数据库。语义检查验证小语料中的近义问句召回；完整的中英文 Recall@10 和性能评估仍需代表性查询集。
