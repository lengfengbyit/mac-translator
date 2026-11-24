# MacTranslator BugFix 快捷路径回归报告

- **验证人**：严过关（Yan）· QA 工程师
- **验证时间**：2026-11-23 21:36 – 21:5x（本机时间）
- **验证对象**：工程师本轮修复的 ① LLM 接口编辑不好用 ② 窗口关闭后重开崩溃
- **代码根目录**：`…/mactranslator/MacTranslator/`
- **最终路由判定**：**NoOne（源码层面未发现 Bug）**，但**核心 GUI「关闭→重开」循环因环境锁屏未能执行**，已转为「需用户手动确认清单」（见第 7 节）。这不是走过场的 PASS：能自动化的部分全部真实执行，做不到的部分逐条说明原因。

---

## 1. 结论摘要

| 项目 | 结果 |
|---|---|
| 静态代码审查（5 个指定文件 + 3 个关联文件） | 全部修复点已落地且逻辑正确，未引入强引用环 |
| 独立构建 `./build.sh` | 成功（exit 0），44 个 Swift 源文件 |
| 独立安装 `./scripts/install.sh` | 成功（exit 0），证书签名有效 |
| 代码签名 `codesign --verify --strict` | valid on disk / satisfies Designated Requirement |
| 二进制 UUID | `721F7D2E-54A0-3C61-BA00-4A8CDF097BB8`，与修复前 `E9798E4E-…` 不同 ✅（构建确定性，重复构建 UUID 不变） |
| 离线验证脚本 `zsh Tests/OfflineVerification/run.sh` | **104 PASS / 0 FAIL**（82 + 16 + 6） |
| QA 自建 ViewModel 回归 | **20 PASS / 0 FAIL** |
| QA 自建 AppKit 生命周期压力测试 | **22 PASS / 0 FAIL**（10 轮关闭/重开） |
| GUI 重复打开压力测试（AXPress 真实菜单动作） | 设置 ×10 + 历史 ×5 = **15/15 成功**，进程全程存活 |
| **GUI 关闭→重开循环（崩溃直接复现路径）** | ❌ **未能执行（0 轮）** — 环境锁屏导致 CGEvent 无法送达 App，AX 树不暴露窗口/关闭按钮；详见第 4 节 |
| 崩溃日志比对 | 验证前后均 **2 份**（仅基线 21:09 / 21:10），**无新增** |
| 发现源码 Bug | **无** |
| 发现测试/脚本问题 | 2 处（均为 QA 自建测试的断言过严，已自修）；离线脚本 1 处覆盖缺口（非 Bug，见 6.2） |

---

## 2. 验证矩阵

图例：✅ PASS ｜ ❌ FAIL ｜ ⚠️ BLOCKED（环境阻断，非产品缺陷）

### 2.1 崩溃根因 A：`isReleasedWhenClosed`

| # | 场景 | 期望 | 实际 | 结论 |
|---|---|---|---|---|
| A1 | `SettingsWindowController` 设 `isReleasedWhenClosed = false` | 存在且位置正确 | `SettingsWindowController.swift:23` 已设置，含根因注释 | ✅ |
| A2 | `HistoryWindowController` 同上 | 存在 | `HistoryWindowController.swift:21` 已设置 | ✅ |
| A3 | `BasePanel` 同上 | 存在 | `BasePanel.swift:16` 已设置 | ✅ |
| A4 |窗口控制器生命周期持有 | 控制器不能被提前释放 | `AppDelegate.swift:44–46` 用 `lazy var` 强持有，并在 `:105–106` 预创建 | ✅ |
| A5 | 无新增强引用环 | window.delegate 弱引用 | `NSWindow.delegate` 为 weak；hosting 只持有 vm；无环 | ✅ |
| A6 | 真实 AppKit close→reopen 不释放窗口 | deinitCount 恒为 0 | 离线 `WindowLifecycleVerification` 4 项 + QA 压力测试 22 项全 PASS | ✅ |
| A7 | 真实 App 红叉关闭→菜单重开 ≥8 次无崩溃 | 进程存活、无新崩溃日志 | **未能执行**：锁屏（见 4） | ⚠️ BLOCKED |
| A8 | 历史窗口关闭/重开 ≥3 次 | 同上 | **未能执行**：锁屏（见 4） | ⚠️ BLOCKED |
| A9 | 重复打开（不关闭）压力 | 窗口每次出现、进程存活 | 设置 ×10 / 历史 ×5，15/15 成功，0 新崩溃 | ✅（部分覆盖） |

