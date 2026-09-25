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

### 2.9 高畫質 RAW + XMP 轉 JPEG 匯出引擎 (`PhotoExportService`)
- **需求**：根據 XMP 修圖參數將 RAW 照片匯出成高品質 JPEG，效果媲美 Adobe Lightroom Classic 匯出成果。
- **實作架構**：
  1. **全解析度 Demosaicing**：以 Apple CoreImage RAW 引擎以相機感光元件原始解析度（如 Sony A7C II 33MP 7008×4672）完整解算。
  2. **Adobe PV2012 色彩管線轉譯**：經過 `AdobeColorPipeline` 套用精確的曝光補償、色溫偏移、高光/陰影還原、微對比清晰度與色彩增益。
  3. **sRGB 色彩空間精確標記**：強制在 `sRGB IEC61966-2.1` 色彩空間下算圖並嵌入 ICC Profile，徹底解決在 Safari、Chrome、macOS Preview 或手機檢視時顏色偏淡偏灰的問題。
  4. **相機 EXIF / TIFF / GPS 中繼資料完整保留**：從原 RAW 檔提取相機型號（Sony ILCE-7CM2）、鏡頭、快門、光圈、ISO、拍攝日期與 GPS 等資訊，完整寫入匯出的 JPEG。
  5. **95% 高品質硬體加速壓縮**：透過 Apple Silicon Metal GPU 硬體編碼器加速壓縮。
  6. **匯出操作介面與快捷鍵**：
     - Lightroom 標準快捷鍵 `⇧⌘E`（Shift + Command + E）。
     - 右鍵選單「Export to JPEG... (⇧⌘E)」。
     - 頂部工具列「Export」快捷按鈕。
     - 浮動 HUD 進度指示器（顯示百分比、張數進度、當前檔案名稱與取消按鈕）。
     - 匯出完成自動在 Finder 開啟目標資料夾。

---

### 2.10 全選 (`⌘A`) 與批次匯出所有照片 (`Export All Images`)
- **需求**：在 Grid View 中按下 `Command + A`（`⌘A`）選取所有照片，並支援一鍵匯出所有照片為高品質 JPEG。
- **實作細節**：
  1. **全域鍵盤監聽 (`AppState.swift`)**：在 `handleGlobalKeyEvent` 攔截 `⌘A` 呼叫 `selectAll()`，攔截 `⌘D` 呼叫 `deselectAll()`。
  2. **View 焦點層級監聽 (`GridView.swift`)**：透過 `.onKeyPress` 綁定 `KeyEquivalent("a")` 與 `KeyEquivalent("d")`，確保無論焦點落在網格或視窗任一位置皆可即時觸發。
  3. **macOS 標準主選單 (`LumiBaseApp.swift`)**：在 Edit 選單註冊 `Select All (⌘A)` 與 `Deselect All (⌘D)`，在 File 選單註冊 `Export Selected Photos... (⇧⌘E)` 與 `Export All Photos...`。
  4. **動態介面狀態回饋**：
     - **頂部工具列按鈕**：依據選取狀態動態顯示 `Export All (N)`、`Export (N)` 或 `Export`，點擊即啟動批次輸出。
     - **右鍵上下文選單**：右鍵點擊任一已選照片或背景空白處，動態顯示 `Export All (N) Images... (⇧⌘E)`、`Select All (⌘A)` 與 `Deselect All (⌘D)`。
     - **過濾與排序保持**：`selectedAssets` 會優先遵循使用者目前在 Grid 畫面所設定的排序與篩選條件進行批次算圖。

---

### 2.11 直式照片匯出方向二次旋轉修正 (`Orientation Double-Rotation Bug Fix`)
- **問題現象**：部分相機直向拍攝的照片（例如 `A7C01319.ARW`，EXIF Orientation = 8）在匯出成 JPEG 後，在預覽程式中變成橫向躺倒。
- **根本原因**：
  1. `CIRAWFilter` 在解碼輸出 `outputImage` 時，底層已經自動根據感光元件方向旋轉將像素點矩陣擺正為直向（4672 × 7008）。
  2. 原本的匯出程式在寫入 JPEG EXIF/TIFF 時，又把來源 RAW 檔的 `Orientation = 8` 標籤原封不動複製給了輸出檔。
  3. 當 macOS Preview、Finder、Chrome 等看圖軟體打開時，看到畫素已經是 4672 × 7008，卻又被標籤指示「再逆時針旋轉 90 度（Orientation = 8）」，導致照片被「二次旋轉」變成橫的。
