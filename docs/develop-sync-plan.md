# Lightroom Develop Sync 批次修圖同步功能實作計畫書

**專案名稱**：LumiBase (macOS Native DAM & RAW Processing)  
**文件版本**：v1.0.0  
**日期**：2026 年 9 月 25 日  
**目標**：在 LumiBase 中完整實現 1:1 媲美 Adobe Lightroom Classic 的 Develop 模組批次同步與修圖設定管理系統，包含 **Sync Settings 對話框（選擇性同步）**、**Auto Sync（即時自動同步）** 以及 **Copy / Paste Settings（複製／貼上設定）**。

---

## 1. 架構總覽 (Architecture Overview)

```
┌─────────────────────────────────────────────────────────────────────────────────┐
│                        LumiBase Develop Sync 核心架構                           │
├──────────────────────────────────────┬──────────────────────────────────────────┤
│           來源照片 (Source)          │              目標照片集合 (Targets)      │
│     PrimarySelectedAsset (基準照片)   │          SelectedAssetIDs (多選照片)     │
│                                      │                                          │
│   ┌──────────────────────────────┐   │   ┌──────────────────────────────────┐   │
│   │ XMPMetadata (Develop Edits)  │   │   │ Target Photo A (XMP Updated)     │   │
│   │  - White Balance (Temp/Tint) │   │   ├──────────────────────────────────┤   │
│   │  - Basic Tone (Exp/HL/Sh...) │   │   │ Target Photo B (XMP Updated)     │   │
│   │  - Presence (Tex/Clarity...) │   │   ├──────────────────────────────────┤   │
│   │  - Profile / Treatment       │   │   │ Target Photo C (XMP Updated)     │   │
│   └──────────────┬───────────────┘   │   └──────────────────────────────────┘   │
├──────────────────┼───────────────────┴──────────────────────────────────────────┤
│                  ▼                                                              │
│       DevelopSyncOptions (遮罩遮罩過濾器)                                       │
│       ┌──────────────────────────────────────────────────────────────────────┐  │
│       │ [✓] White Balance      [✓] Basic Tone (Exp, Contrast, HL, Sh...)     │  │
│       │ [✓] Presence           [✓] Treatment & Profile                       │  │
│       │ [ ] Crop (Geometry)    [ Check All | Check None | Modified Only ]   │  │
│       └──────────────────────────────────┬───────────────────────────────────┘  │
│                                          │                                      │
├──────────────────────────────────────────┼──────────────────────────────────────┤
│               三大同步驅動模式           │              底層寫入與預覽更新      │
│                                          │                                      │
│  1. Sync Settings (Cmd+Shift+S)  ────────┤                                      │
│  2. Auto Sync (即時滑桿連動)      ────────┼──►   allAssets 記憶體更新            │
│  3. Copy / Paste (Cmd+Shift+C/V) ────────┤         │                            │
│                                                    ▼                            │
│                                          300ms Debounced XMPWriter (Sidecar)    │
│                                                    │                            │
│                                                    ▼                            │
│                                          LiveDevelopPreviewEngine 批次重繪預覽  │
└─────────────────────────────────────────────────────────────────────────────────┘
```

---

## 2. 核心功能與工作流程 (Core Features)

### 2.1 選擇性同步對話框 (Selective Sync Settings Dialog)
- **觸發途徑**：
  - 多選照片狀態下點擊右側檢查器底部的 **`Sync...`** 按鈕。
  - 快捷鍵 **`⌘ + ⇧ + S`**。
  - 頂部選單 **Develop** $\rightarrow$ **Sync Settings...**。
