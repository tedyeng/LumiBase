# LumiBase 照片預覽與 Lightroom 視覺對齊實作計畫書
(Lightroom Preview Matching Implementation Plan)

**專案名稱**：LumiBase (macOS Native DAM & RAW Processing)  
**文件路徑**：`docs/lightroom-preview-matching-plan.md`  
**版本**：v1.0.0  
**日期**：2026 年 9 月 22 日  
**目標**：消除 LumiBase (LB) 與 Adobe Lightroom (LR) 在 Basic（基本）面板相同參數下的預覽差異，解決「二度疊加」問題，建立高精度對齊 Adobe PV2012 的 RAW 解算與色調曲線管線，並提供與 LR Library 一致的相機原生預覽體驗。

---

## 1. 現狀問題深入剖析 (Root Cause Analysis)

目前在 LB 中設定與 LR 相同的 Basic 參數，預覽看起來差異明顯，核心原因為**解碼流程中的「二度疊加」與「管線順序錯誤」**：

```
【目前現況的錯誤管線】
RAW 檔案
   │
   ▼
[Apple CIRAWFilter 解碼] ────► 預設強制套用 Apple Auto WB
                              預設強制套用 Apple Boost (+1.0 對比與飽和)
                              （影像已是非線性且已被色彩校正）
   │
   ▼
[AdobeColorPipeline 濾鏡] ──► 二度套用 CITemperatureAndTint（嚴重重複偏色！）
                              二度套用 CIExposureAdjust（非線性亮度拉伸）
                              二度套用 CIToneCurve（高光死白、暗部死黑）
```

### 具體三大落差點：
1. **白平衡二度偏移 (Double White Balance)**：
   - 相機 RAW 拍攝時有原生色溫（如 5200K）。
   - Apple `CIRAWFilter` 在解碼時，預設會依 EXIF 自動把畫面校正到中性灰。
   - 隨後 `AdobeColorPipeline` 又讀取 XMP 裡的 `5200K`，透過 `CITemperatureAndTint` 再次做色溫位移，導致照片重複泛黃或色調怪異。
2. **曝光補償時機錯誤 (Post-Demosaic Exposure)**：
   - Lightroom 的 EV 曝光調整是在去馬賽克前或線性傳輸階段進行，具有完整的感光寬容度。
   - LB 目前是在已輸出非線性 sRGB/Display P3 的影像上做 post-filter `CIExposureAdjust`，極易造成高光溢出與色階斷裂。
3. **Apple 預設對比曲線干擾 (Apple Boost vs Adobe Curve)**：
   - Apple RAW 引擎預設帶有 `BoostAmount = 1.0`（強化對比）。
   - LB 隨後又疊加了 Adobe PV2012 曲線，造成對比過重、色彩過度飽和。

---

## 2. 解決方案架構 (Solution Architecture)

```
【改進後的標準對齊管線】
RAW 檔案
   │
   ├─► [無 Basic 調整時] ────────► 相機高品質內嵌預覽 (Embedded Preview)
   │                             （100% 呈現相機機身風格，0 延遲，與 LR Library 一致）
   │
   └─► [有 Basic 調整 / 即時修圖]
          │
          ▼
       [CIRAWFilter 原生層級解算]
          ├─► kCIInputEVKey = XMP.Exposure2012 (直接在線性 RAW 增益)
          ├─► kCIInputNeutralTemperatureKey = XMP.Temperature
          ├─► kCIInputNeutralTintKey = XMP.Tint
          └─► kCIInputBoostAmountKey = 0.0 (關閉 Apple 對比，還原中性基底)
          │
          ▼
       [AdobeColorPipeline (校準後 PV2012 渲染)]
          ├─► 移除重複的 CITemperatureAndTint
          ├─► Adobe PV2012 5-Point Spline Tone Curve (以中性基底映射)
          ├─► Local Tone Mapping (Highlights 局部平滑壓制 / Shadows 陰影提亮)
          ├─► Whites / Blacks 極值拉伸
          └─► 膚色保護自然飽和度 (Vibrance) & 紋理 (Texture)
          │
          ▼
       輸出與 Lightroom 高度一致的精準畫面 (Metal 120fps)
```

---

## 3. 分階段實作細節

### 階段一：RAW 原生直通解碼與二度疊加消除 (`RAWImageLoader.swift`)

1. **改造 `RAWImageLoader.loadBaseHolder`**：
   - 當解算 RAW 檔案時，不再只用無參數的 `CIRAWFilter(imageURL: url)`。
   - 傳入當前的 `XMPMetadata`（若有）：
     - `rawFilter.setValue(xmp.exposure2012 ?? 0.0, forKey: kCIInputEVKey)`
     - 若 XMP 含有色溫：
       - `rawFilter.setValue(xmp.temperature, forKey: kCIInputNeutralTemperatureKey)`
       - `rawFilter.setValue(xmp.tint, forKey: kCIInputNeutralTintKey)`
     - 關閉 Apple 內建過度飽和曲線：
       - `rawFilter.setValue(0.0, forKey: kCIInputBoostAmountKey)`
     - 設定色彩空間為廣色域線性空間：
       - `rawFilter.setValue(CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3), forKey: kCIInputColorSpaceKey)`

