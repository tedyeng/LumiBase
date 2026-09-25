# Lightroom Crop & Rotate 裁切與旋轉校正功能實作計畫書

**專案名稱**：LumiBase (macOS Native DAM & RAW Processing)  
**文件版本**：v1.0.0  
**日期**：2026 年 9 月 25 日  
**目標**：在 LumiBase 中實作 1:1 媲美 Adobe Lightroom Classic 的 **Crop & Rotate（裁切與水平旋轉校正，快捷鍵 `R`）** 互動工具，包含畫面上可拖曳的 8 個控制錨點、三分法則九宮格參考線、常見比例選單、直橫向切換（`X` 鍵）、雙向 Adobe `.xmp` 標準中繼資料儲存，以及 GPU 60fps 即時裁切預覽與高畫質 JPEG 匯出。

---

## 1. 架構總覽 (Architecture Overview)

```
┌─────────────────────────────────────────────────────────────────────────────────┐
│                     LumiBase Crop & Rotate 模組架構                             │
├─────────────────────────────────────────────────────────────────────────────────┤
│                                                                                 │
│   ┌─────────────────────────────────────────────────────────────────────────┐   │
│   │                        LoupeView (大圖預覽區)                           │   │
│   │                                                                         │   │
│   │   ┌─────────────────────────────────────────────────────────────────┐   │   │
│   │   │                      CropOverlayView                            │   │   │
│   │   │                                                                 │   │   │
│   │   │   ⌜───────────────────── 8 個控制錨點 ─────────────────────⌝   │   │   │
│   │   │   │ ┌─────────┬─────────┬─────────┐                         │   │   │   │
│   │   │   │ │         │ 三分法則│         │                         │   │   │   │
│   │   │   │ ├─────────┼─────────┼─────────┤  ◄── 拖曳邊框/錨點即時調整 │   │   │   │
│   │   │   │ │         │ 輔助格線│         │                         │   │   │   │
│   │   │   │ ├─────────┼─────────┼─────────┤                         │   │   │   │
│   │   │   │ │         │         │         │                         │   │   │   │
│   │   │   │ └─────────┴─────────┴─────────┘                         │   │   │   │
│   │   │   ⌞─────────────────────────────────────────────────────────⌟   │   │   │
│   │   │                                                                 │   │   │
│   │   │   旋轉控制：滑鼠於裁切框外圍拖曳 ──► 即時計算角度 (Angle)        │   │   │
│   │   └─────────────────────────────────────────────────────────────────┘   │   │
│   └────────────────────────────────────┬────────────────────────────────────┘   │
│                                        │                                        │
│                                        ▼ 歸一化座標 (0.0 ~ 1.0)                 │
├─────────────────────────────────────────────────────────────────────────────────┤
│                          狀態與資料模型 (State & Model)                          │
│                                                                                 │
│   CropSettings (Top, Left, Bottom, Right, Angle, AspectRatio, IsLocked)         │
│                                        │                                        │
├────────────────────────────────────────┼────────────────────────────────────────┤
│                   ▼                    │                   ▼                    │
│      AdobeColorPipeline (GPU 渲染)      │        XMPWriter (Sidecar 儲存)        │
│                                        │                                        │
│   1. 旋轉變換 (Rotate Transform)        │   crs:HasCrop="true"                   │
│   2. 邊界裁切 (Normalized Crop Rect)   │   crs:CropTop="0.125"                  │
│   3. 實時 60fps 輸出至 MTKView         │   crs:CropLeft="0.100"                 │
│                                        │   crs:CropBottom="0.875"               │
│                                        │   crs:CropRight="0.900"                │
│                                        │   crs:CropAngle="-1.5"                 │
└────────────────────────────────────────┴────────────────────────────────────────┘
```

---

## 2. 核心功能規格 (Core Functional Specifications)

### 2.1 互動裁切疊層 (`CropOverlayView`)
1. **8 個控制手柄 (Handles)**：
   - 4 個角落手柄：自由/依比例縮放裁切區域。
   - 4 個邊緣手柄：單向拉伸上/下/左/右邊界。