- **參數分類與控制項目**：
  - **白平衡 (White Balance)**：色溫 (`temperature`)、色調 (`tint`)。
  - **基礎色調 (Basic Tone)**：曝光 (`exposure2012`)、對比度 (`contrast2012`)、亮部 (`highlights2012`)、陰影 (`shadows2012`)、白色 (`whites2012`)、黑色 (`blacks2012`)。支援區域一鍵「全選／全取消」。
  - **細節與質感 (Presence)**：紋理 (`texture`)、清晰度 (`clarity2012`)、去朦朧 (`dehaze`)、自然飽和度 (`vibrance`)、飽和度 (`saturation`)。支援區域一鍵「全選／全取消」。
  - **處理與設定檔 (Treatment & Profile)**：相機描述檔 (`cameraProfile`)、黑白模式 (`convertToGrayscale`)。
  - **幾何 (Geometry)**：裁切標記 (`hasCrop`)，預設維持關閉以避免誤套用。
- **智慧輔助按鈕**：
  - **Check All**：快速全選所有調色參數（裁切除外）。
  - **Check None**：一鍵清空所有勾選。
  - **Modified Only**：自動分析來源照片，僅勾選**非預設值／有被調整過**的參數。

---

### 2.2 即時自動同步 (Auto Sync Mode)
- **觸發途徑**：
  - 點擊右下角的 **Auto Sync 圓點開關**。
  - 快捷鍵 **`⌥ + ⌘ + ⇧ + S`**（或 `⌥ + ⌘ + S`）。
  - 頂部選單 **Develop** $\rightarrow$ **Toggle Auto Sync**。
- **即時連動邏輯**：
  - 開啟後，按鈕呈現高亮 Lightroom 金黃色標記（`Auto Sync`）。
  - 當使用者在多選照片狀態下調整任何滑桿時，**主照片與所有次要選取照片的記憶體參數同步被即時變更**。
  - 拖曳結束（Mouse Up）或點擊 Auto Tone / Reset 時，批次觸發 300ms Debounce 的非同步 XMP 側邊檔案寫入。

---

### 2.3 複製與貼上修圖設定 (Copy & Paste Settings)
- **Copy Settings (`⌘ + ⇧ + C`)**：
  - 彈出複製設定對話框，供使用者勾選要複製至剪貼簿的修圖屬性，儲存至 `AppState.copiedDevelopSettings` 與 `AppState.copiedSyncOptions`。
- **Paste Settings (`⌘ + ⇧ + V` 或 `⌥ + ⌘ + V`)**：
  - 將已複製的修圖參數一次性套用至當前選取的照片（支援單選或多選批次貼上）。

---

## 3. 模組架構與檔案清單