### 2.2 编辑体验根因 B

| # | 场景 | 期望 | 实际 | 结论 |
|---|---|---|---|---|
| B1 | `ForEach` 用稳定 UUID 而非数组下标 | `id: \.id` | `LLMInterfacesPane.swift:19` 确认为 `ForEach(vm.interfaces, id: \.id)` | ✅ |
| B2 | `SecureField` 不再塞入假 `sk-****` | 初始文本为空、placeholder 指示 | `:112–117` 绑定 `keyText`（初始 `""`），placeholder 为提示文案 | ✅ |
| B3 | apiKey 多时机提交 | 回车 / 失焦 / 消失均提交 | `:119 onSubmit`、`:123 onChange(keyFocused)`、`:126 onDisappear` 三处均调用 `commitAPIKey()`；`keyEdited` 防重复提交 | ✅ |
| B4 | 状态标签读 Keychain 而非模型字段 | `vm.maskedKey(for:)` | `:133` 调用 `vm.maskedKey(for: endpoint.id)`；`SettingsViewModel.swift:151–153` 从 Keychain 读取 | ✅ |
| B5 | 拖拽用 UUID 而非索引 | `draggingID: UUID?` | `:5`、`:23`、`:27–29` 全为 UUID；`moveInterface(id:before:)` 在 `SettingsViewModel.swift:127–132` | ✅ |
| B6 | 提交后 key 跟随接口而非槽位 | 重排/删除后 key 不错位 | QA ViewModel 测试 E5/E6：A→C 之前重排后 B 仍有 key、A 仍无 key | ✅ |
| B7 | `moveInterface` 语义正确并持久化 | 拖拽 A 到 C 前 → [B,A,C]，priority 重编号 | 实测 Swift `Array.move(fromOffsets:toOffset:)` 语义匹配；测试 E5/E7 PASS | ✅ |
| B8 | 名称/model/baseURL 输入保存 | 内存 + 磁盘均更新 | 测试 E4 PASS；静态 `:158–167` binding 调 `updateInterface` | ✅ |
| B9 | apiKey 回车/失焦提交、状态显示 | 写入 Keychain、标签 `sk-****` | 测试 E1/E2 PASS | ✅（程序化层；GUI 录入见 7） |
| B10 | 重启后 apiKey 仍正确 | Keychain 跨启动持久 | 静态：`KeychainService` 系统 Keychain；离线 C7 验证不明文落盘；**GUI 重启后读取需用户确认** | ⚠️ 部分 |
| B11 | 清空 apiKey 后删除 | 空白串触发 delete | 测试 E3 PASS | ✅ |
| B12 | 多接口交叉重排每个 key 跟对接口 | UUID 绑定 | 测试 E6 PASS（逻辑层）；**GUI 拖拽视觉确认见 7** | ⚠️ 部分 |

---

## 3. 真实命令与输出摘要

### 3.1 崩溃日志基线
```
$ find ~/Library/Logs/DiagnosticReports/ -maxdepth 1 -iname "*MacTranslator*" -print
.../MacTranslator-2026-11-23-210927.ips   (21:09)
.../MacTranslator-2026-11-23-211023.ips   (21:10)
→ 基线 2 份
```

