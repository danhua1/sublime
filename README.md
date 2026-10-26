# Subline

Subline 是一个面向个人使用的原生 macOS 纯文本编辑器。当前已实现多标签编辑、本地 UTF-8 文件打开与保存、撤销/重做，以及关闭时的未保存修改保护。应用使用 AppKit / NSTextView，不需要后端或第三方运行时依赖。

## 环境要求

- macOS 12 或更新版本；当前构建产物为 Apple silicon（arm64）。
- 本仓库已验证环境：macOS 12.5.1、Xcode 14.2、Apple Swift 5.7.2。
- SwiftPM 需要可用的 Apple 工具链、macOS SDK、`PackageDescription` 和 XCTest。若系统选中的 Command Line Tools 缺少这些模块，请像下面示例一样为单条命令指定 Xcode；不必更改全局 `xcode-select`。

## 构建和启动

以下示例使用本机已有的 Xcode 14.2。`DEVELOPER_DIR` 只作用于它前面的那条命令；将其值改为你自己的 `Xcode.app/Contents/Developer` 路径即可。构建产物为忽略目录中的 `build/Subline.app`：

```sh
DEVELOPER_DIR="/Users/dusiyuan/Downloads/Xcode.app/Contents/Developer" /usr/bin/xcrun swift build -c release --scratch-path .build
DEVELOPER_DIR="/Users/dusiyuan/Downloads/Xcode.app/Contents/Developer" sh scripts/build-app.sh
DEVELOPER_DIR="/Users/dusiyuan/Downloads/Xcode.app/Contents/Developer" sh scripts/verify-bundle.sh
```

启动构建好的应用：

```sh
build/Subline.app/Contents/MacOS/Subline
```

`build-app.sh` 通过 `xcrun swift` 使用当前进程选择的开发目录构建 release，然后生成 app bundle；`verify-bundle.sh` 独立检查其 plist、可执行文件、arm64 架构、AppKit 依赖和最低系统版本。构建和验证不会执行全局 `xcode-select` 修改。

## 当前编辑行为

下面列出当前版本已有的操作；尚未实现的编辑辅助功能不作为现有能力介绍。

- 新建多个未命名标签；通过打开菜单/面板选择本地文件；重复打开同一路径时切回已有标签。
- 保存、另存为、撤销/重做，以及关闭标签或退出时的保存、放弃、取消选择。
- 菜单快捷键：⌘N 新建、⌘O 打开、⌘S 保存、⇧⌘S 另存为、⌘W 关闭标签、⌘Z 撤销、⇧⌘Z 重做、⌘Q 退出。
- 编辑内容按纯文本处理。每个标签拥有独立文本与撤销状态；保存失败或取消不会清除未保存标记。

### 文件支持与保护

- 只接受本地普通文件，文本须为严格 UTF-8；允许并保留 UTF-8 BOM。无效 UTF-8、UTF-16、含二进制控制字符的文件和目录会被拒绝。
- 输入和保存结果上限均为 **20 MiB（20 × 1024 × 1024 字节）**。打开前检查文件大小，读取时也有界；上限用于防止超量输入，不代表性能承诺。
- 编辑缓冲区统一使用 LF。打开文件时识别 LF、CRLF 或 CR，保存时沿用检测到的样式；混合行尾会统一为文件中最先出现的换行样式，无换行文件及新建文档使用 LF。已打开文件的 UTF-8 BOM 会保留。
- 保存前会检查磁盘文件是否相对打开时发生变化。检测到外部修改或删除时取消覆盖并保留本地未保存内容；可另存到新路径。该保护不能消除其他非协作程序恰好在最终检查与替换之间写入的所有竞争风险。检测到目标有扩展 ACL（deny、grant、空或继承 ACL），或读取 ACL/访问属性失败时，会在替换前拒绝保存；特殊 mode bits、非零保护 flags 及带继承 ACL 的新临时文件也会拒绝。普通无 ACL 文件的 owner/group/mode 会应用并核对。不能安全原位保存时，请另存为新文件；错误路径不会清除本地未保存状态。
- 文件读写是同步操作；20 MiB 限制不保证大文本操作没有延迟。

### 本地数据与恢复

T001 不实现草稿恢复或应用偏好持久化，也不启用 macOS 窗口状态恢复。未保存内容只在当前进程和标签中；退出后不会自动恢复。关闭/退出前的未保存提示是当前的数据保护方式。当前实现不包含网络请求、遥测或内容上传。

## 验证

```sh
DEVELOPER_DIR="/Users/dusiyuan/Downloads/Xcode.app/Contents/Developer" /usr/bin/xcrun swift test --scratch-path .build
DEVELOPER_DIR="/Users/dusiyuan/Downloads/Xcode.app/Contents/Developer" /usr/bin/xcrun swift build -c release --scratch-path .build
DEVELOPER_DIR="/Users/dusiyuan/Downloads/Xcode.app/Contents/Developer" sh scripts/build-app.sh
DEVELOPER_DIR="/Users/dusiyuan/Downloads/Xcode.app/Contents/Developer" sh scripts/verify-bundle.sh
DEVELOPER_DIR="/Users/dusiyuan/Downloads/Xcode.app/Contents/Developer" sh scripts/smoke-app.sh
```

实现阶段 attempt 3 的正式复验记录为 20 项 XCTest（0 failures）和 87 条 AppKit/文件冒烟断言；首轮 CLT 工具链失败、后续源码诊断与 Xcode 正式复验是不同阶段，当前验证环境与结果、测试隔离、文件/ACL/恢复限制及尚未完成的人工作业见 [`docs/TESTING.md`](docs/TESTING.md)。冒烟启动真实 AppKit 窗口，需图形会话和可用的 `sandbox-exec`；它使用新建临时根和系统沙箱，不重设 `HOME`。这些实现阶段结果尚待文档后工作流复验和独立审核。
