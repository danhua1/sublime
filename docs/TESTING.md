# T001 构建与测试说明

## 已验证环境与正式结果

正式复验环境为 macOS 12.5.1 / arm64、Xcode 14.2（14C18）、Apple Swift 5.7.2。当前已验证状态来自实现阶段 attempt 3：规定的五条命令均退出 0，`swift test` 执行 20 项 XCTest、0 failures；正式 `build/Subline.app` 通过 bundle 校验并实际启动，AppKit 冒烟完成 87 条断言。实现报告中的日志位于 `build/verification/attempt3/`。这是实现阶段记录，不是文档阶段后的工作流复验、独立审核结论或任务 PASS。

本机 `xcode-select -p` 仍指向 Command Line Tools。初轮直接使用已选 CLT 时，SwiftPM 测试报告 `XCTest not available`，release/build-app 报缺少 `PackageDescription`，未能完成正式 build 或生成 bundle。随后有一轮使用 `swiftc` 的源码/AppKit 诊断构建和临时诊断 app 冒烟；那只验证部分真实 UI 行为，不是 SwiftPM/XCTest、release build 或正式 bundle 验收。之后发现本机已有 `/Users/dusiyuan/Downloads/Xcode.app`，通过逐命令设置 `DEVELOPER_DIR` 才完成上述正式复验。不要把早期失败或诊断结果混写成正式复验结果；历史记录仍保留在实现报告中。

为单条命令选择该 Xcode（路径按本机安装位置调整），无需改变全局 `xcode-select`：

```sh
DEVELOPER_DIR="/Users/dusiyuan/Downloads/Xcode.app/Contents/Developer" /usr/bin/xcrun swift test --scratch-path .build
DEVELOPER_DIR="/Users/dusiyuan/Downloads/Xcode.app/Contents/Developer" /usr/bin/xcrun swift build -c release --scratch-path .build
DEVELOPER_DIR="/Users/dusiyuan/Downloads/Xcode.app/Contents/Developer" sh scripts/build-app.sh
DEVELOPER_DIR="/Users/dusiyuan/Downloads/Xcode.app/Contents/Developer" sh scripts/verify-bundle.sh
DEVELOPER_DIR="/Users/dusiyuan/Downloads/Xcode.app/Contents/Developer" sh scripts/smoke-app.sh
```

`DEVELOPER_DIR=... command` 只对该命令进程及其子进程生效；构建脚本调用 `/usr/bin/xcrun swift`，继承该选择。`swift test` 与 release build 使用 `.build` scratch path。构建脚本将 release 可执行文件和 `Resources/Info.plist` 组装为 `build/Subline.app`；bundle 脚本检查 plist、arm64 Mach-O、AppKit 依赖和 macOS 12.0 部署目标。冒烟脚本先检查 bundle，再启动它。示例不重设 `HOME`、`home` 或 `CODEX_HOME`，也不运行全局 `xcode-select` 修改。需要可用的 Apple SDK 与图形登录会话；冒烟使用 macOS `sandbox-exec`，若系统不支持或沙箱无法建立，脚本应失败而非降级为无隔离测试。

## XCTest 隔离和覆盖

`swift test` 当前执行 20 项 XCTest：原有 12 项 `TextFileTests` 与 8 项 `AtomicSaveTests`。测试文件在各测试创建的 UUID 临时目录内操作，并清理由测试创建的目录；不把用户选择的文件作为测试输入。新增原子保存测试涵盖 ACL/继承 ACL 与属性读取/应用错误拒绝、owner/group/mode 核对，以及 Save/Save As 下 15 类 rename 前故障注入各一次（共 30 个故障场景），包括真实先短写后失败、同步和 rename 错误；断言旧文件和文档状态保持、临时文件清理。也测试 EINTR/短写恢复。

这些是测试数据的隔离，不表示整个 SwiftPM、编译器或开发工具链进程处于文件系统沙箱中；编译器可能访问工具链和用户缓存。

## GUI 冒烟隔离与覆盖

`scripts/smoke-app.sh` 的真实行为如下：

