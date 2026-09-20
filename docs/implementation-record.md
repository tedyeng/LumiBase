# LumiBase 實作紀錄與架構技術文件

**日期**：2026 年 9 月 20 日  
**專案名稱**：LumiBase (Native macOS DAM for Apple Silicon)  
**技術堆疊**：Swift 5.9+, SwiftUI, Metal, Core Image, ImageIO, AppKit, Apple Silicon (M-Series)

---

## 1. 專案背景與核心目標

LumiBase 是一套專為 macOS (特別針對 Apple Silicon M 系列晶片) 打造的高效能 RAW 相片資產管理系統（Digital Asset Management, DAM）。其核心目標是提供等同於 **Adobe Lightroom Classic** 級別的選圖速度、雙向 XMP Sidecar 中繼資料同步，以及精準的 Adobe Camera RAW 色彩還原能力。

---

## 2. 今日重點實作與問題修正紀錄

### 2.1 1:1 還原 Lightroom 影像色調與 DCP 色彩設定檔管線 (`AdobeColorPipeline` & `DCPProfileManager`)
- **問題現象**：套用 XMP 修圖參數（Develop Settings）的照片在預覽時，與 Adobe Lightroom Classic 內的色調、色彩濃淡有顯著差異。
- **根本原因**：
  1. 傳統 RAW 解碼若未經過 Camera Calibration 與 Adobe Standard DCP 矩陣轉換，在色溫（Kelvin/Tint）與色彩矩陣上與 Adobe PV2012 管線不一致。
  2. 原本解碼時可能在已套用機身風格曲線的 JPEG 上重複疊加 Exposure/Contrast/Saturation，造成「二次修圖」過度飽和與重對比。
- **解決方案**：
  - **DCP Profile 管理器 (`DCPProfileManager.swift`)**：自動識別相機型號（如 Sony A7C II / `ILCE-7CM2`, Sony A7 IV / `ILCE-7M4`, Canon, Nikon 等），並自系統目錄（`/Library/Application Support/Adobe/CameraRaw/CameraProfiles`）動態定位與載入官方 Adobe Camera Profile。
  - **Adobe PV2012 色彩管線 (`AdobeColorPipeline.swift`)**：以 Core Image 與 Metal 實作標準 PV2012 調整演算法：
    - `Exposure2012`：精準的線性 EV 增益調整。
    - `Temperature` & `Tint`：雙光源色度適應轉換。
    - `Highlights2012` & `Shadows2012`：非線性高光抑制與陰影細節拉回。
    - `Contrast2012`：以中灰度為軸心（Midtone Pivot）的 S 曲線轉換。
    - `Saturation` / `Vibrance` / `Dehaze`：維持人像膚色保護的飽和度與去朦朧演算法。
    - `Whites2012` & `Blacks2012`：動態範圍極限點校正。

---

### 2.2 縮圖 (Thumbnail) 與大圖預覽 (Loupe View) 色彩一致性校正
- **問題現象**：大圖預覽色調已校正，但下方 Filmstrip 底片列與 Grid 縮圖看起來顏色依然過濃。
- **根本原因**：縮圖產生時直接從 RAW 內嵌的機身預覽 JPEG 疊加 XMP 設定，而機身 JPEG 已包含相機風格曲線，重複疊加導致顏色超標。
- **解決方案**：
  - 更新 `ThumbnailLoader.swift`：當偵測到照片含有 XMP 修圖調整時，縮圖直接透過 `CIRAWFilter` 取得中性 RAW 基底，再經過相同的 `AdobeColorPipeline` 進行處理。
  - 升級版本化磁碟快取 `com.lumibase.thumbnails.v2`，確保縮圖與大圖預覽達成 **100% 色調完全一致**。

---

### 2.3 `CIRAWFilter` Undefined Key 例外崩潰修正
- **問題現象**：macOS 在呼叫 `CIRAWFilter` 時若使用 `setValue:forKey:` 設定某些 Adobe XMP 鍵值，會觸發 `NSUnknownKeyException` 崩潰。
- **解決方案**：將所有色調、曝光、曲線與色彩校正統一收斂至獨立的 Metal 著色管線（`AdobeColorPipeline`），避免向系統底層傳入未定義的 KVC 鍵。

