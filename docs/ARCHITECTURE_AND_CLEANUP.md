# EverythingOnMac 当前架构与实现说明

本文以当前源码为准，描述 EverythingOnMac 的模块边界、索引结构、查询链路、流式全文搜索、性能策略、已知限制和后续演进方向。

> 当前代码基线：Swift tools 6.1、Swift language mode 6、最低 macOS 14。

## 1. 模块结构

```text
EverythingOnMac
├── CSearchFS
│   ├── CSearchFS.c
│   └── include/CSearchFS.h
├── EverythingOnMacCore
│   ├── Models
│   ├── Parsing
│   ├── Services
│   └── Orchestration
└── EverythingOnMac
    ├── EverythingOnMac.swift
    └── UI
```

### `CSearchFS`

封装 macOS `searchfs(2)`，按卷读取文件目录项，返回 file ID、parent ID、basename、类型、大小和修改时间。

实现使用 256 KiB 返回缓冲区，每次最多接收 1000 个匹配项。`FileIndexer` 会优先尝试该快速扫描路径，失败或不适用时退回 `FileManager` 递归枚举。

### `EverythingOnMacCore`

负责 SQLite 持久化索引、数据库迁移、basename 字符 mask、SQLite 原生正则与模糊评分函数、查询解析、FSEvents 增量更新、ripgrep 流式正文搜索、结果合并、相关性排序和 Top-K 控制。

### `EverythingOnMac`

SwiftUI App Target，负责查询输入、模式切换、排序、流式结果展示、索引/错误状态，以及双击在 Finder 中定位文件。

## 2. 启动与索引生命周期

默认索引根目录是当前用户 Home：

```swift
[URL(fileURLWithPath: NSHomeDirectory())]
```

默认排除：

```text
/System
/private/var
/Library/Caches
```

启动流程：

```text
创建 FileIndexer
→ 打开 SQLite 数据库并执行迁移
→ 读取上次 FSEvent ID
→ 从该 ID 启动 FSEvents
→ 检查数据库已有记录数
→ 非空则直接使用现有索引
→ 空库才执行全量 rebuild
```

当前数据库默认路径：

```text
~/Library/Application Support/EverythingOnMac/everything.db
```

当前判断“索引可直接使用”的依据只是 `fs_nodes` 行数大于 0，还没有独立的“索引构建完成”标记。异常中断后的半成品索引仍是后续应加强的领域。

## 3. SQLite 数据模型

当前 schema 版本：

```text
PRAGMA user_version = 5
```

### `metadata`

```sql
CREATE TABLE metadata (
    key TEXT PRIMARY KEY,
    value TEXT
);
```

目前用于保存 `last_event_id` 和 `name_mask_version`。

### `fs_nodes`

```sql
CREATE TABLE fs_nodes (
    volume_uuid TEXT,
    file_id INTEGER,
    parent_id INTEGER,
    name TEXT,
    name_character_mask INTEGER NOT NULL DEFAULT 0,
    is_directory INTEGER,
    file_extension TEXT,
    size INTEGER,
    modification_date REAL,
    uti TEXT,
    PRIMARY KEY (volume_uuid, file_id)
);
```

当前索引：

```sql
idx_fs_nodes_parent(volume_uuid, parent_id)
idx_fs_nodes_name(name)
idx_fs_nodes_extension(file_extension)
idx_fs_nodes_parent_name(volume_uuid, parent_id, name)
```

完整路径没有持久化。路径由 `volume UUID + parent_id 链 + name + 当前挂载点` 在 Swift 中动态恢复。

### 迁移历史

- v1：创建 `metadata`；
- v2：创建 `fs_nodes` 和基础索引；
- v3：增加 `(volume_uuid, parent_id, name)` 索引；
- v4：增加并回填 `name_character_mask`；
- v5：使用完整 Unicode lowercase 规则重新生成 mask，记录 `name_mask_version = 2`。

## 4. 全量索引

### 快速路径

当 `useFastVolumeScan == true` 且能够解析物理挂载点时：

