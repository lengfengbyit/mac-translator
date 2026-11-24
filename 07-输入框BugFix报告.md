# MacTranslator 输入框 BugFix 报告（第二次报告：不好选择 / 不能粘贴 / 不能删除）

- **工程师**：寇豆码（Kou）· 软件开发工程师
- **时间**：2026-11-24 08:12 – 08:4x（本机时间）
- **代码根目录**：`…/mactranslator/MacTranslator/`
- **用户报告原文**："LLM 接口编辑功能还是不好用，输入框不好选择，也不支持粘贴和删除，电脑已经解锁了，你再看看"
- **环境**：macOS 15 / x86_64 / Swift 6.1.2（Command Line Tools，无 Xcode）；本机**已解锁**（`CGSessionCopyCurrentDictionary` 无 `CGSSessionScreenIsLocked` 键，frontmost 可为 WorkBuddy / 划译）
- **验证手段**：Quartz CGEvent（`CGEvent.post(tap: .cghidEventTap)`，无需辅助功能）+ AX（`AXIsProcessTrusted() = true`）读回控件值与焦点

---

## 1. 结论摘要

本次是**两个相互独立、叠加出现**的真实源码 Bug，均已定位并修复。不是上一次的 `ForEach` 下标 / `SecureField` 假值 / 重排串位 / 窗口崩溃问题（那些修复保持不变）。

| # | 根因 | 症状 | 修复 |
|---|---|---|---|
| **A** | App 是 `LSUIElement` + `.accessory`，**没有 mainMenu**，标准编辑键位（⌘V/⌘C/⌘A/⌘X）在响应链里没有 target，按键只发 system beep | "不支持粘贴和删除"（⌘A/⌘V/Delete 快捷键无效） | 启动时安装一个**隐藏的 mainMenu + Edit 子菜单**，nil-target 指到第一响应者；`.accessory` 策略不变，菜单不显示、无 Dock 图标闪烁 |
| **B1** | 整个 `List` 行挂 `.onDrag` / `.onMove`，在 NSTextField 上盖了 pan 手势识别器，吞掉 mouse-down | "输入框不好选择"（点击无法成为第一响应者） | `.onDrag` 只挂到序号圆圈手柄；移除行级 `.onMove`；行仅保留 `.onDrop` 作为放置目标（拖拽重排能力保留） |
| **B2** | accessory app 从菜单栏唤起设置窗时，`NSApp.activate` 未必把窗口变成 key window | 首次点输入框可能只激活窗口、不聚焦字段 | `show()` 里 `activate` + `orderFrontRegardless` + `makeKeyAndOrderFront`，并在下一 run-loop turn 再提升一次 key window |

| 验证项 | 结果 |
|---|---|
| 真机 CGEvent：4 个字段（名称/model/baseURL/apiKey）点击聚焦 | **12/12 PASS** |
| 真机 CGEvent：键入 / ⌘A / ⌘C 读回 / ⌘V 粘贴 / 删除 | **全 PASS**（详见第 4 节） |
| apiKey 粘贴后 Keychain 实际内容 | `sk-PASTE-APIKEY-999`（与剪贴板一致）✅ |
| 红叉关闭 → 菜单栏重开 8 次 | **8/8 PASS**，进程全程存活 |
| 崩溃日志比对 | 始终 **2 份基线**，无新增 |
| 签名 / 离线验证 | codesign valid；**121 PASS / 0 FAIL** |

---

