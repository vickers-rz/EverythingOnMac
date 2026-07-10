# EverythingOnMac：编译、打包与运行 macOS App

本文以当前 `Package.swift` 和 `scripts/build_app.sh` 为准，说明如何生成可双击运行的 `.app` 和 `.zip`。

## 1. 构建模型

项目是 Swift Package，不是 Xcode App Project：

```text
CSearchFS              C Target
EverythingOnMacCore    Swift Library Target
EverythingOnMac        Swift Executable Target
```

因此：

```bash
swift build -c release
```

只生成 Mach-O 可执行文件，不会自动创建 `.app` Bundle。项目使用：

```text
./scripts/build_app.sh
```

手工创建标准 Bundle。

## 2. 环境要求

- macOS 14 或更高；
-支持 Swift tools 6.1 的 Swift/Xcode Command Line Tools；
- `codesign`、`ditto`、`plutil`；
- 可选：本机安装 `ripgrep`。

检查：

```bash
swift --version
xcode-select -p
command -v rg
```

## 3. 一键打包

```bash
cd /Users/vickers/Documents/everythingonmac
chmod +x ./scripts/build_app.sh
./scripts/build_app.sh
```

默认：

```text
CONFIGURATION=release
```

也可构建 Debug：

```bash
CONFIGURATION=debug ./scripts/build_app.sh
```

指定要嵌入的 `rg`：

```bash
RG_PATH=/custom/path/to/rg ./scripts/build_app.sh
```

## 4. 脚本实际执行内容

当前脚本会：

1. 执行 `swift build -c "$CONFIGURATION"`；
2. 通过 `--show-bin-path` 获取 SwiftPM 产物目录；
3. 创建 `dist/EverythingOnMac.app`；
4. 复制主可执行文件到 `Contents/MacOS`；
5. 如果能找到 `rg`，复制到 `Contents/Resources/rg`；
6. 写入 `Info.plist` 和 `PkgInfo`；
7. 执行 ad-hoc 签名；
8. 用 `ditto` 生成 ZIP。

脚本不会：

- 自动生成 App 图标；
- 自动创建 entitlements；
- 自动启用 App Sandbox；
- 自动做 Developer ID 签名或公证；
- 自动构建 universal 主程序；
- 自动验证嵌入的 `rg` 与主程序架构是否匹配。

## 5. 输出

```text
./dist/EverythingOnMac.app
./dist/EverythingOnMac.zip
```

Bundle：

```text
EverythingOnMac.app
└── Contents
    ├── Info.plist
    ├── PkgInfo
    ├── MacOS
    │   └── EverythingOnMac
    ├── Resources
    │   └── rg            # 仅在打包时找到 rg 才存在
    └── _CodeSignature
        └── CodeResources
```

## 6. 当前 Info.plist

脚本写入：

```text
CFBundleIdentifier         com.everythingonmac.app
CFBundleExecutable         EverythingOnMac
CFBundlePackageType        APPL
CFBundleShortVersionString 0.1.0
CFBundleVersion            1
LSMinimumSystemVersion     14.0
CFBundleDevelopmentRegion  zh_CN
```

当前没有写入：

- `CFBundleIconFile`；
- Desktop/Documents/Downloads 等 Usage Description；
-自动更新配置；
- Hardened Runtime 配置。

检查：

```bash
plutil -p ./dist/EverythingOnMac.app/Contents/Info.plist
```

## 7. 架构说明

脚本直接复制本机 SwiftPM 编译结果。因此默认产物架构等于当前构建主机架构。

检查主程序：

```bash
file ./dist/EverythingOnMac.app/Contents/MacOS/EverythingOnMac
```

检查 `rg`：

```bash
file ./dist/EverythingOnMac.app/Contents/Resources/rg
```

此前在 Apple Silicon 主机上实际生成的是：

```text
Mach-O 64-bit executable arm64
```

这不是 universal App。若要支持 Intel 与 Apple Silicon，需要分别构建两种架构并合并，或采用 Xcode archive 流程。

项目另有：

```text
./scripts/package_rg.sh
```

