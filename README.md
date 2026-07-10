# EverythingOnMac

macOS 本地文件名与正文搜索应用，目标体验参考 Everything 与 Total Commander。

## 当前实现

- SQLite 持久化文件索引，默认数据库位于 `~/Library/Application Support/EverythingOnMac/everything.db`
- `searchfs` 全卷快速扫描，失败时回退 `FileManager` 递归枚举
- FSEvents 增量监听并保存最后 Event ID
- literal、regex、fuzzy 三种文件名匹配模式
- SQLite 自定义函数：`REGEXP_LIKE`、`CHARACTER_MASK`、`FUZZY_SCORE`
- ripgrep JSON 流式正文搜索，支持 timeout、取消和错误传播
- 文件名与正文结果流式合并、相关性排序、Top-K 展示
- SwiftUI 原生界面，双击在 Finder 中定位
- Release `.app` 与 `.zip` 打包脚本

## 查询语法

```text
path:/some/dir
ext:swift
-excludedTerm
regex:true
fuzzy:true
case:true
size:>10M
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

示例：

```text
report fuzzy:true ext:pdf sort:relevance limit:50
```

## 架构

```text
CSearchFS              searchfs C 封装
EverythingOnMacCore    索引、查询、FSEvents、ripgrep、协调器
EverythingOnMac        SwiftUI App
```

详细说明：

- [当前架构与实现](docs/ARCHITECTURE_AND_CLEANUP.md)
- [编译与打包 App](docs/BUILD_AND_PACKAGE_APP.md)
- [权限与 Sandbox](docs/SANDBOX_AND_PERMISSIONS.md)

## 构建与测试

要求 macOS 14+、Swift tools 6.1 对应工具链。

```bash
swift build
swift test
swift run EverythingOnMac
```

## 打包 `.app`

```bash
./scripts/build_app.sh
```

输出：

```text
dist/EverythingOnMac.app
dist/EverythingOnMac.zip
```

当前脚本生成本机架构、ad-hoc 签名的开发测试版本，不是 Developer ID 公证或 universal 发行版。

## ripgrep 查找顺序

1. `RG_PATH`
2. App Bundle Resources
3. `/opt/homebrew/bin/rg`
4. `/usr/local/bin/rg`
5. `/usr/bin/rg`
6. `PATH`

## 当前主要限制

-完整路径未持久化，超大结果集的 `sort:path` 只保证候选池内正确
- FSEvents 尚未完整处理事件丢失和强制重扫 flag
-启动只按数据库行数判断索引是否可用
-当前 App 没有正式签名、公证、图标或 Sandbox entitlements
-默认打包不是 universal binary