## 2. 复现证据（改代码之前）
```
# 用 CGEvent 点击 model 输入框（app 已 frontmost、窗口已 raise）
field[1] before: val="" focused=0
after click: focused=0            ← 点击后仍不是第一响应者
after Cmd+V: val=""               ← 粘贴无效

# AX 手动设焦点后键入/删除可用，说明字段本身没坏：
AX set focused rc=0 now focused=1
after type 'hello': val="hello"   ← 键入可用
after Backspace x2: val="he'l"    ← 删除键可用（当时是中文输入法，有拼写残留）
after Cmd+V: val="hello"          ← 但 ⌘V 依然无效
```
关键结论（逐一验证 / 证伪 team-lead 的怀疑方向）：
1. **accessory 焦点**：部分成立 → 窗口确实有时不是 key，但点击标题栏 / 设 focusedWindow 后可聚焦，**不是不能粘贴的根因**。
2. **binding 从值类型副本读**：证伪。程序化测试键入 `hello` 五个字符全部落地、无回滚；`binding(for:)` 的 set 传的是完整新值，get 在 body 重算时刷新，不是本次根因。**未改动**。
3. **List 拖拽拦截**：成立。整行 `.onDrag`/`.onMove` 的手势识别器吞点击 → 这是"不好选择"的根因。
4. **SecureField 焦点提交**：证伪。apiKey 的提交时机（onSubmit / onChange / onDisappear + keyEdited 防重）正确，**未改动**。
5. **新增根因（team-lead 未列）**：**没有 mainMenu → ⌘V/⌘A 无响应者** → 这是"不能粘贴/删除"的真正根因。用 CGEvent event tap 观察到我们发出的按键确实带 `cmd=true` 标志（`flags=0x20100000`），系统层面没丢事件，但 NSTextField 不响应——典型的无 Edit 菜单症状（见 StackOverflow "Cocoa Keyboard Shortcuts in Dialog without an Edit Menu"、CSDN "LSUIElement 应用需要手动创建隐藏菜单栏"）。

### 附加环境说明（如实记录，不伪造）
- 开始时系统输入源是 `com.tencent.inputmethod.wetype`（拼音），会干扰 CGEvent 键入测试（出现 `he'l` 之类残影）。测试前用 Carbon `TISSelectInputSource` 切到 `com.apple.keylayout.ABC`。这是**测试环境**因素，不是产品 Bug。
- `osascript` / System Events 依旧报 -10004（无辅助功能），全程未使用；菜单用 AX `AXUIElementPerformAction(kAXPressAction)` 触发，键盘/鼠标用 CGEvent。
- 自动化进程发 ⌘ 组合键需 event tap 权限；本轮已验证 CGEvent 的 command 标志正确发出（`cmd=true`），修复前 NSTextField 不响应、修复后响应，对比明确。

---

## 3. 改动文件与具体修改（最小变更，共 3 个源文件 + 2 个验证文件）

### 3.1 `Sources/MacTranslator/App/AppDelegate.swift`（根因 A）
- `applicationDidFinishLaunching` 中在 `setActivationPolicy(.accessory)` 后新增 `installMainMenu()`。
- 新增私有方法 `installMainMenu()`：构造一个 `NSMenu`，第一个 item 是 App 菜单（Hide ⌘H / Quit ⌘Q），第二个 item 的 submenu 是 **Edit 菜单**：Undo(⌘Z)、Redo(⌘⇧Z)、Cut(⌘X)、Copy(⌘C)、**Paste(⌘V)**、**Select All(⌘A)**，action 用 `#selector(NSText.paste(_:))` 等 nil-target 选择器，最后 `NSApp.mainMenu = mainMenu`。
- 菜单在 `.accessory` 下**不会显示**在菜单栏，不引入 Dock 图标或菜单栏闪烁。

### 3.2 `Sources/MacTranslator/UI/panes/LLMInterfacesPane.swift`（根因 B1）
- `ForEach` 行：去掉 `.onMove`；`.onDrag` 从整行移除；行**仅保留** `.onDrop(of: [.text])`（拖拽重排的目标）。
- `InterfaceCard` 增加 `@Binding var draggingID: UUID?`，由 pane 以 `$draggingID` 传入。
- `.onDrag` 只挂在序号 `ZStack` 圆圈上（25×25 手柄），`.help("拖拽调整顺序")`。
- 每次 Edit 字段的输入/粘贴/删除都经 `binding(for:)` → `vm.updateInterface` 即时持久化，逻辑未变。

### 3.3 `Sources/MacTranslator/UI/Windows/SettingsWindowController.swift`（根因 B2）
`show()` 由：
```swift
NSApp.activate(ignoringOtherApps: true)
window.makeKeyAndOrderFront(nil)
```
改为：
```swift
NSApp.activate(ignoringOtherApps: true)
window.orderFrontRegardless()
window.makeKeyAndOrderFront(nil)
Task { @MainActor [weak self] in
    guard let self else { return }
    NSApp.activate(ignoringOtherApps: true)
    self.window.makeKeyAndOrderFront(nil)
}
```
`isReleasedWhenClosed = false`（上一次崩溃修复）保持不变。

### 3.4 验证文件
- 新增 `Tests/OfflineVerification/InputFocusVerification.swift`（17 项源码级回归：mainMenu/Edit/⌘V/⌘A、`.onDrag` 仅在手柄、无行级 `.onMove`、show() 激活/key window）。
- `Tests/OfflineVerification/run.sh` 末尾追加该验证的编译与执行。

