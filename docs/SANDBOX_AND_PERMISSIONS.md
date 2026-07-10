# EverythingOnMac 权限、Sandbox 与发布边界

本文以当前源码和打包脚本为准，说明 EverythingOnMac 的实际权限模型，以及启用 App Sandbox 时需要重新设计的部分。

## 1. 当前实际状态

当前 `scripts/build_app.sh`：

- 使用 ad-hoc 签名；
-没有 `.entitlements`；
-没有启用 App Sandbox；
- `Info.plist` 没有 Desktop/Documents/Downloads 等 Usage Description；
-默认索引当前用户 Home；
-会通过 `Process` 启动 `ripgrep`；
-会通过 FSEvents 监听配置 roots。

因此当前产物是一个非沙盒、本机开发测试 App，不是 Mac App Store 架构。

## 2. TCC 与完全磁盘访问权限

macOS TCC 可能限制：

- Desktop；
- Documents；
- Downloads；
- Mail；
- Messages；
- Safari 数据；
-其他隐私敏感目录。

当前索引器对读取失败的很多路径会跳过，部分写入/扫描错误还使用 `try?`，所以权限不足通常表现为“索引遗漏”，而不一定出现显式弹窗。

本机开发测试可在：

```text
系统设置
→ 隐私与安全性
→ 完全磁盘访问权限
→ 添加 EverythingOnMac.app
```

授权后完全退出并重启 App。

注意：

- Full Disk Access 不会自动解决 App Sandbox 的容器限制；
- ad-hoc 重新签名后，TCC 可能把新构建视为不同代码身份；
-当前 UI 没有自动检测权限或引导授权。

## 3. 当前 Info.plist 与 Usage Description

当前打包脚本只写入基础 Bundle 信息，没有以下键：

```xml
NSDesktopFolderUsageDescription
NSDocumentsFolderUsageDescription
NSDownloadsFolderUsageDescription
NSRemovableVolumesUsageDescription
NSNetworkVolumesUsageDescription
```

是否需要这些键取决于最终分发方式和访问 API。正式产品应根据实际访问范围添加准确说明，但 Usage Description 本身不等于授权，也不能替代用户选择目录、security-scoped bookmark 或 Full Disk Access。

示例：

```xml
<key>NSDocumentsFolderUsageDescription</key>
<string>EverythingOnMac 需要读取您选择的文档目录以建立本地文件名和正文索引。</string>
```

不要声明应用实际并不访问的目录。

## 4. 为什么不能直接给当前 App 加 Sandbox

当前架构默认扫描整个 Home，并依赖：

- `searchfs` 全卷目录扫描；
- `FileManager` 递归枚举；
- FSEvents 监听 root；
- `Process` 启动 `rg`；
-跨启动访问同一目录。

开启 App Sandbox 后，应用不能因为声明一个 entitlement 就任意访问 Home。通常需要：

1. 用户通过 `NSOpenPanel` 明确选择目录；
2. 使用 `com.apple.security.files.user-selected.read-write` 或 read-only；
3. 保存 security-scoped bookmark；
4. 下次启动解析 bookmark 并调用 `startAccessingSecurityScopedResource()`；
5. 只在授权目录内索引和搜索。

因此 Sandbox 不是单纯“补一个 plist”即可完成，而是产品交互和索引生命周期改造。

## 5. 推荐的沙盒目录授权模型

### 首次运行

```text
显示 NSOpenPanel
→ 用户选择一个或多个 roots
→ 创建 security-scoped bookmarks
→ 持久化 bookmark data
→ 对 roots 建索引
```

### 后续启动

```text
读取 bookmark
→ 解析 stale 状态
→ startAccessingSecurityScopedResource
→ 启动索引和 FSEvents
→ 退出时 stopAccessingSecurityScopedResource
```

需要处理：

- bookmark stale；
-目录被移动或删除；
-外置卷未挂载；
-授权被撤销；
-多个 root 的独立状态。

## 6. 建议 entitlements