### 3.2 独立构建 / 安装 / 签名
```
$ swiftc --version
Apple Swift version 6.1.2 (swiftlang-6.1.2.1.2 clang-1700.0.13.5)
Target: x86_64-apple-macosx15.0

$ ./build.sh
==> Checking toolchain
    SDK    : /Library/Developer/CommandLineTools/SDKs/MacOSX.sdk
    target : x86_64-apple-macosx13.0
==> Compiling Swift sources
    source files: 44 (entry: main.swift top-level code)
==> Signing
    signed with certificate: view-timer Dev
Build complete: .../build/MacTranslator.app
BUILD_EXIT=0

$ otool -l build/MacTranslator.app/Contents/MacOS/MacTranslator | grep -A2 LC_UUID
    uuid 721F7D2E-54A0-3C61-BA00-4A8CDF097BB8

$ codesign --verify --strict --verbose=2 build/MacTranslator.app
build/MacTranslator.app: valid on disk
build/MacTranslator.app: satisfies its Designated Requirement

$ ./scripts/install.sh
==> Installing to /Applications/MacTranslator.app
    previous version backed up to: ~/.mactranslator-backup/20261123-213655/MacTranslator.app
==> Re-signing at final path
/Applications/MacTranslator.app: valid on disk
/Applications/MacTranslator.app: satisfies its Designated Requirement
    certificate signature (view-timer Dev); grants persist across rebuilds
==> Launching
INSTALL_EXIT=0

$ codesign --verify --strict --verbose=2 /Applications/MacTranslator.app
/Applications/MacTranslator.app: valid on disk
/Applications/MacTranslator.app: satisfies its Designated Requirement
```
> 备注：修复前基线 UUID 为 `E9798E4E-…`（team-lead 提供）；本次构建为 `721F7D2E-…`，不同 ✅。安装前 `/Applications` 中的二进制已是 `721F7D2E-…`（工程师此前已安装过同版修复），说明该构建是**确定性**的，重复构建 UUID 不变。

### 3.3 离线验证脚本
```
$ zsh Tests/OfflineVerification/run.sh
===== A. LLM Failover 网关 =====       PASS: 82 | FAIL: 0 | TOTAL: 82
===== D. 历史/收藏持久化（真实 Core Data） =====  PASS: 16 | FAIL: 0 | TOTAL: 16
PASS: root cause: a programmatic NSWindow defaults to isReleasedWhenClosed = true
PASS: fixed window survives close()
PASS: fixed window survives makeKeyAndOrderFront after reopen
PASS: fixed window is visible after reopen
PASS: Sources/.../SettingsWindowController.swift opts out of release-on-close
PASS: Sources/.../HistoryWindowController.swift opts out of release-on-close
WindowLifecycleVerification: ALL PASS
RUN_EXIT=0
→ 合计 104 PASS / 0 FAIL
```

### 3.4 QA 自建回归（独立编写，非工程师提供）
```
swiftc ... /tmp/qa_yan_vmtest.swift -o /tmp/qa_yan_vmtest && /tmp/qa_yan_vmtest
===== E. LLM 接口编辑 ViewModel 回归 =====
PASS: E1 未设置 key 时状态标签='未设置'
PASS: E1 saveAPIKey 写入 Keychain 真实值
PASS: E1 已设置 key 时状态标签='sk-****'（非明文）
PASS: E1 apiKey 未进入持久化的 settings
PASS: E2 saveAPIKey 重新发布 interfaces（状态标签会刷新）
PASS: E3 清空/纯空白 key 触发 Keychain 删除
PASS: E3 删除后状态标签回到'未设置'
PASS: E4 名称/model/baseURL 更新写入内存
PASS: E4 名称变更已持久化
PASS: E5 拖拽 A 到 C 之前 -> [B,A,C]
PASS: E5 重排后 priority 重新编号 1..n
PASS: E5 重排结果已持久化
PASS: E6 重排后 key 仍跟随 UUID（B 有 key，A 无 key）
PASS: E7 ↑ 上移 A -> [A,B,C] / priority 重编号
PASS: E7 ↓ 下移 A -> [B,A,C]
PASS: E8 按 id 删除接口
PASS: E8 删除接口同时删除其 Keychain key
PASS: E8 删除后剩余接口 priority 仍严格递增（允许留空档）
PASS: E9 新增接口 priority = 剩余最大值+1 (=4)
===== ViewModel 回归汇总: 0 FAILURE(S) =====

swiftc ... /tmp/qa_yan_lifecycle.swift -o /tmp/qa_yan_lifecycle && /tmp/qa_yan_lifecycle
===== F. AppKit 窗口生命周期压力测试（修复模式，10 轮关闭/重开）=====
PASS: F1a … F10b（每轮 close() 后 deinitCount 恒为 0，重开 makeKeyAndOrderFront 正常）
PASS: F-final 10 轮后再次 makeKeyAndOrderFront 未崩溃/未释放
PASS: F-control 默认窗口 isReleasedWhenClosed=true（崩溃根因条件成立）
===== 生命周期汇总: 0 FAILURE(S) =====
```