该脚本下载 ripgrep 14.1.0 的 Intel 与 Apple Silicon 预编译包，并用 `lipo` 生成 universal `rg`。它不会自动把生成结果接入 `build_app.sh`；需手动用 `RG_PATH` 指向该文件。

示例：

```bash
./scripts/package_rg.sh
RG_PATH="$PWD/tmp_rg_build/rg" ./scripts/build_app.sh
```

该脚本需要联网，并应在发布前复核下载来源、版本、哈希和许可证。

## 8. 签名

当前：

```bash
codesign --force --deep --sign - "$APP_DIR"
```

这是 ad-hoc 签名，只适合本机开发测试。

验证：

```bash
codesign --verify --deep --strict --verbose=2 \
  ./dist/EverythingOnMac.app

codesign -dv --verbose=4 \
  ./dist/EverythingOnMac.app
```

当前脚本没有 Hardened Runtime，也没有 entitlements。

正式发布需要：

```bash
codesign --force --deep --options runtime \
  --sign "Developer ID Application: NAME (TEAMID)" \
  ./dist/EverythingOnMac.app
```

之后还需公证和 stapling。

## 9. 运行与验证

启动：

```bash
open ./dist/EverythingOnMac.app
```

直接运行并查看 stderr：

```bash
./dist/EverythingOnMac.app/Contents/MacOS/EverythingOnMac
```

检查进程：

```bash
pgrep -fl '/EverythingOnMac.app/Contents/MacOS/EverythingOnMac'
```

退出：

```bash
osascript -e 'tell application id "com.everythingonmac.app" to quit'
```

检查内嵌 ripgrep：

```bash
./dist/EverythingOnMac.app/Contents/Resources/rg --version
```

当前代码运行时的 `rg` 查找顺序为：

1. `RG_PATH`；
2. Bundle resource；
3. `Contents/Resources/rg`；
4. Homebrew 常见路径；
5. `/usr/bin/rg`；
6. `PATH`。

## 10. 权限

当前构建没有 App Sandbox entitlements。App 默认索引用户 Home，并可能访问受 TCC 保护的目录。

若读取受保护目录失败，可在：

```text
系统设置 → 隐私与安全性 → 完全磁盘访问权限
```

添加当前 `.app`，然后完全退出并重启。

由于当前采用 ad-hoc 签名，每次重建 Bundle 后代码签名身份会变化，TCC 授权可能需要重新确认。

详见：

```text
./docs/SANDBOX_AND_PERMISSIONS.md
```

## 11. Gatekeeper

当前 App 没有 Developer ID 签名和公证。自己本机构建通常可运行；跨机器复制后可能被 Gatekeeper 阻止。

确认来源可信时可用 Finder 右键“打开”。检查隔离属性：

```bash
xattr -l ./dist/EverythingOnMac.app
```

只对自己确认安全的构建移除 quarantine：

```bash
xattr -dr com.apple.quarantine ./dist/EverythingOnMac.app
```

## 12. 清理

```bash
rm -rf ./.build ./dist
./scripts/build_app.sh
```

或只清理 SwiftPM：

```bash
swift package clean
```

## 13. 正式发布前清单

1. 增加 App 图标；
2. 版本号由构建配置注入，而不是写死；
3. 决定 direct distribution 或 Mac App Store；
4. 配置正确 entitlements；
5. 使用 Developer ID 或 Distribution 证书；
6. 启用 Hardened Runtime；
7. 公证并 staple；
8. 生成真正的 universal App 或分别发布架构版本；
9. 确认内嵌 `rg` 的架构和许可证；
10. 在干净系统测试 TCC、Full Disk Access、数据库迁移和 FSEvents；
11. 避免依赖 `--deep` 作为正式签名策略，正式流程应逐组件签名；
12. 增加构建产物自动校验和 smoke test。

## 14. 已验证状态

此前已实际验证：

```text
Release 编译                 通过
标准 App Bundle 结构         通过
Info.plist 校验              通过
内嵌 rg                      通过
ad-hoc 签名                  通过
codesign deep/strict 验证    通过
LaunchServices 实际启动      通过
ZIP 产物生成                 通过
```

该验证针对当时本机 arm64 产物，不代表 universal、正式签名或跨机器分发验证。
