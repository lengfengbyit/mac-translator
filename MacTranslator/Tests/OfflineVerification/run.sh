#!/bin/zsh
# 离线验证运行脚本（无需 XCTest / Xcode）
# 用法：在 MacTranslator/ 目录下执行  zsh Tests/OfflineVerification/run.sh
set -o pipefail

cd "$(dirname "$0")/../.." || exit 1

SRC="Sources/MacTranslator"
OUT="/tmp/qa_offline_verification"

swiftc -target x86_64-apple-macosx13.0 \
  "$SRC/Core/Models/Enums.swift" \
  "$SRC/Core/Models/AppSettings.swift" \
  "$SRC/Core/Models/LLMInterface.swift" \
  "$SRC/Core/Models/TranslationModels.swift" \
  "$SRC/Core/Protocols/LLMProviding.swift" \
  "$SRC/Core/Protocols/PersistenceProtocols.swift" \
  "$SRC/Core/Extensions/String+Hash.swift" \
  "$SRC/Core/Extensions/Bundle+Info.swift" \
  "$SRC/Services/LLMGateway.swift" \
  "$SRC/Services/CacheService.swift" \
  "Tests/OfflineVerification/OfflineVerification.swift" \
  -o "$OUT"

if [ $? -ne 0 ]; then
  echo "编译失败"
  exit 1
fi

"$OUT"

# ===== 持久化验证（真实 Core Data，临时 sqlite）=====
PERSIST_OUT="/tmp/qa_persistence_verification"
swiftc -target x86_64-apple-macosx13.0 \
  "$SRC/Core/Models/Enums.swift" \
  "$SRC/Core/Models/AppSettings.swift" \
  "$SRC/Core/Models/LLMInterface.swift" \
  "$SRC/Core/Models/TranslationModels.swift" \
  "$SRC/Core/Protocols/PersistenceProtocols.swift" \
  "$SRC/Core/Extensions/Bundle+Info.swift" \
  "$SRC/Services/CoreDataStack.swift" \
  "$SRC/Services/HistoryStore.swift" \
  "Tests/OfflineVerification/PersistenceVerification.swift" \
  -o "$PERSIST_OUT"

if [ $? -ne 0 ]; then
  echo "持久化验证编译失败"
  exit 1
fi

"$PERSIST_OUT"

# ===== 窗口生命周期验证（本次崩溃根因回归）=====
WINDOW_OUT="/tmp/qa_window_lifecycle_verification"
swiftc -target x86_64-apple-macosx13.0 \
  -framework AppKit \
  "Tests/OfflineVerification/WindowLifecycleVerification.swift" \
  -o "$WINDOW_OUT"

if [ $? -ne 0 ]; then
  echo "窗口生命周期验证编译失败"
  exit 1
fi

"$WINDOW_OUT" "$PWD" || exit 1

# ===== 输入框焦点/粘贴验证（本次输入框 Bug 回归）=====
FOCUS_OUT="/tmp/qa_input_focus_verification"
swiftc -target x86_64-apple-macosx13.0 \
  "Tests/OfflineVerification/InputFocusVerification.swift" \
  -o "$FOCUS_OUT"

if [ $? -ne 0 ]; then
  echo "输入框焦点验证编译失败"
  exit 1
fi

"$FOCUS_OUT" "$PWD" || exit 1

# ===== 结果窗修复回归（透明度 / 关闭按钮 / 拖动 / 位置记忆）=====
PANEL_OUT="/tmp/qa_result_panel_verification"
swiftc -target x86_64-apple-macosx13.0 \
  "$SRC/Core/Models/Enums.swift" \
  "$SRC/Core/Models/AppSettings.swift" \
  "$SRC/Core/Models/LLMInterface.swift" \
  "$SRC/Core/Models/TranslationModels.swift" \
  "$SRC/Core/Protocols/PersistenceProtocols.swift" \
  "$SRC/Core/Extensions/Bundle+Info.swift" \
  "Tests/OfflineVerification/ResultPanelVerification.swift" \
  -o "$PANEL_OUT"

if [ $? -ne 0 ]; then
  echo "结果窗修复验证编译失败"
  exit 1
fi

"$PANEL_OUT" "$PWD" || exit 1

# ===== OCR 链路 + 结果页布局回归（权限 / ScreenCaptureKit / 阅读顺序 / 自适应高度）=====
OCR_OUT="/tmp/qa_ocr_layout_verification"
swiftc -target x86_64-apple-macosx13.0 \
  -framework Vision \
  "$SRC/Services/VisionOCRService.swift" \
  "Tests/OfflineVerification/OCRAndResultLayoutVerification.swift" \
  -o "$OCR_OUT"

if [ $? -ne 0 ]; then
  echo "OCR / 结果页布局验证编译失败"
  exit 1
fi

"$OCR_OUT" "$PWD" || exit 1