---

### 2.4 照片選取狀態重設問題修正
- **問題現象**：在瀏覽或過濾相片時，選取的照片狀態偶爾會跳掉或選取跑位。
- **根本原因**：`PhotoAsset` 原先使用隨機生成的 `UUID()` 作為識別碼，當資產刷新或重新掃描時 ID 改變。
- **解決方案**：將 `PhotoAsset.id` 改為以標準化實體檔案路徑（`fileURL.standardizedFileURL.path`）為唯一識別碼，確保識別碼具有確定性與不可變性。

---

### 2.5 Grid View 2D 鍵盤導覽與 Loupe 大圖預覽切換
- **需求**：
  1. 在 Grid 網格中可以使用 `↑`（上鍵）與 `↓`（下鍵）整行跳轉移動。
  2. 選中照片後按下 `Enter` / `Return` 鍵可立即進入大圖預覽模式。
- **實作**：
  - 在 `GridView.swift` 透過 `GeometryReader` 即時依據視窗寬度與縮圖大小計算目前欄數（`gridColumnsCount`）。
  - `↑` 鍵往前跳轉 $N$ 張，`↓` 鍵往後跳轉 $N$ 張；`←` / `→` 鍵依序選取上一張 / 下一張。
  - 支援 `Enter` / `Return` 鍵（或 `E` / 空白鍵）直接切換至 `LoupeView`，按 `Esc` / `G` 鍵返回 Grid 檢視。

---

### 2.6 左側欄檔案總管與無限制樹狀目錄瀏覽 (Folder Tree)
- **需求**：
  1. 類似檔案總管在左側，讓使用者可以點開目錄並層層點開尋找目標資料夾。
  2. 曾經點擊過的目錄置於最上方（RECENT FOLDERS），並以分隔線與電腦磁碟/本機目錄分開。
  3. 修正箭頭與資料夾圖示展開/收合失靈的問題，並移除多餘的 "Current Folder" 橫幅。
- **實作**：
  - **解除 App Sandbox 限制**：調整 `LumiBase.entitlements`，允許程式直接讀取外接硬碟（如 `Super SSD`）、`/Volumes` 磁碟槽與本機各層目錄。
  - **無限層級遞迴目錄樹 (`FolderTreeRow`)**：動態非同步載入子目錄，自動過濾隱藏檔與系統垃圾目錄。
  - **整合觸發區**：將目錄前方的箭頭（`>`）與資料夾圖示（📁）整合為同一個展開/收合按鈕，支援展開與收合；點擊文字名稱則為選取該資料夾。
  - **分區架構**：
    - **最上方**：`RECENT FOLDERS`（紀錄最近開啟與點擊的目錄）。
    - **分隔線**：清晰的 Divider 分隔線。
    - **中間**：`PLACES & DISKS`（電腦本機常用位置與外接磁碟）。
    - **最下方**：`SMART COLLECTIONS`（智慧篩選集合）。

---

### 2.7 移除 Color Label（色標）功能
- **需求**：使用者不需要 Color Label 功能，予以清理精簡。
- **實作**：
  - 移除左側欄的 Color Labels 分類。
  - 移除頂部篩選列的顏色圓點按鈕。
  - 移除 Grid 與 Filmstrip 縮圖上的色標指示點與外框色。
  - 移除右側檢查器的色標調色盤。
  - 移除右鍵選單與 `6~9` 的鍵盤快速鍵。

---

### 2.8 無 XMP 照片的 Rating 儲存機制
- **機制設計**：
  - 當照片原本沒有 `.xmp` 檔時，只要在 LumiBase 內為其設定星等（Rating）或旗標（Pick/Reject），系統會在該照片同目錄下自動產生標準 Adobe 格式的 `.xmp` 副檔（如 `DSC01234.xmp`）。
  - **特點**：100% 非破壞性（不修改 RAW 原始本體），且未來直接相容於 Adobe Lightroom Classic、Bridge 與 Capture One。