```text
searchfs 全卷目录项扫描
→ 每 10,000 行批量写入 SQLite
→ 根据配置 root IDs 做递归 CTE 剪枝
→ 删除 excluded paths
```

因为 `searchfs` 是按卷扫描，所以扫描完成后必须剪除不属于配置 roots 的记录。

### 回退路径

以下情况会退回 `FileManager`：无法获得物理挂载点、`searchfs` 返回错误、root file ID 解析不完整，或数据库剪枝失败。

递归扫描使用：

```text
.skipsPackageDescendants
.skipsHiddenFiles
```

并以 10,000 条为批次写入数据库。

## 5. 增量索引

`FileSystemEventMonitor` 使用：

```text
FSEventStreamCreate
kFSEventStreamCreateFlagFileEvents
kFSEventStreamCreateFlagUseCFTypes
FSEventStreamSetDispatchQueue
```

默认 latency 为 1 秒，事件在专用串行 GCD queue 中接收。

每批事件由 `SearchCoordinator.apply()` 顺序处理：删除事件调用 `remove`，其他事件调用 `upsert`，最后保存该批最大 Event ID。

当前 `isRemoval` 只识别 `kFSEventStreamEventFlagItemRemoved`。目录重命名、事件丢失、root changed、must scan subdirs 等特殊 flag 尚未单独处理，这是可靠性方面的已知限制。

## 6. 查询语法

当前解析器支持：

```text
path:/some/directory
ext:swift
-excludedTerm
regex:true
fuzzy:true
case:true
size:>10M
size:<=512K
date:>=2026-07-01
uti:public.image
sort:relevance
sort:path
sort:filename
sort:size
sort:date
order:asc
order:desc
limit:100
offset:200
```

带空格的 token 可使用双引号：

```text
"annual report" ext:pdf
```

大小单位支持 `K`、`M`、`G`，按 1024 进制换算。日期使用 UTC 的 `yyyy-MM-dd`。

## 7. 文件名匹配模式

### Literal

默认模式。每个 term 使用：case-sensitive 时 `GLOB '*term*'`，否则 `LIKE '%term%'`。

### Regex

`regex:true` 使用 SQLite UDF：

```sql
REGEXP_LIKE(pattern, name, case_sensitive)
```

内部基于 `NSRegularExpression`，并维护最多 128 个已编译表达式缓存。

### Fuzzy

`fuzzy:true` 使用两级过滤：

```text
basename 64-bit character mask
→ FUZZY_SCORE(query, name, case_sensitive)
```

每个查询 token 独立匹配并累加分数。mask 始终使用 case-insensitive Unicode lowercase，只做粗筛；真正大小写规则由 `FUZZY_SCORE` 处理。

SQLite UDF 使用 `sqlite3_get_auxdata` / `sqlite3_set_auxdata` 缓存 prepared query。

模糊评分包括 exact、case-exact、prefix、substring、subsequence、连续字符、单词边界、camelCase 奖励，以及 gap/跨度/长度惩罚。

当前动态规划复杂度近似为：

```text
O(query length × candidate length²)
```

对 basename 通常可接受，但高命中率、超大索引仍需继续 benchmark。

## 8. 正文搜索

`RipgrepSearcher` 默认：

```text
timeout = 8 seconds
maximum stderr = 16 KiB
```

可执行文件查找顺序：

1. `RG_PATH`；
2. App Bundle resource；
3. `Contents/Resources/rg`；
4. `/opt/homebrew/bin/rg`；
5. `/usr/local/bin/rg`；
6. `/usr/bin/rg`；
7. `PATH`。

ripgrep 使用 `--json` 输出。stdout 按字节增量读取，每个 JSON line 解码后立即产生一个 `SearchResult`，不会先把完整 stdout 留在内存。

退出码 0 和 1 视为正常；其他退出码转成 typed error，并截取尾部最多 16 KiB stderr。

新搜索会终止当前活跃的 ripgrep 进程。每次搜索使用 UUID 隔离，旧任务取消不会误杀新进程。

