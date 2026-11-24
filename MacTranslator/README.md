# 划译（MacTranslator）

菜单栏常驻的 macOS 翻译工具：全局快捷键划词翻译 / 区域截图 OCR 翻译，多个 OpenAI 兼容接口按优先级 Failover，历史与收藏本地持久化。

## 环境要求

- macOS 13.0+；构建二选一：Xcode 15+（Swift 5.9+），或仅 Command Line Tools（见下方「无 Xcode 构建安装」）
- 无第三方运行时依赖，全部使用系统框架

## 工程结构

- `MacTranslator.xcodeproj`：主工程（App 目标，非沙盒）
- `Sources/MacTranslator/App`：入口、组装根、Coordinator、菜单栏
- `Sources/MacTranslator/Core`：模型、协议、扩展
- `Sources/MacTranslator/Services`：热键、取词、OCR、网关、缓存、配置存储、权限、持久化
- `Sources/MacTranslator/UI`：AppKit 窗口容器 + SwiftUI 内容视图
- `Sources/MacTranslator/Resources`：Info.plist、entitlements、Core Data 模型、资源目录
- `Tests/MacTranslatorTests`：核心逻辑单元测试
- `scripts`：构建、签名公证、DMG 打包脚本

## 构建与运行

```bash
# 直接用 Xcode 打开
open MacTranslator.xcodeproj

# 或使用构建脚本（Debug / Release 可切换）
./scripts/build.sh Debug
```

首次运行后仅显示菜单栏图标（无 Dock 图标）。下拉菜单：划词翻译（⌥D）、OCR 翻译（⌥⇧S）、历史与收藏、设置、退出。

## 无 Xcode 构建安装（Command Line Tools 路径）

本机**没有 Xcode.app 也能构建**：只要 `xcode-select -p` 指向
`/Library/Developer/CommandLineTools`（Swift 6.1.2 实测），不依赖 `xcodebuild`。

```bash
cd MacTranslator
chmod +x build.sh scripts/install.sh

./build.sh                 # 只构建，产物：build/MacTranslator.app
./scripts/install.sh       # 构建 → 备份旧版 → 装进 /Applications → 重设授权 → 启动
```

`build.sh` 流程：定位 SDK / swiftc / plutil / codesign → 生成 `Contents/Info.plist`
（替换 `$(EXECUTABLE_NAME)` 等 Xcode 变量）→ 编译 Core Data 模型 → `swiftc`
一次编译全部 45 个源文件 → 组装 bundle → 签名（需 `-framework ScreenCaptureKit`）。

两个关键实现细节（改动构建脚本时别踩回去）：

- **Core Data 模型**：Command Line Tools 不带 `momc` / `actool`。脚本内嵌一个 Swift
  helper 解析 `Model.xcdatamodel/contents`，生成 `Contents/Resources/Model.momd/Model.mom`
  （系统有 `momc` 时优先用它）。helper 给实体的 `representedClassName` 加上
  `MacTranslator.` 模块前缀——Swift 类在可执行文件里注册为 `MacTranslator.<类名>`，
  少了前缀运行时 `HistoryRecordEntity(context:)` 会找不到类。`Assets.xcassets` 目前
  只有 `Contents.json`，菜单栏图标用的是 `NSImage.statusAvailableName` 系统图，
  因此不需要 `Assets.car`。
- **入口是顶层代码**：`Sources/MacTranslator/App/main.swift` 没有 `@main`，
  `swiftc` 命令**不能加** `-parse-as-library`。

构建完可自检：

```bash
plutil -lint build/MacTranslator.app/Contents/Info.plist
codesign -dv build/MacTranslator.app
file build/MacTranslator.app/Contents/MacOS/MacTranslator
ls build/MacTranslator.app/Contents/Resources/Model.momd
open build/MacTranslator.app && pgrep -fl MacTranslator
```

### 截图 OCR：权限、快捷键与结果窗

**屏幕录制权限是 OCR 的硬前提**。macOS 15 上被拒绝的 App 仍能截到桌面壁纸，
症状是「框选成功，却提示未识别到文字」。权限状态现在用
`CGPreflightScreenCaptureAccess()` 精确查询，不再靠「截图是否全黑」猜；
未授权时结果窗会显示带「打开屏幕录制设置」按钮的错误卡片，设置 → OCR 识别
也有「前往设置」入口。开启开关后回到设置页状态会自动刷新。

截图主路径为 ScreenCaptureKit（macOS 15.2+，多屏坐标无关），macOS 13/14
及 SCK 异常时回退到 `CGWindowListCreateImage`。框选支持 Esc / 右键取消、
实时尺寸提示；识别结果按阅读顺序重排并过滤低置信度乱码。

如果本机同时运行 Bob（默认占用 ⌥D）或 iShot 类截图工具，全局快捷键可能被
更底层的事件监听截获。`HotkeyService` 在注册失败时会自动切换到备用组合并把
**实际生效**的快捷键写回 `settings.json`，菜单栏也会显示调整提示；也可以
在「设置 → 快捷键」自定义，或直接用菜单栏的「OCR 翻译」入口（任何权限状态下都可点）。

