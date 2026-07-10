# EverythingOnMac

适用于 Mac OS 的本地文件与文本内容极速搜索应用，目标体验参考 Everything + Total Commander。

## 当前实现（MVP 基线）

- 文件名/路径索引搜索（内存索引，支持排除目录）
- APFS 友好的元数据采集：通过 macOS `statfs`/URL resource values 读取卷格式、持久 File ID 能力，并在索引中保留文件系统资源标识
- FSEvents 增量监听：macOS 下监听文件创建、修改、删除并增量更新索引
- ripgrep 正文检索通道（自动发现 `rg`，支持 `RG_PATH`/PATH 环境变量覆盖，结构化 JSON 结果解析）
- 混合查询编排（文件索引结果 + 正文命中结果合并）
- SwiftUI macOS 原生界面（双击在 Finder 中定位）
- 查询语法支持：
  - `path:/some/dir`
  - `ext:swift`
  - `-excludeTerm`
  - `regex:true`
  - `case:true`

## 架构分层

- `EverythingOnMacCore`
  - `Parsing/QueryParser.swift`：查询表达式解析
  - `Services/FileIndexer.swift`：文件索引扫描、文件名查询、增量 upsert/remove
  - `Services/APFSVolumeInspector.swift`：APFS/卷能力探测，用于展示当前索引根目录的文件系统能力
  - `Services/FileSystemEventMonitor.swift`：macOS FSEvents 监听，驱动索引增量刷新
  - `Services/RipgrepSearcher.swift`：rg 调用与正文命中解析
  - `Orchestration/SearchCoordinator.swift`：双通道查询、结果融合、索引更新编排
- `EverythingOnMac`
  - `UI/ContentView.swift`：主界面
  - `UI/SearchViewModel.swift`：UI 状态、节流、触发查询、文件系统事件接入

## 运行

> 需要在 macOS 环境运行 UI。Linux 环境可构建核心库并运行测试。

```bash
swift build
swift test
swift run EverythingOnMac
```

`rg` 会按如下顺序自动发现：`RG_PATH`、`/opt/homebrew/bin/rg`、`/usr/local/bin/rg`、`/usr/bin/rg`，最后回退到 PATH 中的 `rg`。

## 下一步

- 持久化索引（SQLite/LMDB）以支持百万级文件冷启动
- 增加结果分页/排序策略与更多过滤条件（大小、时间、UTType）
- 增强权限与发布策略（Full Disk Access / 沙盒策略）