注意：正文模式把所有普通 terms 用空格连接成一个 ripgrep pattern。它目前不是“多 token AND”正文语义。

## 9. 搜索协调与流式更新

默认执行策略：

```text
default candidate limit       5,000
maximum candidate limit      50,000
default presentation limit      500
max content excerpts/file        20
```

候选 overscan：fuzzy 为 8 倍，literal/regex 为 2 倍。候选量至少覆盖 `offset + limit`，并使用 `candidateLimit + 1` 作为截断哨兵。

流式正文结果刷新策略：

```text
第一条立即发布
之后每 32 条或 75 ms 发布一次
结束时发布尾批
```

文件名和正文结果按完整路径去重。每个文件最多保留 20 条正文摘要，但 `totalContentMatchCount` 继续累计。

最终响应包含 `results`、`indexError`、`contentError`、`isTruncated` 和 `totalCandidateCount`。

## 10. 排序与相关性

默认 UI 排序为 relevance descending。可切换 path、filename、size 和 modification date。

相关性评分综合：

- 每个文件名 token 的 fuzzy score；
- 正文命中基础分；
- 最多 5 次正文命中的有限奖励；
- 前 3 条正文摘要的行/列位置奖励；
- 路径长度惩罚；
- 文件名与正文同时命中的 hybrid bonus。

稳定 tie-breaker 使用 filename 和 path。

### 当前 `sort:path` 限制

完整路径未持久化，因此路径排序必须先在 Swift 中恢复路径，再对候选池排序。超过最大候选池时，只保证候选池内顺序正确，并通过 `isTruncated` 提示。

后续可保留 parent/file ID 结构，同时增加物化 `canonical_path` / `normalized_path`，把全局路径排序和分页下推到 SQLite。

## 11. UI 行为

- 查询输入 debounce：160 ms；
- 默认混合模式；
- 默认相关性降序；
- 流式更新 List；
- 截断时显示提示；
- index/ripgrep 错误显示在界面；
- 双击结果在 Finder 中定位。

当前搜索框 placeholder 只列出部分语法，未完整展示 fuzzy、size、date、sort、limit 等能力。

## 12. 错误处理

索引错误：

```swift
FileIndexSearchError.invalidPathPrefix
FileIndexSearchError.databaseError
```

ripgrep 错误：

```swift
executableUnavailable
launchFailed
timedOut
cancelled
failed(exitCode:stderr:)
```

两类错误分开进入 `SearchResponse`，避免把“查询失败”伪装成“零结果”。

索引构建和增量写入的若干路径仍使用 `try?`，写入失败可能被静默忽略；这是后续应加强的可靠性问题。

## 13. 已知技术限制

1. 完整路径未物化，`sort:path` 不是无限集合上的数据库级全局排序。
2. FSEvents 尚未处理 must-scan、root-changed、event-ID wrap 等恢复策略。
3. 启动仅用行数判断索引是否可用，没有 build-generation/complete marker。
4. `SearchViewModel` 初始化数据库失败会 `fatalError`，尚无可恢复 UI。
5. C `searchfs` 路径使用固定 512-byte basename buffer，超长名称可能被跳过或截断。
6. `APFSVolumeInspector.supportsSearchFS` 当前固定为 `false`，并未反映实际快速扫描尝试。
7. App 默认没有图标、正式签名、公证或 sandbox entitlements。
8. 打包脚本嵌入当前主机架构的 executable 和 `rg`，不是自动 universal build。
9. benchmark 目前仍位于普通测试套件，性能阈值不应被视为稳定 SLA。

## 14. 当前验证基线

当前完整测试套件为 35 项，覆盖 SQLite schema/migration、索引扫描和过滤、排序分页、pathPrefix CTE、character mask、Unicode case folding、fuzzy score、多 token、错误传播、ripgrep timeout/stderr/流式输出、流式 batching 与结果合并。

测试数量和耗时会随后续变更而变化，不应被视为长期固定的产品性能承诺。