若采用用户选择目录的 Sandbox 模型，基础文件可类似：

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.app-sandbox</key>
    <true/>

    <key>com.apple.security.files.user-selected.read-only</key>
    <true/>

    <key>com.apple.security.files.bookmarks.app-scope</key>
    <true/>
</dict>
</plist>
```

当前索引器只需要读取文件内容和元数据时，应优先 read-only，而不是 read-write。

### 不应误用 `com.apple.security.inherit`

`com.apple.security.inherit` 主要用于由沙盒父进程启动、并继承其 sandbox profile 的辅助 executable。它不是“允许主 App 启动任意外部命令”的通用开关，不应放在主 App entitlement 中作为 `Process` 权限解决方案。

### 不建议依赖 temporary exception

类似：

```xml
com.apple.security.temporary-exception.shared-system-directory.read-only
```

不是访问 `/usr/local/bin` 或任意外部工具的通用方案。temporary exception 会增加审核和长期维护风险，不应作为核心架构。

## 7. ripgrep 在 Sandbox 中的处理

最稳妥方式是把 `rg` 作为 App 内受签名管理的辅助 executable：

```text
EverythingOnMac.app/Contents/Resources/rg
```

但仅复制文件并不等于完整发布方案。正式签名时应：

-确认 `rg` 架构；
-确认代码签名顺序；
-确保 Hardened Runtime 下可执行；
-确认其访问路径处于用户授权 scope 内；
-确认许可证和分发义务。

当前 `RipgrepSearcher` 会优先找 Bundle 内的 `rg`，这是正确方向。

## 8. FSEvents 与 Sandbox

即使有 security-scoped access，也应验证 FSEvents 是否能持续返回授权 root 下的事件。

当前实现没有处理：

- `MustScanSubDirs`；
- `UserDropped` / `KernelDropped`；
- `RootChanged`；
- Event ID wrap；
- bookmark 失效后的重新授权。

正式沙盒版需要在这些情况下触发局部或完整重建。

## 9. Direct Distribution 与 Mac App Store

### Direct Distribution

较适合当前全盘搜索方向：

-非沙盒或受控 sandbox；
- Developer ID Application 签名；
- Hardened Runtime；
-公证；
-用户手动授予 Full Disk Access。

仍应尽量缩小扫描范围，并提供清晰权限说明。

### Mac App Store

需要严格 Sandbox。当前“默认扫描整个 Home + 全卷 searchfs”模式与商店沙盒不直接兼容，必须改成用户选择 roots 和 security-scoped bookmarks。

## 10. 当前打包脚本缺失项

`scripts/build_app.sh` 当前没有：

- entitlements 参数；
- Usage Description；
- Hardened Runtime；
- Developer ID；
- notarization；
- stapling；
-图标；
-权限检测 UI。

正式签名示意：

```bash
codesign --force --options runtime \
  --entitlements EverythingOnMac.entitlements \
  --sign "Developer ID Application: NAME (TEAMID)" \
  ./dist/EverythingOnMac.app
```

正式流程不应简单依赖 `--deep`，而应先签内嵌 executable，再签主 Bundle。

## 11. 推荐实施顺序

1. 明确分发渠道；
2. Direct Distribution 先完善 Full Disk Access 检测和说明；
3. 如需 Sandbox，先实现 root picker；
4. 加入 security-scoped bookmarks；
5. 将默认 roots 从 Home 改为用户授权 roots；
6.验证 FSEvents、SQLite 和 ripgrep 均在 scope 内运行；
7. 增加 entitlements 和 Usage Description；
8.配置正式签名、公证和跨机器测试。

## 12. 安全原则

-不请求超出功能所需的权限；
-索引数据只保存在本地；
-明确告诉用户哪些目录正在被索引；
-允许移除 root 和删除其索引；
-不要把 Full Disk Access 当作默认必需条件，除非产品明确定位为全盘搜索；
-不要通过 temporary exception 绕过合理的用户授权模型。
