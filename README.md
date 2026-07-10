# EverythingOnMac

适用于 macOS 的本地文件与文本内容快速搜索工具，目标是提供类似 Windows Everything + Total Commander 的体验。

## 当前实现

- **Swift 原生架构**：使用 Swift 构建核心搜索引擎（可直接扩展为 macOS App UI 层）
- **APFS 友好索引**：扫描文件时读取 `fileResourceIdentifier`、卷格式描述等元数据，用于快速定位与后续增量索引扩展
- **rg 内容检索集成**：通过 ripgrep(`rg --json`) 做高性能正文搜索，并与文件元信息合并输出
- **文件信息 + 正文联合搜索**：支持仅文件名、仅正文、文件名+正文交集检索

## 运行方式

```bash
swift run EverythingOnMac --root /Users/you/Documents --name report --content invoice --limit 500
```

参数说明：

- `--root <path>`：搜索根目录（默认当前目录）
- `--name <keyword>`：按文件名过滤
- `--content <text>`：按正文内容搜索（依赖本机安装 `rg`）
- `--hidden`：包含隐藏文件
- `--limit <number>`：最大索引文件数（默认 200）

## 测试

```bash
swift test
```