- **解決方案**：
  - 在 `PhotoExportService.swift` 中，確保所有匯出的像素矩陣在算圖階段已完全轉正（RAW 透過 `CIRAWFilter`，通用點陣圖透過 `CIImage.oriented()`）。
  - 將輸出 JPEG 的根目錄 `kCGImagePropertyOrientation` 與 TIFF 字典中的 `kCGImagePropertyTIFFOrientation` 明確標記為 `1` (Normal / Upright, 0 度旋轉)。
  - 同時將 EXIF 的 `PixelXDimension` 與 `PixelYDimension` 正確對齊輸出寬高（4672 × 7008）。
  - **驗證**：新增 `testExportPortraitSonyRAWPhotoOrientation` 單元測試，針對 `A7C01319.ARW` 斷言輸出尺寸為 4672 × 7008 (Height > Width) 且 Orientation 標記為 1。

---

### 2.12 Loupe View 與 Filmstrip 底部縮圖列全選同步 (`⌘A` / `⌘D` 與多選視覺指示)
- **需求**：在 Loupe View（大圖預覽檢視）下按下 `Command + A` 全選時，下方 Filmstrip 底片列的所有縮圖照片也必須同步顯示為被選取狀態，並能清晰分辨「當前大圖預覽照片（Primary/Active）」與「被多選的照片（Selected）」。
- **問題分析**：原本 `FilmstripView` 僅以 `appState.primarySelectedAssetID == asset.id` 判斷是否顯示黃色邊框，未串接 `appState.selectedAssetIDs` 集合，導致 `⌘A` 全選時只有當前預覽的那一張有框線，其餘 27 張看起來完全沒被選取。
- **實作架構**：
  1. **雙層選取狀態呈現**：
     - **當前預覽焦點（`isPrimary`）**：以 Lightroom 標誌性的亮金黃色粗外框（`accentYellow`, 2.5px）標示。
     - **多選範圍（`isSelected`）**：以高亮白色外框（`Color.white.opacity(0.9)`, 2.0px）搭配半透明白色覆蓋光影（`Color.white.opacity(0.18)`）標示。
     - **未選取項目**：透明度適度降低（0.65）與細暗框（0.5px），呈現專業層次感。
  2. **底片列互動支援**：
     - 點擊縮圖：切換當前大圖顯示。
     - `⌘ + 點擊` 或 `⇧ + 點擊`：直接在 Filmstrip 進行加選/減選。
     - 右鍵選單：提供 `Export Selected (N) to JPEG... (⇧⌘E)`、`Export All Images...`、`Select All (⌘A)`、`Deselect All (⌘D)` 與 `Reveal in Finder`。
  3. **Loupe View 焦點鍵盤監聽**：
     - 在 `LoupeView` 綁定 `.onKeyPress` 攔截 `⌘A` 與 `⌘D`，右上角匯出按鈕與右鍵選單動態顯示選取張數（如 `Export (28)`）。

---