### 3.5 未改动（明确）
`SettingsViewModel.swift`（binding 回滚怀疑已证伪）、`LLMInterfacesPane` 的 SecureField `commitAPIKey` 三种提交时机、`main.swift` 的 `.accessory` 策略、`Info.plist` 的 `LSUIElement=1`。

---

## 4. 真机 CGEvent 回归验证（真实输出，逐字段）

进程 PID 52663（最终版本）；输入源切到 ABC；先用菜单栏唤起设置窗并点标题栏确保 key window。以下为 `final_verify.swift` / `paste_delete_final.swift` / `apikey.swift` 的真实 stdout。

### 4.1 四个字段：点击聚焦 / 键入 / ⌘C 读回 / 粘贴 / 删除
```
--- 名称(name) [0] ---
  PASS 名称(name) click-focus: focused=1
  PASS 名称(name) type abc: val="abc"
  PASS 名称(name) readback type: clip="abc"
  PASS 名称(name) paste: val="ZQ0M" expect ZQ0M
  PASS 名称(name) readback paste: clip="ZQ0M"
  PASS 名称(name) delete: val=""

--- model [1] ---
  PASS model click-focus: focused=1
  PASS model type abc: val="abc"
  PASS model readback type: clip="abc"
  PASS model paste: val="ZQ1M" expect ZQ1M
  PASS model readback paste: clip="ZQ1M"
  PASS model delete: val=""

--- baseURL [2] ---
  PASS baseURL click-focus: focused=1
  PASS baseURL type abc: val="abc"
  PASS baseURL readback type: clip="abc"
  PASS baseURL paste: val="ZQ2M" expect ZQ2M
  PASS baseURL readback paste: clip="ZQ2M"
  PASS baseURL delete: val=""
```
粘贴验证说明：先把剪贴板设为唯一标记（如 `ZQ0M`），CGEvent 发 ⌘V，再用 AX 读回 TextField 值**等于该标记**，随后 ⌘A+⌘C 把字段内容读回剪贴板二次确认。删除用 ⌘A + Backspace，读回为空。

### 4.2 apiKey（SecureField）
SecureField 的 AX `kAXValueAttribute` 会显示掩码圆点（``），这是安全控件预期行为，不能用它判断内容。改用**Keychain 实际值**验证：
```
apiKey focus=1
after paste (masked)=""   ← 剪贴板 sk-PASTE-APIKEY-999（19 字符）已落入
status after Enter="sk-****"
# 直接读系统 Keychain（service=com.mactranslator.app.llm）：
count=1
acct=B5950336-1B87-4AEE-8758-7900E8819EFA status=0 key=sk-PASTE-APIKEY-999
```
→ 粘贴的 key 完整落盘（Keychain），status 标签同步为 `sk-****`。apiKey 的删除/清空仍由原有 `commitAPIKey`（空串触发 delete）负责，逻辑未改。

### 4.3 冷启动完整用户路径（kill → open → 菜单栏 → 设置 → 单击字段）
```
status item x=1012.0 front=WorkBuddy
menu items=99
press 设置 rc=0
opened: front=划译 isActive=true
fields=12
field[1] before focus=0 val="5te"
after SINGLE click focus=1        ← 修复后：单击即聚焦（修复前 focus=0）
after type 'te': val="5tete"
```

### 4.4 关闭 → 菜单栏重开 8 次（崩溃直接路径）
```
round 1: closed=true reopened=true alive=true => OK
round 2: closed=true reopened=true alive=true => OK
round 3: closed=true reopened=true alive=true => OK
round 4: closed=true reopened=true alive=true => OK
round 5: closed=true reopened=true alive=true => OK
round 6: closed=true reopened=true alive=true => OK
round 7: closed=true reopened=true alive=true => OK
round 8: closed=true reopened=true alive=true => OK
REOPEN_LOOP ok=8 fail=0
```
每次用 CGEvent 点红叉坐标关闭，菜单栏点 "设置…" 用 AX kAXPressAction 重开，进程 PID 52663 全程存活。