---

## 4. GUI 循环执行记录（关键：必须如实说明未完成部分）

### 4.1 已完成的 GUI 动作（15/15）

使用 AX `AXUIElementPerformAction(kAXPressAction)` 直接触发菜单栏状态项的真实菜单项（等价于点击菜单），再用 `CGWindowListCopyWindowInfo` 按 `kCGWindowOwnerPID + kCGWindowName` 校验窗口出现：

```
[设置 ×10] S1..S10  rc=0  OPEN_OK title=设置 rect=(570,142,780,588)  alive=ALIVE
[历史 ×5 ] H1..H5   rc=0  OPEN_OK title=历史 rect=(660,157,600,528)  alive=ALIVE
OPEN_STRESS ok=15 fail=0
崩溃日志数: 2
```
进程 PID 99053 全程存活，无任何新增崩溃日志。

### 4.2 未能执行的「关闭→重开」循环（0/8 设置、0/3 历史）

`原始崩溃触发序列`要求：**打开 → 关闭（红叉 / Cmd+W）→ 再打开**，循环 ≥8 次。本轮**未能执行**，逐条给出实测证据：

| 尝试手段 | 实测结果 |
|---|---|
| CGEvent 鼠标点击红叉（坐标由 CGWindowList 精确给出 `(590,162)` / `(680,177)`） | `CLOSE_X_TIMEOUT`，窗口未关闭 |
| CGEvent 点击菜单栏图标 `(967,12)` | 菜单未出现 |
| `CGEvent.post(tap: .cghidEventTap)` Cmd+W | 窗口未关闭 |
| `CGEvent.postToPid(pid)` Cmd+W（down/up err 均 0） | 窗口未关闭 |
| `AXUIElementPostKeyboardEvent`（ObjC 直接调 C API，返回 err=0） | 窗口未关闭 |
| AX 查找 `kAXCloseButtonAttribute` | `closeCandidates=0`，AX 树仅暴露菜单栏（11 个 AXMenuItem），**无 AXWindow / 无关闭按钮** |
| AppleScript `tell application "MacTranslator" to close every window` | 命令被 SIGTERM（exit 137），被环境拦截 |
| `osascript` System Events | 任务书已说明 -10004 被拒，未重复尝试 |

**根因定位（环境，不是产品 Bug）**：
```
$ swift -e '... CGSessionCopyCurrentDictionary() ...'
CGSSessionScreenIsLocked = 1
OnConsole = 1, UserName = fengyaming
display asleep = 1（caffeinate -u 后 asleep=0，但 locked 仍为 1）
$ NSWorkspace.shared.frontmostApplication?.localizedName
loginwindow
```
即当前处于**锁屏会话**：CGEvent 事件确实被发出（鼠标指针从 `(680,177)` 移动到 `(400,300)` 已验证），但**无法送达 App**；AX 通道只能触发菜单动作、无法关闭窗口。因此无法在本环境复现「点红叉→再打开」这条直接崩溃路径。