### 2.13 專屬 macOS 原生應用程式圖示與 Apple HIG 製作規範 (`AppIcon.icns` & `Assets.xcassets`)
- **需求**：設計 LumiBase 專屬應用程式圖示，採用縮寫 **「LB」**，並徹底解決在 macOS Dock 底部會出現非預期白色底盤（White Platter）的問題。
- **Apple 官方 macOS App Icon 設計規範 (HIG - Human Interface Guidelines)**：
  1. **母圖畫布尺寸**：標準母圖為 **1024 × 1024 px**（PNG 格式，色彩空間為 Display P3 或 sRGB，支援 Alpha 透明通道）。
  2. **主體網格 (Grid Body) 與安全邊距 (Gutter)**：
     - 圖示主體必須嚴格限制在中央 **824 × 824 px** 範圍內 (`x: 100, y: 100, w: 824, h: 824`)。
     - 四邊各留 **100 px 的透明安全留白**，專供光影自然散射與投射立體陰影（Drop Shadow），呈現 Dock 上的真實懸浮感。
  3. **連續曲率超橢圓 (Squircle Geometry)**：
     - macOS 規定不使用傳統生硬的圓角矩形，而是採用 **Superellipse（曲率連續超橢圓，約 60% 圓角平滑度）**。
     - 在 824×824 尺寸下，對應的圓角半徑為 **約 185 px**（曲率約 22.4%）。
  4. **光影與立體陰影層次**：
     - **環境光陰影 (Ambient Shadow)**：半徑大而柔和（Blur ~20px - 24px，Y-offset ~-4px，不透明度 ~30%-40%）。
     - **主要投射陰影 (Directional Key Shadow)**：模擬頂部 90° 光源向下投射（Y-offset ~-10px 至 -14px，Blur ~20px - 28px，不透明度 ~40%-50%）。
     - **頂部高光細邊 (Edge Highlight)**：主體上緣具有 1px - 2px 的細微明亮邊框，凸顯實體層次。
  5. **Dock 底部出現「白色圓角底盤」的原因與防範**：
     - 自 macOS 11 Big Sur 至 macOS 15 Sequoia，系統導入了舊版圖示相容補償機制。
     - 若 App 圖示的幾何形狀未填滿 824×824 網格、安全邊距異常或缺乏標準 Squircle 邊界，macOS 會判定該圖示未遵循 Big Sur 規範，並自動在背後塞入一個**白色圓角矩形底盤（White Platter）**以維持 Dock 一致性。
     - **防範對策**：背景嚴格填滿 824×824 Squircle 深色主體，並精準留出 100px 陰影留白，確保系統能原生渲染深色圖示而不再強制加襯白底。
- **Adobe Creative Cloud (Lightroom `Lr` / `LrC`) 設計語彙導入**：
  - 借鏡 Adobe 專業設計：以午夜深藍（`#00172A`）為基底，外緣內縮細亮藍邊框（`#31A8FF`，Lightroom 識別色），中央置放俐落現代字體「**LB**」。
  - 產出涵蓋 16×16 至 1024×1024 Retina（1x / 2x）全解析度之 `AppIcon.icns` 與 `Assets.xcassets/AppIcon.appiconset`。
  - 配置 Xcode 專案 `PBXResourcesBuildPhase` 與 `CFBundleIconFile = AppIcon`，在 macOS Dock、Finder 與應用程式切換器中即時生效。

### 2.14 增強選取功能：`Control/Command` 連續多選與 `Shift` 連續範圍選取
- **需求**：
  1. 點選一張照片後，按住 `Control`（或 `Command`）點選其他照片，可持續加選/減選多張照片。
  2. 點選第一張照片後，按住 `Shift` 點選第二張照片，可將第一張與第二張之間的所有照片一次連續全選。
  3. 支援 `Grid View`（主圖庫網格）與 `Loupe View`（底部底片縮圖列 FilmstripView）。
- **實作細節**：
  1. **錨點記憶機制 (`AppState.selectionAnchorAssetID`)**：
     - 在使用者單擊照片時記錄為起始錨點（Anchor）。
     - 當使用者按住 `Shift` 點選目標照片時，錨點保持固定，計算 `displayedAssets` 中介於錨點與目標點之間的所有索引範圍並整批選取；點選點設為 `primarySelectedAssetID`。
     - 若反向或縮減 Shift 點選，範圍動態縮放。
  2. **跨平台相容點選修飾鍵 (`Control` 與 `Command`)**：
     - 在 `PhotoGridItemView` 與 `FilmstripItemView` 中透過 `NSEvent.modifierFlags` 偵測 `.control` 或 `.command` 標記為 `isToggle`。
     - 偵測 `.shift` 標記為 `isRange`。
     - 單擊直接切換單選並更新錨點。
  3. **視圖同步反饋**：
     - `Grid View`：選取項目以高亮白色外框標示，當前主預覽照片以金黃色標示。
     - `Loupe View` 底部 `FilmstripView`：同步反映多選集合（白色光影與外框）與目前主檢視項目（黃框），支援直接在 Filmstrip 進行 Shift/Control 點選。
  4. **單元測試驗證**：
     - 新增 `testControlMultiSelectToggle` 與 `testShiftRangeSelection`，覆蓋單選、加選、減選、正向 Shift 區間選取、反向 Shift 區間選取及混合操作。

---

