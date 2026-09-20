# LumiBase

> **Native macOS Digital Asset Manager (DAM) for Camera RAW & XMP workflows on Apple Silicon.**

LumiBase 是一套專為 macOS (特別是 Apple Silicon M 系列晶片) 打造的高效能 RAW 相片資產管理軟體。提供如 Adobe Lightroom Classic 般的直覺介面、秒級選圖反應、精確的 Adobe Camera RAW 色彩還原，以及非破壞性的雙向 XMP Sidecar 中繼資料同步。

---

## 🌟 核心特色 (Key Features)

- ⚡ **極速 RAW 解碼與選圖**：基於 Apple Silicon 統一記憶體架構與 Metal 硬體加速，實現毫秒級照片載入與縮圖算圖。
- 🎨 **1:1 Adobe Camera RAW 色彩還原**：
  - 整合 **Adobe Standard DCP (Digital Camera Profile)** 管理管線。
  - 完整支援 Adobe PV2012 色彩管線（曝光、色溫/色調、高光/陰影、對比、白色/黑色、鮮豔度、飽和度、去朦朧）。
  - 確保 **Grid 縮圖**、**Filmstrip 底片列** 與 **Loupe 大圖預覽** 色彩 100% 完全一致。
- 📂 **檔案總管樹狀目錄導覽 (File Explorer Tree)**：
  - 無限制層級目錄展開與即時瀏覽。
  - 直接存取本機目錄與外接 SSD/隨身碟（如 `/Volumes/Super SSD`）。
  - 自動記錄「曾經點擊過的目錄」（RECENT FOLDERS），並以清楚的分隔線與本機磁碟分開。
- 🔄 **雙向 XMP Sidecar 同步 (Non-Destructive)**：
  - 支援讀取與寫入標準 Adobe `.xmp` 副檔。
  - 評星等（Rating）或旗標（Pick/Reject）時自動產生 `.xmp`，不修改 RAW 原檔，並可無縫在 Adobe Lightroom Classic / Bridge / Capture One 中開啟。
- ⌨️ **Lightroom 經典快捷鍵操作**：
  - **Grid 2D 導覽**：`↑` / `↓` 整行跳轉，`←` / `→` 前後選取。
  - **檢視切換**：`Enter` / `Return` / `E` / `Space` 進入大圖預覽（Loupe View），`Esc` / `G` 返回網格（Grid View）。
  - **評分與旗標**：`0~5` 快速評星等，`P` 標記留用（Pick），`X` 標記剔除（Reject），`U` 取消標記（Unflag）。
  - **面板收合**：`Tab` 鍵快速收合/展開左右兩側面板。

---

## 📸 支援格式 (Supported Formats)

- **RAW 格式**：
  - Sony (`.ARW`)
  - Canon (`.CR2`, `.CR3`)
  - Nikon (`.NEF`)
  - Adobe / Leica / Apple ProRAW (`.DNG`)
  - Fujifilm (`.RAF`)
  - Panasonic (`.RW2`)
  - Olympus / OM System (`.ORF`)
- **通用圖片格式**：
  - JPEG (`.JPG`, `.JPEG`), TIFF (`.TIF`, `.TIFF`), HEIC, PNG

---

## ⌨️ 快速鍵一覽 (Keyboard Shortcuts)

| 動作 | 快捷鍵 |
| :--- | :--- |
| **進入大圖預覽 (Loupe View)** | `Enter` / `Return`、`E`、雙擊滑鼠 |
| **返回圖庫網格 (Grid View)** | `Esc`、`G` |
| **切換 網格 / 預覽** | `Space` (空白鍵) |
| **網格上下行移動** | `↑` (上鍵) / `↓` (下鍵) |
| **上一張 / 下一張** | `←` (左鍵) / `→` (右鍵) |
| **設定評分 (Rating)** | `0` (無)、`1` ~ `5` 星 |
| **標記旗標 (Flag)** | `P` (Pick 留用)、`X` (Reject 剔除)、`U` (Unflag 取消) |
| **收合/展開左右面板** | `Tab` |

---

## 🏗️ 架構與模組 (Architecture)

```
LumiBase/
├── App/                  # App 生命週期與 AppState 全域狀態中心
├── Models/               # PhotoAsset、XMPMetadata、CameraMetadata、FilterCriteria
├── Services/
│   ├── FileSystem/       # DirectoryWatcher (FSEvents), FolderScanner
│   ├── Image/            # AdobeColorPipeline (Metal), DCPProfileManager, RAWImageLoader, ThumbnailLoader
│   └── Metadata/         # XMPParser, XMPWriter, MetadataReader (EXIF)
├── Theme/                # LightroomTheme 深灰色系主題與組件
└── Views/                # GridView, LoupeView, FilmstripView, LeftSidebarView, RightInspectorView
```

---

## 🛠️ 開發與建置需求 (Requirements & Build)

- **系統需求**：macOS 14.0 (Sonoma) 或更新版本
- **硬體推薦**：Apple Silicon Mac (M1 / M2 / M3 / M4)
- **開發工具**：Xcode 15.0+ / Swift 5.9+

### 建置與測試指令

```bash
# 執行單元測試
swift test

# 建置 macOS 應用程式
xcodebuild -scheme LumiBase -destination 'platform=macOS' build
```

---

## 📖 詳細實作紀錄

詳細的架構演進、問題診斷與色彩管線設計細節請參閱：
👉 [`docs/implementation-record.md`](docs/implementation-record.md)