2. **自適應輔助格線系統 (Tool Overlay Guides)**：
   - **多線水平對齊格線 (Alignment Grid)**：與 Lightroom Classic 完全一致，根據目前 App 視窗大小及裁切框尺寸（約每 32pt 一格）動態計算並繪製細緻的水平／垂直校正格線。視窗放大時自動增加格線條數，提供精準的地平線與垂直結構校準。
   - **三分法則 (Rule of Thirds)**：標準 $3 \times 3$ 黃金分割輔助線。
   - **快速循環切換 (`O` 快捷鍵)**：隨時按下鍵盤 `O` 鍵或右側面板的 Tool Overlay 按鈕即可在對齊格線與三分構圖線之間即時切換。
   - 拖曳裁切框或調整角度滑桿時，格線自動強化對比顯示（透明度 $65\%$），靜止時維持清爽（透明度 $35\%$）。
3. **裁切框外暗角遮罩 (Dimmed Overlay Mask)**：
   - 裁切框外部區域以 $60\%$ 半透明黑底遮罩覆蓋，讓使用者專注於裁切後的構圖。
4. **直橫向快速翻轉 (`X` 快捷鍵)**：
   - 按下鍵盤 `X` 鍵，瞬間將當前裁切框在橫向（Landscape）與直向（Portrait）之間翻轉，並維持鎖定的長寬比例。

---

### 2.2 水平旋轉校正 (Straighten & Rotation)
1. **角度滑桿 (Straighten Slider)**：
   - 範圍：$-45.0^\circ \sim +45.0^\circ$，步進 $0.1^\circ$。
   - 具備中心點 $0^\circ$ 雙擊復位。
2. **框外滑鼠手勢旋轉**：
   - 當游標移動至裁切框四角外側時，自動變更為雙向彎曲箭頭指標（`rotate.left` / `rotate.right`），按住拖曳即可直覺旋轉畫面。
3. **自動限制邊界 (Auto Constrain to Crop)**：
   - 旋轉時自動內縮裁切框，確保裁切視角內不會出現透明或黑色畫布留白邊緣。

---

### 2.3 長寬比例系統 (Aspect Ratio Presets)

支援與 Lightroom Classic 完全相同的長寬比選單與鎖定功能：

| 比例名稱 (Preset) | 比例數值 (Ratio) | 常見使用情境 |
| :--- | :--- | :--- |
| **Original (原始比例)** | $3:2$ (或感光元件原尺寸) | 預設保留相機原始感光元件比例 |
| **1 : 1 (正方形)** | $1.0$ | Instagram 貼文、正方形頭像 |
| **4 : 5 / 8 : 10** | $0.8$ 或 $1.25$ | 經典人像、商業相簿印刷 |
| **5 : 7** | $0.714$ 或 $1.4$ | 標準相片沖印 |
| **16 : 9** | $1.778$ 或 $0.5625$ | 螢幕桌布、YouTube 影片縮圖 |
| **Custom (自訂)** | 自由比例 | 解除比例鎖定（點擊鎖頭圖示），自由拉伸任意長寬比 |

---

### 2.4 快捷鍵與互動操作 (Keyboard Shortcuts Matrix)

| 功能 (Action) | 快捷鍵 | 說明 |
| :--- | :--- | :--- |
| **進入 / 退出裁切模式** | `R` | 切換裁切工具列與互動裁切框 |
| **直橫向翻轉裁切比例** | `X` | 快速切換裁切框的長寬比例方向（直向 $\leftrightarrow$ 橫向） |
| **循環切換輔助格線樣式** | `O` | 切換多線水平對齊格線 (Alignment Grid) 與三分法則 (Rule of Thirds) |
| **確認並套用裁切** | `Enter` / `Return` / `Space` | 完成裁切，退出裁切工具並儲存 |
| **取消裁切編輯** | `Esc` | 放棄本次裁切調整並退出 |
| **復位裁切 (Reset Crop)** | `Cmd + Option + R` | 清除裁切與旋轉，恢復全圖視野 |

---

## 3. Adobe XMP 規範相容性 (Metadata Compatibility)

Lightroom 採用**歸一化浮點數（Normalized Coordinates, 0.0 ~ 1.0）**來儲存裁切座標，原點 $(0, 0)$ 為照片左上角，右下角為 $(1.0, 1.0)$。

### 3.1 XMP 標籤定義
```xml
<crs:HasCrop>true</crs:HasCrop>
<crs:CropTop>0.120000</crs:CropTop>
<crs:CropLeft>0.150000</crs:CropLeft>
<crs:CropBottom>0.880000</crs:CropBottom>
<crs:CropRight>0.850000</crs:CropRight>
<crs:CropAngle>-1.850000</crs:CropAngle>
<crs:CropConstrainToWarp>1</crs:CropConstrainToWarp>
```