- 先运行 `scripts/verify-bundle.sh`，再用 `mktemp -d "${TMPDIR:-/tmp}/Subline-smoke-XXXXXXXX"` 建立新的测试根及专用 `recovery`、`preferences`、`tmp` 目录与测试文件。
- 使用 `scripts/smoke-sandbox.sb` 限制被测 App 写入新测试根以外的位置，禁止写用户偏好，并禁止读取真实 Subline 偏好、恢复及 Saved Application State 路径。应用的 `--smoke-test` 入口也校验测试根和子目录。沙箱不能建立时不会继续无隔离测试。
- 不重设 `HOME`。脚本只记录上述用户状态路径的文件元数据以便前后比较，不读取内容；完成后只清理由本次创建的 smoke 根目录。测试日志放在忽略目录 `build/verification/smoke-app.log`。
- 启动真实 AppKit 窗口和控件，90 秒超时；要求成功标记及断言完成，不以进程存活代替通过。attempt 3 记录 87 条 AppKit/文件断言。

本隔离只约束冒烟 App 进程，不是通用安全隔离机制，也不限制整个 SwiftPM/Xcode 命令只访问仓库和临时目录。此前 attempt 2 有偏好文件来源不可追溯的记录；attempt 3 的前后元数据比较不能反向证明早期历史来源，也不应据此推断其曾被读取或未被读取。

GUI 自动化使用真实窗口、文本控件与控制器，但成功路径选择及部分 Save/Discard 决策由测试注入交互驱动；原生面板/提示框主要验证取消路径。以下真人操作尚未验证：macOS 快捷键和中文输入法组合输入、人工在原生面板成功选取路径及处理覆盖确认、Finder 双击、视觉布局、长文本滚动/响应，以及用户实际退出并重新启动。不得将这些写成已通过。

## 文件与恢复边界

- 仅支持本地普通文件和严格 UTF-8，可带并保留已打开文件的 UTF-8 BOM；拒绝 UTF-16、无效 UTF-8、目录/非普通文件及二进制控制内容。输入读取前检查大小，打开和保存结果上限均为 20 MiB。上限不是性能保证。
- 编辑缓冲区使用 LF。保存时沿用检测到的 LF、CRLF 或 CR；混合行尾统一为最先出现的换行样式。新建文件使用 LF 且无 BOM。
- 保存会检查文件自打开后是否变化或删除；检测到冲突会取消覆盖并保留本地未保存内容，可另存到新路径。任意非协作进程在最终检查与替换之间的瞬时竞争不能完全消除。
- 对目标文件检测到任何扩展 ACL（包括 deny、grant、空或继承 ACL），或 ACL/访问属性读取失败时，保存会在替换前拒绝，不会把这些情况当成“没有 ACL”。目标含特殊 mode bits 或非零保护 flags 也拒绝。新建临时文件若继承 ACL，会在写入正文前拒绝。错误提示用户另存为新文件；普通无 ACL 文件的 owner/group/mode 会应用并读回核对。rename 前的失败保留原文件和文档未保存状态。保存到普通新路径可用于保留本地内容，但不表示可绕过有 ACL 文件的安全策略进行原位覆盖。
- R2 故障注入覆盖 rename 前的属性检查、写入、fsync 和 rename 错误；不等于真实磁盘满或断电测试。rename 成功后读回失败时，磁盘可能已是新内容，因此不能保证任何报错都意味着磁盘未变化。非协作写入竞争、断电持久性及清理 unlink 自身失败也不在已验证保证内。xattr/resource fork/硬链接身份语义未完整验证；其他文件系统、不同账号、非默认 owner/group 及非零 flags 的全部组合没有验证。
- 文件读写同步执行；没有接近 20 MiB 文件的 UI 延迟基准。T001 不实现草稿恢复、应用偏好持久化或窗口状态恢复；退出后未保存草稿不会自动恢复。冒烟专用的隔离恢复目录只是测试夹具，不是产品恢复功能。

实现报告 `.workflow/results/T001-implementation.md` 记录上述复验、证据与未解决边界。文档完成后仍应由调度员按工作流执行正式验证并由独立审核员审核；本说明本身不更新工作流状态。