结果窗按内容自适应高度（不再固定 440×470），卡片式布局；「设置 → 通用」
可调不透明度与重置窗口位置，工具栏图钉可让窗口在点击外部时保持不关闭。

### 朗读音色

结果窗可朗读原文与译文。旧实现用 `availableVoices.first(where:)` 盲选，macOS 15 上英文稳定命中 `Albert`——Apple 遗留的 novelty 特效音（同批还有 Bells / Boing / Zarvox），中文则恰好抓到 `Eddy (zh-CN)`。

现改为 `SpeechVoiceService`：语音目录整体排除 `com.apple.speech.synthesis.voice.*`；按文本语言（假名 / 韩文 / 汉字 / 其他）匹配同音色家族，首选 en-US / zh-CN；单语种音色有显式跨语言回退。默认 `eddy`，英文 `com.apple.eloquence.en-US.Eddy`、中文 `com.apple.eloquence.zh-CN.Eddy`（保持原有听感），日韩也有同系列。

`设置 → 通用 → 朗读音色` 提供 10 个音色下拉与中英文试听按钮，选择写入 `settings.json` 的 `speechVoiceFamily`，每次朗读都读最新值，结果窗已开着也即时生效。「跟随系统默认」返回 `nil` 而不是空字符串——macOS 15 的 `defaultVoice.rawValue` 是空哨兵值。

详见 `11-朗读音色修复报告.md`。

### 签名与重新授权

默认 `SIGN=auto`：有受信任的自签证书身份就复用，否则退回 ad-hoc。
可用 `SIGN=adhoc ./build.sh` / `SIGN=cert ./build.sh` 强制指定。

| 签名方式 | TCC 指定要求 | 重新编译后 |
|---|---|---|
| ad-hoc（兜底） | 二进制 cdhash | 要删掉重加一次 |
| 自签证书 + 系统域信任 | identifier + 证书根 | 不用动 |

自签证书方案的前提是证书根装进**系统域**（用户域不够，tccd 验不过签名链）：

```bash
sudo security add-trusted-cert -d -r trustRoot -p codeSign \
  -k /Library/Keychains/System.keychain ~/.viewtimer-sign/cert.pem
codesign --verify -R='anchor trusted' /Applications/MacTranslator.app   # 退出码须为 0
```

`install.sh` 自动处理：备份旧版到 `~/.mactranslator-backup/`、去掉 quarantine、
在最终路径重签名、注销重复 LaunchServices 注册，并且**仅在 ad-hoc 模式**重置
辅助功能与屏幕录制的授权记录（证书模式还去 reset 等于自断授权）。

## 权限说明（按需申请）

| 权限 | 用途 | 缺失影响 |
|---|---|---|
| 辅助功能 | AXUIElement 读取选中文本、模拟 ⌘C 兜底 | 划词仅可尝试浏览器 AppleScript |
| 屏幕录制 | 区域截图（ScreenCaptureKit；macOS 13/14 回退 `CGWindowListCreateImage`） | OCR 不可用，结果窗提示并引导授权 |
| 自动化 | 浏览器 AppleScript 取词 | 划词降级为 AX → ⌘C |

在「设置 → 权限」一键跳转系统设置。签名变更或 App 移动后需要重新授权。

## 数据与安全

- **apiKey 明文保存在本地配置文件** `~/Library/Application Support/mac_translator/settings.json`，文件权限 `600`。按用户要求已完全移除系统钥匙串：源码和二进制里都不再有任何 `SecItem*` 调用，不会再弹钥匙串授权框；旧版存于钥匙串的密钥已一次性静默迁移进该文件。
- apiKey 仅在发请求时放入 `Authorization` 头；接口列表一律遮罩显示 `sk-****`，不写入日志或提示文案。
- 该文件含明文密钥，请勿放进共享目录或云同步盘。
- 历史/收藏：Core Data（`~/Library/Application Support/mac_translator/MacTranslator.sqlite`）。
- 配置：`~/Library/Application Support/mac_translator/settings.json`。
- 缓存：`~/Library/Application Support/mac_translator/cache.json`（500 条 LRU，可在设置中开关/清除）。
- 支持 Ollama：`baseURL = http://localhost:11434/v1`，model 填本地模型名，apiKey 任意。

## 签名 / 公证 / DMG

```bash
export TEAM_ID="XXXXXXXXXX"
export SIGN_IDENTITY="Developer ID Application: Your Name (XXXXXXXXXX)"
./scripts/build.sh Release
./scripts/sign_notarize.sh
./scripts/package_dmg.sh
spctl -a -vv /Applications/MacTranslator.app   # 可选：校验公证结果
```

公证需要 Apple Developer 账号与 app 专用密码（`APPLE_ID` / `APP_PASSWORD` / `TEAM_ID`）。验证：`spctl -a -vv MacTranslator.app` 期望 `accepted, source=Notarized Developer ID`。

## 已知限制

- ScreenCaptureKit 截图主路径要求 macOS 15.2+；更老系统回退到 `CGWindowListCreateImage`（该 API 在新版 SDK 已标记 obsolete）。
- 多模态 OCR 只筛 `supportsVision` 接口；若没有启用视觉模型会提示用户配置。
- 自动复制 / 系统通知 / 替换选中文本属于 P2 备选，默认关闭且未实现。