### 3.2 座標轉換數學式
若原始影像解析度為 $W \times H$，則實際像素矩形為：
$$\text{PixelRect} = \left( \text{CropLeft} \times W,\; \text{CropTop} \times H,\; (\text{CropRight} - \text{CropLeft}) \times W,\; (\text{CropBottom} - \text{CropTop}) \times H \right)$$

---

## 4. 模組實作計畫 (Implementation Roadmap)

### 階段一：資料模型與 XMP 解析擴充
1. 在 `XMPMetadata.swift` 中加入裁切欄位：
   - `cropTop: Double?`
   - `cropLeft: Double?`
   - `cropBottom: Double?`
   - `cropRight: Double?`
   - `cropAngle: Double?`
   - `hasCrop: Bool`
2. 擴充 `XMPParser.swift` 與 `XMPWriter.swift`，確保雙向讀寫 Adobe 標準 `crs:Crop*` 標籤。
3. 擴充 `DevelopSyncOptions.swift`，支援將精確裁切範圍與角度納入批次同步。

### 階段二：GPU 渲染管線整合 (`AdobeColorPipeline` & `LiveDevelopPreviewEngine`)
1. 在 `AdobeColorPipeline.process()` 中新增裁切階段：
   - 依據 `cropAngle` 執行 `CGAffineTransform(rotationAngle:)` 旋轉變換。
   - 依據歸一化座標執行 `CIImage.cropped(to:)` 與邊界修正。
2. 支援大圖（Loupe）、縮圖（Grid & Filmstrip）即時呈現裁切後的成果。

### 階段三：互動裁切疊層與比例控制器 (`CropOverlayView.swift`)
1. 建立 `CropOverlayView.swift`，使用 SwiftUI 幾何讀取器（`GeometryReader`）精確換算螢幕點與影像歸一化座標。
2. 實作 8 點拖曳手勢（`DragGesture`）與長寬比鎖定幾何演算法。
3. 實作九宮格三分輔助線與暗角遮罩。
4. 支援 `X` 鍵快速翻轉長寬比例。

### 階段四：右側檢視面板與工具列整合
1. 在 `DevelopBasicPanelView.swift` 頂部新增 **Crop & Rotate 工具按鈕**（標示快捷鍵 `R`）。
2. 開啟時展開比例選單（`Original`, `1:1`, `4:5`, `16:9`, `Custom`）、鎖頭開關、角度滑桿與 Done / Reset 按鈕。
3. 全域鍵盤事件攔截 `R` 鍵與 `X` 鍵。

### 階段五：匯出管線與單元測試
1. 在 `PhotoExportService.swift` 匯出全尺寸 JPEG 時，完整套用旋轉與像素級裁切。
2. 編寫 `CropAndRotateTests.swift` 單元測試：
   - 測試 XMP 裁切數值 Round-Trip 序列化。
   - 測試長寬比計算與旋轉內縮限制。
   - 測試批次同步裁切設定。

---

## 5. 預期成果與驗收標準 (Deliverables)

- [x] 按下 `R` 鍵能無縫在 LoupeView 叫出裁切框，並支援多線對齊格線與九宮格輔助線切換（`O` 鍵）。
- [x] 根據視窗大小（Window Size）自適應動態調整輔助格線數量與間距，完美匹配 Lightroom Classic 視覺體驗。
- [x] 拖曳角落與邊緣能平順即時變更裁切範圍，支援鎖定長寬比例（`Original`, `1:1`, `4:5`, `5:7`, `16:9`, `Custom`）。
- [x] 按下 `X` 鍵能瞬間旋轉裁切方向（直式／橫式）。
- [x] 旋轉角度滑桿具備 120 FPS GPU 直驅即時預覽，滑動順暢不卡頓。
- [x] 按下 `Enter` 或 `R` 退出後，照片以裁切後構圖呈現，縮圖同步更新。
- [x] 生成的 `.xmp` 側邊檔案可在 Adobe Lightroom Classic 中直接辨識並還原完全一致的裁切框。
- [x] JPEG 匯出檔完全符合裁切後之解析度與比例。