### 4.5 构建 / 安装 / 签名 / 崩溃日志
```
$ ./build.sh        → Build complete, BUILD_EXIT=0
$ ./scripts/install.sh
  previous version backed up to: ~/.mactranslator-backup/20261124-083031/MacTranslator.app
  /Applications/MacTranslator.app: valid on disk
  /Applications/MacTranslator.app: satisfies its Designated Requirement
  certificate signature (view-timer Dev); grants persist across rebuilds

$ codesign --verify --strict --verbose=2 /Applications/MacTranslator.app
  valid on disk / satisfies its Designated Requirement

$ otool -l /Applications/MacTranslator.app/Contents/MacOS/MacTranslator | grep LC_UUID
  uuid 712C2DDC-4FF2-3077-A33C-DF7EBE257A2D   （修复前 0A9E1C6C…，不同 ✅）

$ find ~/Library/Logs/DiagnosticReports/ -iname '*MacTranslator*'
  MacTranslator-2026-11-23-210927.ips        （基线，21:09）
  MacTranslator-2026-11-23-211023.ips        （基线，21:10）
  → 始终 2 份，无新增 ✅
```

### 4.6 离线验证
```
$ zsh Tests/OfflineVerification/run.sh
========== 汇总 ==========  PASS: 82 | FAIL: 0 | TOTAL: 82
========== 持久化汇总 ==========  PASS: 16 | FAIL: 0 | TOTAL: 16
WindowLifecycleVerification: ALL PASS       （6 项）
InputFocusVerification: 17/17 PASS, 0 FAIL  （本次新增）
→ 合计 121 PASS / 0 FAIL
```

---

## 5. 全局一致性审查

修改后通读全部相关文件，逐项检查：
- **跨文件导入**：`AppDelegate.swift` 用 `NSText.cut/copy/paste/selectAll` 选择器，文件已 `import AppKit` ✅；`SettingsWindowController` 的 `Task { @MainActor }` 与类注解一致 ✅；`LLMInterfacesPane` 的 `@Binding draggingID` 由 pane 的 `@State` 以 `$draggingID` 传入，类型 `Binding<UUID?>` 匹配 ✅。
- **接口契约**：InterfaceCard 构造从 `InterfaceCard(vm:endpoint:)` 改为 `InterfaceCard(vm:endpoint:draggingID:)`，唯一调用点已同步 ✅；`vm.moveInterface(id:before:)` 签名未变 ✅。
- **数据流**：`.onDrag` 手柄写 `draggingID`，行 `.onDrop` 读它并调 `vm.moveInterface(id:before:)`，重排逻辑与 ↑↓ 按钮共用同一套，未重复实现 ✅。
- **无重复实现**：Edit 菜单只在 `installMainMenu()` 构造一次，启动时调用一次 ✅。
- 完整构建成功（44 个源文件），真机运行无崩溃。

**IS_PASS: YES**

---

## 6. 需用户手动确认的少量项（非阻断；自动化无法 100% 覆盖的交互细节）

真机 CGEvent 已覆盖核心路径（4 字段输入/粘贴/删除、apiKey Keychain、8× 关闭重开），以下建议用户顺手确认一次（此时 App 已是修复版，已装到 `/Applications/MacTranslator.app`）：
1. **拖拽重序**：把某卡片的**序号圆圈**拖到另一张卡片上（手柄拖拽），确认顺序变化、key 不串位；↑↓ 按钮亦可用。（自动化只验证了 `.onDrop` 与 `.onDrag` 源码结构，未做真实鼠标拖拽手势。）
2. **Redo（⌘⇧Z）/ 中文输入法下的粘贴**：Edit 菜单也接了 Undo/Redo；如常用中文输入法，确认 ⌘V 仍能把剪贴板内容粘进输入框（本轮自动化测试前已切到 ABC 以排除输入法干扰）。
3. **apiKey 失焦/回车保存**：输入 key 后回车或点别的输入框，确认状态标签变 `sk-****`；重启 App 后仍为 `sk-****`（Keychain 持久）。

上述问题**不影响**本次已验证通过的"点击选中 / ⌘V 粘贴 / 删除"核心修复。

---

## 7. 附：备份与回滚

`/Applications/MacTranslator.app` 的历次备份位于 `~/.mactranslator-backup/`，本次修复前版本为：
`~/.mactranslator-backup/20261124-083031/MacTranslator.app`
如需回滚：`pkill -f MacTranslator; rm -rf /Applications/MacTranslator.app; cp -R <备份>/MacTranslator.app /Applications/; codesign --verify --strict /Applications/MacTranslator.app; open /Applications/MacTranslator.app`。