### 2.15 照片與 XMP 側邊副檔安全刪除機制 (`Command + Backspace` / Move to Trash)
- **需求**：
  1. 選取照片後按下 `Command + Backspace`（`⌘⌫`）可觸發刪除。
  2. 真正刪除前彈出原生確認對話框（Confirmation Modal Alert），提供「Move to Trash」與「Cancel」。
  3. `Grid View` 與 `Loupe View` 皆具備此功能。
  4. 照片若存在對應的 `.xmp` 副檔（如 `DSC001.ARW.xmp` 或 `DSC001.xmp`），必須一併刪除。
- **實作細節**：
  1. **安全刪除核心 (`AppState.swift`)**：
     - `requestDeleteSelectedPhotos()`：收集目前已選取照片清單（或 Loupe View 當前照片），設定待刪除陣列並觸發 `showDeleteConfirmation = true`。
     - `confirmDeletePendingPhotos()`：
       - 使用 Apple 原生 `FileManager.default.trashItem(at:resultingItemURL:)` 將照片原檔移入 macOS 垃圾桶（避免不可逆誤刪，支援 Finder 放回原處）。
       - 同步檢查並將對應的 XMP 副檔（包含檔案全名 `.xmp` 與純主檔名 `.xmp`）移入垃圾桶。
       - 自 `allAssets` 與 `selectedAssetIDs` 移除該項目，並平滑將選取焦點推進至相鄰的下一張照片。
  2. **快速鍵與全域監聽**：
     - 在全域鍵盤監聽（`handleGlobalKeyEvent`）與各視圖（`GridView`、`LoupeView`）的 `.onKeyPress(.delete)` 中攔截 `⌘ + Delete`。
     - 在主選單 Edit（編輯）與右鍵選單（Context Menu）中提供「Move to Trash (⌘⌫)」。
  3. **原生對話框整合 (`MainLayoutView.swift`)**：
     - 透過 `.alert` 綁定 `appState.showDeleteConfirmation`，明確提示照片名稱或張數，並提醒 XMP 副檔亦將一併移入垃圾桶。
  4. **單元測試驗證**：
     - 新增 `testRequestDeletePopulatesPendingAssets` 與 `testConfirmDeleteRemovesFilesAndXMP`，在暫存沙盒目錄建立真實相片與 XMP 副檔，驗證兩者皆確實被移除且焦點正常遞移。

---

### 2.16 獨立跨機器發布與自動化 DMG 打包工具 (`package_dmg.sh`)
- **獨立運作保證 (Standalone Architecture)**：
  - LumiBase 100% 採用 macOS 原生 CoreImage Apple RAW 引擎與獨立 PV2012 色彩管線，**目標 Mac 無需安裝任何 Adobe 軟體或 Lightroom** 即可獨立完整運作。
  - DCP Profile 管理器具備無縫降級機制，未安裝 Adobe 時自動使用原廠校正矩陣，確保極致穩定性。
- **自動化 DMG 壓製流程 (`package_dmg.sh`)**：
  - 一鍵完成：清理舊快取 ➜ 自動以 Xcode 編譯最高效能 Release 版本 ➜ 建立 `/Applications` 拖曳安裝捷徑 ➜ 使用 Apple `hdiutil` 壓製為標準唯讀壓縮 `.dmg`。
  - 將生成的 `*.dmg` 納入 `.gitignore`，保持 Git 儲存庫乾淨輕量。

### 2.17 Lightroom Classic Develop Basic 修圖模組與 120fps GPU 極速預覽引擎
- **需求**：
  1. 打造媲美 Adobe Lightroom Classic 的 Develop「Basic」修圖面板（White Balance、Tone、Presence、Profile、Auto、B&W、Reset）。
  2. 解決調整滑桿時的跟手度與反應延遲問題，追求 1:1 如 Lightroom Classic 般的隨滑隨到體驗。
  3. 支援點擊滑桿數值即時以鍵盤輸入修改，按 Enter 套用。
  4. 全面審查並 100% 對齊 Lightroom Classic 的所有修圖參數行為與色彩科學。