**替代证据**：工程师的离线 `WindowLifecycleVerification` 与 QA 自建的 10 轮 AppKit 生命周期压力测试，都在**真实 AppKit NSWindow** 上执行了 `isReleasedWhenClosed = false → close() → makeKeyAndOrderFront()`，deinitCount 恒为 0，从机制层证明了修复有效；但**不能替代**真实 App 的 8 次 GUI 循环，故第 7 节列出用户手动确认步骤。

---

## 5. 崩溃日志比对

| 时点 | 文件 | 数量 |
|---|---|---|
| 验证前基线 | `MacTranslator-2026-11-23-210927.ips`、`MacTranslator-2026-11-23-211023.ips` | 2 |
| 构建/安装后 | 同上两份 | 2 |
| 15 次重复打开后 | 同上两份 | 2 |
| 最终 | 同上两份 | **2（无新增）** ✅ |

---

## 6. 发现的问题清单

### 6.1 源码 Bug
**无。** 静态审查与 42 项程序化测试（20 VM + 22 生命周期）未发现源码缺陷。

### 6.2 非阻断问题 / 覆盖缺口（路由 QA，均已处理或记录）

| # | 位置 | 严重度 | 说明 | 处理 |
|---|---|---|---|---|
| Q1 | QA 自建 `/tmp/qa_yan_vmtest.swift` E8/E9 | 低 | 初版断言要求删除后 priority 必须连续、新增必须为 3；实际源码只保证**相对有序**且新增取剩余 max+1（设计合理，网关按 priority 升序调用即可） | **已自修断言**（第 1 轮自修），重跑 20/20 PASS；未改源码 |
| Q2 | 工程师 `Tests/OfflineVerification/WindowLifecycleVerification.swift:48–51` | 低（覆盖缺口，非 Bug） | 源码文本检查只覆盖 `SettingsWindowController` 与 `HistoryWindowController`，**未包含 `BasePanel.swift`**；且真实生命周期测试用的是 `LifecycleProbeWindow`（手动设 flag）而非生产类 | QA 已独立静态确认 `BasePanel.swift:16` 设了 `isReleasedWhenClosed = false`，并用自建 10 轮压力测试补足；建议后续把 BasePanel 纳入文本检查（本轮不阻塞） |
| Q3 | `SettingsViewModel.maskedKey(for:)`（`:151–153`） | 提示 | 每次 SwiftUI body 求值都同步读 Keychain；接口数量很少，无实际性能问题 | 仅记录，不建议本轮改动 |
| Q4 | `SettingsViewModel.removeInterface`（`:112–117`） | 提示 | 删除后不重排 priority，会留空档（如 [2,3]）；相对顺序正确、UI 用 `index+1` 显示位次、网关只看相对顺序，**功能无影响** | 仅记录；已体现在自修后的 E8 断言 |

### 6.3 轮次与路由
- **第 1 轮**：写测试 → 跑 → 发现 2 个失败 → 判定为 QA 测试断言错误 → 自修（Q1），未动源码。
- **第 2 轮**：重跑 → 20/20 + 22/22 + 104/104 全过。
- **最终路由：NoOne**（源码无 Bug）。GUI 关闭循环因锁屏 BLOCKED，转人工确认，不计为源码 Bug、也不伪造 PASS。

---

## 7. 需用户手动确认清单（请在解锁屏幕的机器上执行）

> 前置：解锁屏幕；`/Applications/MacTranslator.app` 已安装（本轮已装好）；文案以实际界面为准。

