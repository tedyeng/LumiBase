# LumiBase P0 & P1 Develop 增強規格與實作計畫書
> **借鏡 rawmakase 色彩工程：自動影調、自動白平衡、自適應對比度、色調曲線與 HSL 混色器**

---

## 1. 概述與目標 (Overview & Goals)

本計畫旨在將從 `rawmakase` 逆向工程與色彩科學中所提煉之精華，完整導入 **LumiBase**，使 LumiBase 在保有 macOS / Apple Silicon 原生極致流暢度（Metal 120fps）的同時，在色彩演算法與修圖維度上達到 1:1 媲美 Adobe Lightroom Classic (PV2012 / PV15.4) 的專業水準。

### 階段劃分 (Phasing)

- **P0（立即可用之核心智慧功能）**：
  1. **真實 Auto Tone（自動影調）估計引擎**：替換原先硬編碼的固定參數，改採基於畫面亮度百分位數之線性迴歸模型。
  2. **真實 Auto White Balance（自動白平衡）估計引擎**：灰度世界演算法疊加 Adobe $+23\text{ mired}$ 與 $-3\text{ Tint}$ 校正矩陣。
- **P1（影調精緻度與核心調色面板擴充）**：
  1. **自適應對比度支點 (Adaptive Contrast Pivot) 與暗部腳部補償 (Black Point Toe)**：消除陰影與高動態場景下與 ACR 的細微偏差。
  2. **色調曲線模組 (Tone Curve Panel)**：RGB Master 與 R/G/B 三原色點曲線（Point Curve），支援互動畫布、樣條插值與標準預設。
  3. **色彩混色器模組 (Color Mixer / HSL Panel)**：8 色相（紅、橙、黃、綠、淺綠/青、藍、紫、洋紅）之色相、飽和度、明度微調。
  4. **批次修圖同步 (Develop Sync) 與 XMP 雙向持久化**：支援標準 Adobe XMP 標籤讀寫與同步對話框勾選。

---

## 2. 演算法與數學規格 (Mathematical Formulations)

### 2.1 Auto Tone（自動影調預測模型）

在 1024px 基準未調色影像（As-Shot，已套用基礎相機描述檔與光學校正，未經 Tone 滑桿）上提取直方圖特徵：
- $L_q$：顯示編碼亮度（Luminance）的第 $q$ 百分位數（如 $L_{40}$ 為第 40% 亮度分位數，$L_1$ 為第 1% 最暗部）。
- $P_q$：RGB 三通道最大值（Peak Channel）的第 $q$ 百分位數。
- $C_q$：彩色純度（Chroma，計算公式為 $(P - \min(R,G,B))/P$）的第 $q$ 百分位數。

各滑桿計算公式：
$$
\begin{aligned}
\text{Exposure (EV)} &= \text{clamp}(2.22 - 2.13 L_{40} - 1.52 L_{99}, -5.0, 5.0) \\
\text{Highlights} &= \text{clamp}(-36.0 - 51.9 L_{90} + 26.9 P_{25}, -100.0, 0.0) \\
\text{Shadows} &= \text{clamp}(54.4 - 41.5 P_{10}, 0.0, 100.0) \\
\text{Whites} &= \text{clamp}(67.5 - 52.2 P_{99.8}, -100.0, 100.0) \\
\text{Blacks} &= \text{clamp}(-38.0 - 1.86 \log_2(\max(10^{-4}, \text{sRGB\_Decode}(L_1))), -100.0, 0.0) \\
\text{Saturation} &= \text{clamp}(2.07 - 10.2 C_{35}, -100.0, 100.0) \\
\text{Contrast} &= +6.0 \\
\text{Vibrance} &= +15.0
\end{aligned}
$$

### 2.2 Auto White Balance（自動白平衡預測模型）

1. **有效取樣 (Valid Sampling)**：採樣畫面內排除高光過曝（$\max(R,G,B) > 0.98$）與雜訊暗部（$\max(R,G,B) < 0.02$）的像素。
2. **灰度世界 (Gray World)**：
   $$\bar{R} = \frac{1}{N} \sum R_i, \quad \bar{G} = \frac{1}{N} \sum G_i, \quad \bar{B} = \frac{1}{N} \sum B_i$$
3. **換算色溫與色調 (Planckian Conversion)**：以 Daylight (5500K) 為基準，依通道比值求得初步溫度 $T_{\text{est}}$ 與色調 $\text{Tint}_{\text{est}}$。
4. **Adobe 偏移修正**：
   $$\text{Mired} = \left(\frac{10^6}{T_{\text{est}}} - 23.0\right)$$
   $$T_{\text{final}} = \text{clamp}\left(\frac{10^6}{\text{Mired}}, 2850\text{K}, 7500\text{K}\right)$$
   $$\text{Tint}_{\text{final}} = \text{clamp}(\text{Tint}_{\text{est}} - 3, 0, 30)$$

### 2.3 自適應對比度支點 (Adaptive Contrast Pivot) 與暗部腳部補償 (Black Point Toe)