---

## 3. 模組架構總覽

```
LumiBase/
├── App/
│   ├── AppState.swift              # 全域狀態中心 (資料夾管理、選取、鍵盤監聽、XMP同步)
│   └── LumiBaseApp.swift           # SwiftUI 應用程式入口
├── Models/
│   ├── CameraMetadata.swift        # EXIF / 相機參數資料模型
│   ├── FilterCriteria.swift        # 智慧篩選與搜尋條件
│   ├── PhotoAsset.swift            # 照片資產模型 (唯一路徑識別碼、XMP路徑解析)
│   └── XMPMetadata.swift           # XMP 中繼資料與 Camera RAW 修圖參數模型
├── Services/
│   ├── FileSystem/
│   │   ├── DirectoryWatcher.swift  # FSEvents 即時檔案變更監聽器
│   │   └── FolderScanner.swift     # 非同步多核心目錄掃描器
│   ├── Image/
│   │   ├── AdobeColorPipeline.swift # Metal 加速 Adobe PV2012 色彩管線
│   │   ├── DCPProfileManager.swift  # Adobe DCP 相機設定檔解析與定位
│   │   ├── HistogramCalculator.swift# RGB / 亮度直方圖即時計算
│   │   ├── RAWImageLoader.swift     # 高解析 RAW 預覽解碼器
│   │   ├── ThumbnailCacheManager.swift # 雙層 (Memory + Disk v2) 縮圖快取
│   │   └── ThumbnailLoader.swift    # 智慧縮圖載入器 (RAW中性基底 + 色彩同步)
│   └── Metadata/
│       ├── MetadataReader.swift    # CGImageSource EXIF / TIFF 讀取器
│       ├── XMPParser.swift         # Adobe XMP Packet XML 解析器
│       └── XMPWriter.swift         # Adobe XMP Sidecar XML 產生器
├── Theme/
│   ├── Components/Badges.swift     # 星等、旗標等 UI 組件
│   └── LightroomTheme.swift        # Lightroom 經典深灰色系主題
└── Views/
    ├── Center/
    │   ├── FilmstripView.swift     # 底部底片縮圖導覽列
    │   ├── GridView.swift          # 主圖庫 2D 網格視圖
    │   ├── LoupeView.swift         # 放大放大鏡全螢幕預覽視圖
    │   └── PhotoGridItemView.swift # 網格單張照片卡片組件
    ├── Inspector/
    │   ├── EXIFInfoView.swift      # EXIF 相機拍攝資訊
    │   ├── HistogramView.swift     # 即時直方圖
    │   ├── RightInspectorView.swift# 右側檢查器面板
    │   └── XMPMetadataEditorView.swift # XMP 中繼資料與修圖參數編輯
    ├── Sidebar/
    │   └── LeftSidebarView.swift   # 左側檔案總管、磁碟樹與智慧集合
    └── Toolbar/
        ├── BottomControlsBarView.swift # 底部縮圖縮放與張數統計列
        └── TopFilterBarView.swift  # 頂部搜尋與星等/旗標篩選列
```

---

## 4. 測試與驗證結果

- **自動化單元測試 (`swift test`)**：
  - `AdobeColorPipelineProcessing`：通過
  - `CameraMetadataFormatting`：通過
  - `DCPProfileManagerNormalizationAndDiscovery`：通過
  - `HistogramComputation`：通過
  - `SupportedFileTypes`：通過
  - `ThumbnailCacheKeyGeneration`：通過
  - `FilterCriteriaMatching`：通過
  - `ParseAdobeXMPStandard`：通過
  - `ParseCameraRawDevelopSettings`：通過
  - `XMPRoundTrip`：通過
  - **共 10/10 測試全數通過，0 錯誤。**
- **專案建置 (`xcodebuild`)**：`** BUILD SUCCEEDED **`