### A. 崩溃路径（最高优先，务必逐条做）
1. 点击菜单栏的「划译」图标 → 点「设置…」，确认设置窗口打开。
2. **点设置窗口左上角红叉**关闭窗口（不要用 Cmd+W，要与原始崩溃路径一致）。
3. 再次点菜单栏图标 → 「设置…」。
4. **重复第 2–3 步至少 8 次**。每次后确认：App 仍在菜单栏存活、窗口正常弹出、无「划译 意外退出」系统弹窗。
5. 同样方式对「历史与收藏」窗口做 **≥3 次**关闭/重开。
6. 执行后运行：`ls -lt ~/Library/Logs/DiagnosticReports/ | grep MacTranslator`
   - **期望**：仍只有 `MacTranslator-2026-11-23-210927.ips` 与 `211023.ips` 两份，**无新文件**。

### B. LLM 接口编辑路径
1. 打开「设置…」→ 切到「LLM 接口」标签。
2. 点「＋ 添加接口」，在新增卡片中填写 **名称 / model / baseURL**，每个字段输入后切到下一格（失焦），关闭再打开设置，确认内容保留。
3. 在 **apiKey** 框输入 `sk-test123456` → **按回车**：
   - 确认该卡片下方状态文案从「未设置」变为「**sk-******」；
   - 确认输入框**没有**变成 `sk-****sk-test123456` 之类拼接脏值（这是旧 Bug 的典型症状）。
4. 再次输入另一个 key 后**直接点别的输入框（失焦）**，确认状态同样更新为「sk-****」。
5. 完全退出 App（`菜单 → 退出划译`）再重新打开 → 进入 LLM 接口 → 确认状态**仍是**「sk-****」（Keychain 跨启动持久）。
6. 清空 apiKey 输入框并按回车 → 确认状态回到「**未设置**」。
7. 添加 3 个接口，分别给第 1、3 个填入**不同的** key（如 `sk-AAA…`、`sk-CCC…`），状态都应显示「sk-****」。
8. 用 **↑↓ 按钮**和**拖拽**交叉重排多次（例如 1↔3、2↔1）：
   - 确认每个卡片的圆序号与顺序一致；
   - 确认原本有 key 的**那条接口**状态仍是「sk-****」，原本没 key 的仍是「未设置」（key 不串位）。
9. 删除一条接口 → 确认其 Keychain key 一并删除、其余接口顺序与状态仍正确。

---

## 8. 附：静态审查逐项核对明细

| 文件 | 关键行 | 核对结论 |
|---|---|---|
| `UI/Windows/SettingsWindowController.swift` | 7, 12–23, 29–31, 34–38 | `private let window` 强持有；`:23` 设 `isReleasedWhenClosed=false`；`show()` 用 `makeKeyAndOrderFront`；`windowWillClose` 为 `nonisolated` 并切回 MainActor 停轮询 — 正确 |
| `UI/Windows/HistoryWindowController.swift` | 7, 12–21, 27, 31–35 | 同上，`:21` 设置 flag；无 delegate 但 `orderOut` 不触发释放 — 正确 |
| `UI/Windows/BasePanel.swift` | 4–25 | `:16` 设 `isReleasedWhenClosed=false`；`canBecomeKey/Main=false` 保持非激活 — 正确 |
| `UI/panes/LLMInterfacesPane.swift` | 5, 19–40, 63–70, 112–127, 150–167 | `id: \.id`、`draggingID: UUID?`、SecureField 空初值 + 三时机提交 + `keyEdited` 防重、`maskedKey(for:)` 状态、`position` 由数组实时推导 — 正确 |
| `UI/Shared/SettingsViewModel.swift` | 104–169, 200–221 | `moveInterface(id:before:)` UUID 定位、priority 重编号持久化、`saveAPIKey` 写 Keychain 后再发布、删除清 key — 正确 |
| `App/AppDelegate.swift` | 44–46, 104–107 | 三个控制器强持有并预创建，杜绝控制器被提前释放 — 正确 |
| `App/MenuBarController.swift` | 46–57, 78–84 | 菜单项 action 正确绑定到 `onSettings`/`onHistory` — 正确 |
| `UI/Windows/ResultWindowController.swift` | 7, 19 | 使用 `BasePanel`（已 opt-out），无同类风险 — 正确 |