1. **對比度支點**：
   $$\text{Pivot} = \text{clamp}(0.577 + 0.568 \times \text{MeanLuma} - 0.689 \times \text{MiddleLuma}, 0.35, 0.65)$$
   取代原本固定的 $0.5$ 灰度旋轉軸心。
2. **暗部腳部補償**：
   在曝光增益後引入二次方滾降補償：
   $$\Delta_{\text{black}} = 0.0015 \times 2^{\text{Exposure}}$$
   使極暗部深黑與 ACR 基準線吻合。

### 2.4 Tone Curve (色調曲線) 規格

- **Point Curve**：
  - 支援 RGB Master、Red、Green、Blue 獨立點陣列。
  - 每個點由歸一化座標 $(x, y) \in [0, 1] \times [0, 1]$ 表示（XMP 中對應 $0 \sim 255$）。
  - 自然三次樣條曲線（Natural Cubic Spline）計算，以確保平滑連續。
  - 標準預設點：
    - Linear: `[(0,0), (255,255)]`
    - Medium Contrast: `[(0,0), (32,22), (64,56), (128,128), (192,196), (255,255)]`
    - Strong Contrast: `[(0,0), (32,16), (64,50), (128,128), (192,202), (255,255)]`
- **XMP 標籤相容**：
  - `crs:ToneCurvePV2012`
  - `crs:ToneCurvePV2012Red`
  - `crs:ToneCurvePV2012Green`
  - `crs:ToneCurvePV2012Blue`

### 2.5 HSL Color Mixer (色彩混色器) 規格

- **8 色區間定義**：
  - Red: $345^\circ \sim 15^\circ$
  - Orange: $15^\circ \sim 45^\circ$
  - Yellow: $45^\circ \sim 75^\circ$
  - Green: $75^\circ \sim 150^\circ$
  - Aqua: $150^\circ \sim 195^\circ$
  - Blue: $195^\circ \sim 255^\circ$
  - Purple: $255^\circ \sim 285^\circ$
  - Magenta: $285^\circ \sim 345^\circ$
- **各通道控制**：
  - Hue: $-100 \sim +100$
  - Saturation: $-100 \sim +100$
  - Luminance: $-100 \sim +100$
- **XMP 標籤相容**：
  - `crs:HueAdjustmentRed`, `crs:HueAdjustmentOrange`, ...
  - `crs:SaturationAdjustmentRed`, `crs:SaturationAdjustmentOrange`, ...
  - `crs:LuminanceAdjustmentRed`, `crs:LuminanceAdjustmentOrange`, ...

---

## 3. 架構設計與模組規劃 (Architecture)

```
LumiBase/
├── Models/
│   ├── XMPMetadata.swift              # 擴充 ToneCurve 與 HSL 欄位與序列化
│   ├── ToneCurveData.swift           # 點曲線資料結構與三次樣條插值計算
│   ├── HSLAdjustments.swift          # 8 色相 HSL 資料結構
│   └── DevelopSyncOptions.swift      # 擴充 Tone Curve 與 HSL 批次同步勾選
├── Services/
│   ├── Image/
│   │   ├── AutoToneService.swift      # [NEW] P0: 直方圖統計與 Auto Tone / Auto WB 估算
│   │   ├── ColorMixerKernel.swift     # [NEW] P1: HSL 8 色相 Metal / CIColorKernel 著色器
│   │   ├── AdobeColorPipeline.swift   # 整合 Adaptive Contrast、Black Toe、Tone Curve 與 HSL
│   │   └── OpticalExposureKernel.swift
│   └── Metadata/
│       ├── XMPParser.swift            # 解析 ToneCurve 與 HSL 標籤
│       └── XMPWriter.swift            # 寫入 ToneCurve 與 HSL 標籤
├── Views/
│   └── Inspector/
│       ├── ToneCurvePanelView.swift   # [NEW] P1: 互動式色調曲線畫布面板
│       ├── ColorMixerPanelView.swift  # [NEW] P1: 8 色相 HSL 分頁調整面板
│       ├── DevelopBasicPanelView.swift# 整合真實 Auto Tone / Auto WB 按鈕
│       └── RightInspectorView.swift   # 組織面板佈局折疊項
```

---

## 4. 實作驗證步驟 (Verification & Quality Gates)

1. **單元測試 (Unit Tests)**：
   - 驗證 `AutoToneService` 在典型高光、剪影、人像、風景測試圖上的預測數值符合夾止範圍與預期趨勢。
   - 驗證 `ToneCurveData` 三次樣條插值曲線在單調遞增與 S 曲線情況下之連續性與邊界值。
   - 驗證 `XMPParser` 與 `XMPWriter` 針對 `ToneCurvePV2012` 與 `HueAdjustment*` 能夠 100% Round-trip 無損讀寫。
2. **渲染與效能驗證**：
   - 驗證 `ColorMixerKernel` 在 Metal/CoreImage 下耗時 $< 0.5\text{ms}$，無卡頓流暢套用。
   - 驗證 120fps 滑桿手感與 Before/After 分割視圖的一致性。
