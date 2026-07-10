# EverythingOnMac

适用于 Mac OS 的本地文件与文本内容极速搜索应用，目标体验参考 Everything + Total Commander。

## 当前实现（MVP 基线）

- 文件名/路径索引搜索（内存索引，支持排除目录）
- ripgrep 正文检索通道（结构化 JSON 结果解析）
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
  - `Services/FileIndexer.swift`：文件索引扫描与文件名查询
  - `Services/RipgrepSearcher.swift`：rg 调用与正文命中解析
  - `Orchestration/SearchCoordinator.swift`：双通道查询与结果融合
- `EverythingOnMac`
  - `UI/ContentView.swift`：主界面
  - `UI/SearchViewModel.swift`：UI 状态、节流、触发查询

## 运行

> 需要在 macOS 环境运行 UI。

```bash
swift build
swift test
swift run EverythingOnMac
```

如果你安装的 ripgrep 不在 `/opt/homebrew/bin/rg`，请调整 `SearchViewModel.swift` 中的路径。

## 下一步

- 引入文件系统事件监听，实现实时增量更新索引
- 增加结果分页/排序策略与更多过滤条件（大小、时间、UTType）
- 增强权限与发布策略（Full Disk Access / 沙盒策略）