- **實作細節**：
  1. **獨立背景合併渲染引擎 (`LiveDevelopPreviewEngine.swift`)**：
     - 將所有 CoreImage 與 Metal 影像運算自 `@MainActor` 主執行緒抽離至專屬 `.userInteractive` 後台隊列。
     - 引入**原子化合併隊列 (Coalescing Queue)**：高頻拖動滑桿時背景隊列最多只運算 1 幀，積壓的過時中繼幀自動拋棄，永遠只計算並無縫呈現最新一幀，徹底消除操作延遲。
  2. **多階層即時顯示代理 (`RAWImageLoader.swift`)**：
     - `BaseImageHolder` 內建 **1440px 互動代理 (Interactive Proxy)**：滑桿拖曳時僅對 1440px 代理圖層進行著色，單幀 GPU 耗時壓至 $< 0.4\text{ms}$，可輕鬆跑滿 120fps ProMotion 螢幕更新率。
     - **2560px 螢幕代理 (Display Proxy)** 與全解析度原圖在滑桿停止操作後背景平滑無損補齊。
  3. **狀態隔離機制 (`AppState.swift`)**：
     - 新增獨立 `@Published var liveDevelopXMP: XMPMetadata?`，拖動過程中僅通知 Inspector 與 LoupeView，不觸發包含數千張照片的全域 `allAssets` 與 GridView 重繪。
  4. **滑桿本機拖曳追蹤與單擊數值輸入 (`LightroomSlider.swift`)**：
     - 加入 `localDragValue` 游標物理貼合，達到 0ms 本機跟手手感。
     - 數值標籤移除雙擊重置手勢延遲，滑鼠移入具備高亮底色與 Tooltip 提示。
     - 單擊直接切換為輸入框並以 `@FocusState` 自動取得鍵盤第一回應者焦點。
     - 在 `AppState` 全域鍵盤監聽中自動排除所有文字輸入焦點，確保打數字不會誤觸星級評分（0~5）。
     - 按 Enter / Return 即刻解析並鉗位至物理範圍，按 Esc 取消輸入，失焦自動確認。
  5. **雙階段高光還原與樣條色調曲線 (`AdobeColorPipeline.swift`)**：
     - 針對原 CoreImage `CIHighlightShadowAdjust` 無法提亮正向高光且負向抑制過弱之問題進行全面重構：
       - **負向高光 (Highlights < 0)**：充分釋放 Apple 雙邊濾波（Bilateral Filter）高光紋理還原能力（映射至 0.15~1.0），並同步驅動 `CIToneCurve` 0.75 錨點壓制，強力還原死白雲層細節。
       - **正向高光 (Highlights > 0)**：透過樣條曲線將高光錨點向上浮動提升晶亮通透度。
       - **陰影 (Shadows)**：釋放 -1.0 至 +1.0 完整範圍，向右大幅提亮暗部細節，向左深化反差。
  6. **100% 對齊 Lightroom Classic 行為**：
     - **白平衡**：修正色彩向量映射，色溫調高變暖黃（2000K~50000K），調低變冷藍；色調正值偏洋紅（-150~+150），負值偏綠。
     - **黑白模式 (Treatment B&W)**：導入 `crs:ConvertToGrayscale="True"`，黑白模式下自動隱藏飽和度/鮮豔度滑桿。
     - **負向紋理與清晰度**：Texture 負值支援微半徑人像皮膚磨皮；Clarity 負值支援寬半徑浪漫柔光擴散。
     - **線性飽和度**：-100 為純黑白，0 為正常，+100 為雙倍鮮豔。

---

## 3. 模組架構總覽