### 3.1 核心資料模型
- [`LumiBase/Models/DevelopSyncOptions.swift`](file:///Users/tedyeng/XcodeProjects/LumiBase/LumiBase/Models/DevelopSyncOptions.swift)：
  - 定義 `DevelopSyncOptions` 結構體。
  - 提供 `checkAll()`、`checkNone()`、`checkModified(from:)` 輔助方法。
  - 提供 `apply(from:to:)` 進行非破壞性欄位覆蓋。

### 3.2 UI 介面層
- [`LumiBase/Views/Inspector/SyncSettingsDialogView.swift`](file:///Users/tedyeng/XcodeProjects/LumiBase/LumiBase/Views/Inspector/SyncSettingsDialogView.swift)：
  - 採用雙欄式深色專業 UI 配置（Column 1: WB & Tone；Column 2: Presence, Treatment, Geometry）。
  - 支援 `.synchronize` 與 `.copy` 雙模式。
  - 支援鍵盤快速確認（`Enter` 執行、`Esc` 取消）。
- [`LumiBase/Views/Inspector/RightInspectorView.swift`](file:///Users/tedyeng/XcodeProjects/LumiBase/LumiBase/Views/Inspector/RightInspectorView.swift)：
  - 於右側檢查器底部釘選固定操作列 `developFooterBar`：
    - 左側：`Copy...` 與 `Paste` 按鈕。
    - 右側：單選時顯示 `Reset`，多選時顯示 `Auto Sync 開關` 與 `Sync... / Auto Sync 按鈕`。
- [`LumiBase/Views/MainLayoutView.swift`](file:///Users/tedyeng/XcodeProjects/LumiBase/LumiBase/Views/MainLayoutView.swift)：
  - 整合 `showSyncDialog` 與 `showCopySettingsDialog` 的 `.sheet` 彈出容器。
  - 監聽全域 NotificationCenter 事件。

### 3.3 狀態管理與鍵盤處理
- [`LumiBase/App/AppState.swift`](file:///Users/tedyeng/XcodeProjects/LumiBase/LumiBase/App/AppState.swift)：
  - 狀態屬性：`isAutoSyncEnabled`、`showSyncDialog`、`showCopySettingsDialog`、`copiedDevelopSettings`、`copiedSyncOptions`、`lastSyncOptions`。
  - 同步 API：`syncDevelopSettings()`、`copyDevelopSettings()`、`pasteDevelopSettings()`、`toggleAutoSync()`。
  - 增強 `updateDevelopSettings()`：於 `isAutoSyncEnabled` 啟用時自動連動所有選取資產。
  - 全域按鍵攔截 `handleGlobalKeyEvent()`：精確捕捉 `⌘⇧S`、`⌥⌘⇧S`、`⌘⇧C`、`⌘⇧V`、`⌥⌘V`。
- [`LumiBase/App/LumiBaseApp.swift`](file:///Users/tedyeng/XcodeProjects/LumiBase/LumiBase/App/LumiBaseApp.swift)：
  - 新增 macOS 系統頂部 `Develop` 選單，標準化選單鍵盤快捷鍵。

---

## 4. 快捷鍵對應表 (Keyboard Shortcuts Matrix)

| 功能 (Feature) | macOS 快捷鍵 | 作用情境 (Context) |
| :--- | :--- | :--- |
| **Sync Settings...** | `⌘ + ⇧ + S` | 多選照片時彈出同步設定視窗 |
| **Toggle Auto Sync** | `⌥ + ⌘ + ⇧ + S` 或 `⌥ + ⌘ + S` | 切換即時多選自動同步模式 |
| **Copy Settings...** | `⌘ + ⇧ + C` | 彈出複製修圖參數視窗 |
| **Paste Settings** | `⌘ + ⇧ + V` 或 `⌥ + ⌘ + V` | 貼上修圖參數至選取照片 |
| **Auto Tone** | 介面點擊 | 自動演算最佳高光/陰影與曝光 |
| **Reset Basic** | 介面點擊 | 復位所有基本修圖參數為 0 |

---

## 5. 測試覆蓋與驗證矩陣 (Test Verification)

單元測試位於 [`Tests/LumiBaseTests/DevelopSyncTests.swift`](file:///Users/tedyeng/XcodeProjects/LumiBase/Tests/LumiBaseTests/DevelopSyncTests.swift)，包含以下測試項目：

1. **`testSyncOptionsSelectivity`**：驗證選擇性遮罩僅套用指定欄位，未勾選項目（如白平衡、相機描述檔）完全維持目標照片原值。
2. **`testSyncOptionsCheckAllAndCheckNone`**：驗證全選與全取消開關運作。
3. **`testSyncOptionsCheckModifiedOnly`**：驗證 Modified Only 智慧演算法能準確抓取來源照片中非預設的修改項目。
4. **`testSyncDevelopSettingsAcrossSelectedPhotos`**：驗證多選批次同步時，來源照片正確寫入所有被選取目標，未選取之照片不受任何影響。
5. **`testCopyAndPasteDevelopSettings`**：驗證複製至剪貼簿與貼上至多張照片之完整流程。
6. **`testAutoSyncRealTimeSliderUpdates`**：驗證 Auto Sync 開啟時，滑桿調整、Auto Tone、Reset 能即時連動所有選取照片；關閉時則嚴格保持單照片隔離。

> **測試執行結果**：全數 116 項單元測試（包含 DevelopSyncTests、ProcessedROICacheTests、PreviewPreloaderTests 等）全部 Passed (0 Failures)。