2. **多階代理快取機制升級**：
   - 由於 RAW 重新解碼消耗約 100~200ms，拖曳滑桿時仍須維持 120fps。
   - 維持雙層策略：
     - **拖曳中 (Dragging)**：由 Metal GPU 著色器對快取 baseHolder 進行 0.5ms 即時色調曲線運算。
     - **放開滑桿 (Mouse Up / Commit)**：以最新 EV/色溫觸發 RAW 解碼器背景刷新高精度底層影像。

---

### 階段二：AdobeColorPipeline 校準 (`AdobeColorPipeline.swift`)

1. **移除重複濾鏡**：
   - 既然白平衡與線性曝光已在 `CIRAWFilter` 完成，在 `AdobeColorPipeline` 中：
     - 僅在非 RAW 格式（如 JPG/TIFF）或二次微調時才調用 `CITemperatureAndTint`。
     - 避免對 RAW 檔執行二次白平衡偏移。

2. **校準 PV2012 色調曲線 (Tone Curve Spline)**：
   - Lightroom PV2012 的預設曲線具有特定的趾部 (Toe) 與肩部 (Shoulder) 壓縮：
     ```swift
     // 對齊 Adobe Standard 階調映射
     let p0Y = max(0.0, min(0.20, (Double(blacks) / 100.0 * 0.06)))
     let p1Y = max(0.12, min(0.38, 0.25 + (Double(sh) / 100.0 * 0.05) + (Double(blacks) / 100.0 * 0.03)))
     let p2Y = 0.50
     let p3Y = max(0.62, min(0.88, 0.75 + (Double(hl) / 100.0 * 0.08) + (Double(whites) / 100.0 * 0.04)))
     let p4Y = max(0.82, min(1.0, 1.0 + (Double(whites) / 100.0 * 0.06)))
     ```
3. **優化高光還原與陰影提升 (Highlights & Shadows)**：
   - 使用雙邊濾鏡（Bilateral Tone Mapping）保留微對比，避免死白區域出現灰色階斷。

---

### 階段三：相機原生內嵌預覽無縫切換 (`Embedded Preview`)

1. **未調色狀態 (Zero-Edits)**：
   - 直接讀取 RAW 檔中的 4096px 全尺寸機身內嵌 JPEG（Embedded Preview）。
   - 優點：**0 延遲瞬間載入**，且與 Lightroom Library 視圖、相機螢幕看到的機身發色 100% 相同。
2. **調色狀態 (Develop Active)**：
   - 一旦偵測到該照片有 Develop 調整（`hasDevelopEdits == true`）或使用者拉動滑桿，無縫淡入 GPU 解算管線。

---

## 4. 預期效益與對照

| 評估項目 | 目前 LumiBase | 改進後 LumiBase | Adobe Lightroom |
| :--- | :--- | :--- | :--- |
| **初始色溫/色彩** | 嚴重重複偏移（偏黃/偏紫） | 與相機原色/LR 一致 | Adobe Standard / 机身色彩 |
| **曝光與高光寬容度** | Post-filter 易過曝死白 | 線性 RAW 層級 EV，高光自然過渡 | 線性 Raw 寬容度 |
| **暗部與對比** | Apple Boost 疊加，暗部過重 | 中性基底 + PV2012 曲線，階調柔順 | PV2012 標準階調 |
| **未修圖時載入速度** | 需完整解 RAW (~150ms) | 機身內嵌即時預覽 (~10ms) | 即時快取預覽 |
| **滑桿反應效能** | 120fps GPU | 維持 120fps GPU | 60~120fps |

---

## 5. 變更檔案清單

1. `LumiBase/Services/Image/RAWImageLoader.swift`：
   - 支援傳入 XMP 參數至 `CIRAWFilter`。
   - 支援無調色時優先載入高品質內嵌預覽。
2. `LumiBase/Services/Image/AdobeColorPipeline.swift`：
   - 修正二度白平衡與曝光疊加問題。
   - 校準 PV2012 曲線節點數學模型。
3. `LumiBase/App/AppState.swift`：
   - 當拖曳結束 (Mouse Up) 確定數值後，驅動底層 RAW 刷新。
4. `Tests/LumiBaseTests/`：
   - 新增 RAW 參數解碼直通與曲線校準單元測試。

---

## 6. 驗證與測試計畫

### 6.1 自動化測試
- 執行 `swift test` 確保所有 25+ 項既有單元測試（XMP 讀寫、RAW+JPG 分組、快捷鍵）持續通過。
- 新增測試驗證 `AdobeColorPipeline` 在中性參數下的輸出不發生色偏。

### 6.2 實際比對測試
- 使用實機拍攝之 Sony ARW 檔案：
  - 在 Lightroom 設定：曝光 `+1.0`、高光 `-40`、陰影 `+30`、色溫 `5500K`。
  - 在 LumiBase 設定完全相同參數。
  - 擷圖進行直方圖比對與肉眼階調比對，確認色調、反差與色彩高度契合。