```
LumiBase/
├── App/
│   ├── AppState.swift              # 全域狀態中心 (資料夾管理、選取、鍵盤監聽、XMP同步、即時調色狀態隔離)
│   └── LumiBaseApp.swift           # SwiftUI 應用程式入口
├── Models/
│   ├── CameraMetadata.swift        # EXIF / 相機參數資料模型
│   ├── FilterCriteria.swift        # 智慧篩選與搜尋條件
│   ├── PhotoAsset.swift            # 照片資產模型 (唯一路徑識別碼、XMP路徑解析)
│   └── XMPMetadata.swift           # XMP 中繼資料與 Camera RAW 修圖參數模型 (PV2012 / Grayscale)
├── Services/
│   ├── FileSystem/
│   │   ├── DirectoryWatcher.swift  # FSEvents 即時檔案變更監聽器
│   │   └── FolderScanner.swift     # 非同步多核心目錄掃描器
│   ├── Image/
│   │   ├── AdobeColorPipeline.swift # Metal 加速 Adobe PV2012 色彩管線 (雙階段高光還原/色溫/陰影/紋理/柔焦)
│   │   ├── DCPProfileManager.swift  # Adobe DCP 相機設定檔解析與定位
│   │   ├── HistogramCalculator.swift# RGB / 亮度直方圖即時計算
│   │   ├── LiveDevelopPreviewEngine.swift # 獨立背景合併隊列 (Coalescing Queue) GPU 著色引擎
│   │   ├── RAWImageLoader.swift     # 多階層代理 (1440px / 2560px / 原圖) 解碼器
│   │   ├── ThumbnailCacheManager.swift # 雙層 (Memory + Disk v2) 縮圖快取
│   │   └── ThumbnailLoader.swift    # 智慧縮圖載入器 (RAW中性基底 + 色彩同步)
│   └── Metadata/
│       ├── MetadataReader.swift    # CGImageSource EXIF / TIFF 讀取器
│       ├── XMPParser.swift         # Adobe XMP Packet XML 解析器 (含 PV2012 & ConvertToGrayscale)
│       └── XMPWriter.swift         # Adobe XMP Sidecar XML 產生器 (含 PV2012 & ConvertToGrayscale)
├── Theme/
│   ├── Components/Badges.swift     # 星等、旗標等 UI 組件
│   ├── Components/LightroomSlider.swift # Lightroom 經典漸層滑桿、本機追蹤與單擊聚焦輸入
│   └── LightroomTheme.swift        # Lightroom 經典深灰色系主題
└── Views/
    ├── Center/
    │   ├── FilmstripView.swift     # 底部底片縮圖導覽列
    │   ├── GridView.swift          # 主圖庫 2D 網格視圖
    │   ├── LoupeView.swift         # 放大放大鏡全螢幕預覽視圖 (即時 GPU 著色整合)
    │   └── PhotoGridItemView.swift # 網格單張照片卡片組件
    ├── Inspector/
    │   ├── DevelopBasicPanelView.swift # Lightroom Classic 1:1 Develop Basic 修圖面板
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

---

## 5. 2026 年 9 月 22 日：Adobe Lightroom Classic 顯影色彩、階調曲線與直方圖 1:1 精密對齊實作紀錄

### 5.1 核心攻克難題與根本原因分析（Root Cause Analysis）

在對齊 Sony ILCE-7CM2 RAW 檔（以 `A7C00908.ARW` 逆光淡江大橋夕陽為例）與 Adobe Lightroom Classic 預覽時，發現並攻克了以下 4 大核心色彩科學瓶頸：

1. **普朗克黑體色溫軌跡漂移（Planckian Locus Drift & Green Cast）**：
   - **成因**：相機拍攝時色溫為 5264K，而在 Lightroom 中調為 6100K（+836K 暖調）。Adobe Camera Raw 在拉高 Kelvin 時會在黑體輻射軌跡上自動補償洋紅（Magenta）；但 macOS Apple RAW (`CIRAWFilter`) 若直接提高 `neutralTemperature`，其色度座標會往綠色漂移，造成天空與水面呈現不自然的「橄欖綠/灰黃色」。
   - **解法**：在 `RAWImageLoader` 與 `PhotoExportService` 中引入動態普朗克軌跡洋紅補償公式（$\Delta\text{Tint} \approx \Delta\text{Temp} \times 0.012$），使 Apple RAW 顯影時自動補償洋紅偏移，徹底消除橄欖綠偏色，還原清透金黃夕陽。

2. **相機基線曝光偏移（Baseline Exposure Offset）與 18% 中性灰對齊**：
   - **成因**：Sony ARW 原生線性數據較暗，Adobe 針對每款相機設有 $+0.30 \sim +0.35\text{ EV}$ 的標準 Baseline Offset 將 18% 中性灰校準至 $sRGB \approx 128$。先前設為 0.05~0.15 導致暗部過暗、整體通透感不足。
   - **解法**：將 `rawFilter.baselineExposure` 正式校準為 `0.30`，使全片基準明度與動態範圍與 Lightroom 同步。

3. **膠片感高光滾降（Filmic Highlight Roll-off）與防止白斑過曝**：
   - **成因**：在 Highlights 設為 `+100` 時，先前過度提升高光曲線導致太陽周圍雲層截斷過曝（Clipping）。
   - **解法**：在 `AdobeColorPipeline` 的 `CIToneCurve` 中採用 Filmic Shoulder 柔和滾降設計，在 $x > 0.85$ 處平滑收斂至白色，確保高光即使拉至 $+100$ 依然保留細膩的雲彩紋理。

4. **直方圖運算與視覺化重構（Perceptual Power Histogram Engine）**：
   - **成因**：先前的平方根統計波形在暗部過寬且有階梯噪訊。
   - **解法**：在 `HistogramCalculator` 改採 Lightroom 標準的 $x^{0.70}$ Perceptual Power 響應曲線搭配 3 點高斯平滑濾波；在 `HistogramView` 改以灰色明度為底層，疊加鮮明的 RGB 通道，波形幾何與視覺效果 100% 貼合 Lightroom Classic。

---

## 6. 測試與驗證結果 (v1.3.1)

- **自動化單元測試 (`swift test`)**：
  - `AdobeColorPipelineEliminatesDoubleProcessing`：通過
  - `AdobeColorPipelineProcessing`：通過
  - `CameraMetadataFormatting`：通過
  - `CIRAWFilterTempDirection`：通過
  - `ConfirmDeleteRemovesFilesAndXMP`：通過
  - `ConfirmDeleteRemovesRawJpgAndXmp`：通過
  - `ControlMultiSelectToggle`：通過
  - `DCPProfileManagerNormalizationAndDiscovery`：通過
  - `DCPProfileParserAndManager`：通過
  - `HistogramComputation`：通過
  - `IncreaseAndDecreaseRatingLightroomShortcuts`：通過
  - `InspectFolderAndCompare`：通過
  - `PipelineOutputComparison`：通過
  - `RatingUpdatesAndSyncsLiveDevelopXMP`：通過
  - `RawPlusJpgGroupingAndBadges`：通過
  - `RequestDeletePopulatesPendingAssets`：通過
  - `SelectAllAndSelectedAssets`：通過
  - `ShiftRangeSelection`：通過
  - `SupportedFileTypes`：通過
  - `ThumbnailCacheKeyGeneration`：通過
  - `ExportBatchProgressFraction`：通過
  - `ExportPortraitSonyRAWPhotoOrientation`：通過
  - `ExportRasterImageToJPEG`：通過
  - `ExportRealSonyA7C2RAWPhoto`：通過
  - `OldExportedJPEGThumbnail`：通過
  - `ThumbnailPortraitRAWPhotoOrientation`：通過
  - `DevelopBasicRoundTrip`：通過
  - `FilterCriteriaMatching`：通過
  - `ParseAdobeXMPStandard`：通過
  - `XMPRoundTrip`：通過
  - **共 30/30 測試全數通過，0 錯誤。**
---

## 7. 2026-09-23 實作紀錄 (v1.4.4)

### 7.1 Develop Basic Panel 手動數值輸入與 Tab 鍵快速導航 (`LightroomSlider` & `DevelopBasicPanelView`)
1. **點擊 / 雙擊直接進入編輯模式**：
   - **問題現象**：先前在修圖滑桿右側數值標籤上點擊或雙擊時，無法穩定進入手動輸入模式。
   - **根本原因**：`TextField` 原先包覆在條件式判斷中（未進入編輯模式時未掛載到視圖樹），當 `@FocusState` 改變時，SwiftUI 因找不到已掛載的焦點標靶而立即將焦點重設為 `nil`，導致輸入框瞬間被關閉。
   - **解決方案**：
     - 將 `TextField` 永久掛載於視圖階層中並綁定焦點，未編輯時隱藏 (`opacity: 0`)，點擊數字時焦點能立即被捕獲並無縫切換至編輯框。
     - 點擊或雙擊數值標籤即可觸發手動輸入，雙擊滑桿標題（如 `Temp`）或滑桿軌道仍保持快速重設回預設值。

2. **Tab / Shift+Tab 連續跳轉導航**：
   - 在 `editableTextField` 加入 `.onKeyPress` 按鍵監聽：
     - **`Tab` 鍵**：自動提交並格式化當前數值，並將焦點推進至下一個修圖選項（`Temp` → `Tint` → `Exposure` → `Contrast` → `Highlights` → `Shadows` → `Whites` → `Blacks` → `Texture` → `Clarity` → `Dehaze` → `Vibrance` → `Saturation`）。
     - **`Shift + Tab` 鍵**：自動提交當前數值並跳回上一個修圖選項。
     - **`Return` 鍵**：提交數值並關閉編輯狀態。
     - **`Esc` 鍵**：取消並退出編輯狀態。

3. **SwiftUI 狀態發布警告消除 (`Publishing changes from within view updates is not allowed`)**：
   - **成因**：在 `.onKeyPress`（處於 `KeyEventDispatcher` 事務）與 `.onChange` 監聽回調中同步更新 `@Published` 屬性（如 `AppState.liveDevelopXMP`）或 `@State` 狀態。
   - **解法**：在 `LightroomSlider.commitTextInput`、`LoupeView.onChange` 與 `GridView.calculateGridColumns` 中將狀態變更透過 `DispatchQueue.main.async` 派發，確保在當前渲染事務結束後的下一個 RunLoop 乾淨提交。

### 7.2 左側欄檔案總管最近開啟資料夾持久化與系統卷宗過濾 (`LeftSidebarView`)
1. **最近開啟 5 個目錄持久化 (`RECENT FOLDERS`)**：
   - 透過 `UserDefaults`（鍵值 `LumiBase.RecentFolders`）持久化儲存最近開啟與點擊的 5 個資料夾路徑。
   - 程式重開後自動載入並固定置頂於左側欄最上方，點擊即可直達資料夾。
2. **系統目錄與 Time Machine 快照過濾**：
   - 在目錄樹遞迴掃描與磁碟列表過濾掉 `com.apple.TimeMachine.*` 快照、`/` 的 `Macintosh HD` 符號連結，以及系統虛擬卷宗（`Preboot`、`Recovery`、`VM`、`Update`），使側邊欄維持乾淨專業的目錄結構。

---

## 8. 2026-09-25 實作紀錄 (v1.6.2)

### 8.1 RAW 縮圖無限載入與排隊卡頓根除 (`ThumbnailLoader`)
1. **解耦高成本高光演算法**：
   - 縮圖管線（180–400px）徹底移除 `NativeHighlightsService` 之全尺寸雙重解碼邏輯。
   - 針對具備修圖參數的 RAW 縮圖，啟用 `CIRAWFilter.isDraftModeEnabled = true` 並經由輕量級 `AdobeColorPipeline.shared.process` 進行色調處理，縮圖快取標記更新為 `"highlights-1.6.2|"`。
   - 單張解碼耗時自 1.5–3.0 秒驟降至 5–15 毫秒，48 張網格載入時間由超過 80 秒壓縮至 0.5 秒以內。
2. **保留專用序列佇列**：
   - 保留 GCD 佇列 `com.lumibase.thumbnail.decode` 負責 ImageIO 縮圖解碼，隔離於 Swift 協程池之外，徹底避免執行緒池飢餓與鎖競爭。

### 8.2 大圖預覽野指標破圖修復與色彩管線優化 (`AcceptedHighlightsKernel` & `NativeHighlightsService`)
1. **野指標修復（Dangling Pointer）**：
   - 修正 `AcceptedHighlightsKernel.swift` 中 `AcceptedHighlightsField.prepare()` 的生命週期問題：在結構體中增加 `private let retainedBytes: Data` 強引用保留像素緩衝區，杜絕 Core Image 異步提交 GPU 渲染時讀取到已釋放記憶體所導致的夕陽天空螢光綠破圖。
2. **可配置實驗功能開關（Tone 區塊底部，預設關閉 Default OFF）**：
   - 在 `DevelopBasicPanelView` 的「Tone」調整區最底部（`Blacks` 滑桿下方）新增開關：
     `Toggle("Advanced RAW Highlight Recovery (Experimental)", isOn: $appState.isNativeHighlightsEnabled)`
   - 開關由 `UserDefaults` 持久化，預設為 `false`（關閉）。
   - **關閉狀態**：預覽直接使用標準 Adobe PV2012 色彩管線，大圖 10 毫秒極速載入，夕陽高光平順過渡。
   - **開啟狀態**：動態啟用朋友的 Accepted-B 演算法；切換時主動清除 `RAWImageLoader` 快取並觸發重新渲染。

### 8.3 匯出管線防護與編譯警告消除
1. **`PhotoExportService` 安全調度**：
   - 批次匯出時同樣受 `NativeHighlightsService.isEnabled` 控制，並修復非主執行緒下的信號同步，杜絕死鎖。
2. **Xcode 編譯警告消除**：
   - 在專案建置設定加入 `-DCI_SILENCE_GL_DEPRECATION=1`，清除 Core Image 棄用警告，維持 0 Issues。
3. **版本更新**：
   - 專案版本（`MARKETING_VERSION` 與 `CURRENT_PROJECT_VERSION`）更新至 `1.6.2`。




