# Inspection 1.6.0 — 原生 accepted-B Highlights

## 成品與範圍

- 本文件記錄已交付的 `LumiBase-Inspection-1.6.0-Highlights.app`，不是可下載 binary release；由下方步驟重新建置。
- Bundle ID：`com.lumibase.LumiBase.Inspection.ROI`；版本／build：`1.6.0`；arm64；ad-hoc 簽章驗證通過。
- 可執行檔 SHA-256：`84e251c756c900a2268eee4b14c9b8af381550c0933d5c1208a6ed7210b343a4`
- 以實際 macOS 26.6.2／Apple M5 Pro（16-core GPU，Metal 4）執行 Core Image GPU rendering。Swift SDK Release build 與實際 kernel compilation/render 都已執行，不是 Python production subprocess，也不是只有 CPU prototype。
- 自動驗證未啟動 GUI、未修改原始照片／sidecar／catalog／使用者偏好，舊 apps 未覆寫。使用者已接受多張照片的 Highlights 視覺結果；這不是系統性 camera/scene validation，也不能把以下 raster timings 當成 GUI latency。
- 依賴 ROI 1.5.5（upstream PR #2，基底 commit `afcee2c`）。本次新增內容僅為 Highlights 1.6.0、測試與文件；另一個 RAW loading/infinite-spinner 問題及其 GCD queue fix 不在本次範圍。不要把本 PR 視為已解決 loading hang。

## 實作

新增 `AcceptedHighlightsKernel.swift`：完整 native pixel stages 由 Core Image color kernel 執行。legacy endpoints 經 sRGB16 quantization／display-linear decode 後才進入 accepted-B 算法；不是把 RAW scene-linear 或 EDR÷4 誤當 endpoint。使用仍受 SDK 支援、但已 deprecated 的 CI kernel-language API，實際 GPU render 已驗證；未宣称新的 Metal shading-language source/metallib。

全域 field 由兩個獨立 Boost1 RAW graph 準備：RAW EV0 與 RAW EV−2，baselineExposure .30、相同 WB/tint，legacy Highlights−80 各一次。96-row full-width band raster 僅為精確擷取全圖 top-left `[::4,::4]`；CPU filter 僅作用於 quarter grid，size97 half-sample reflect 的兩階段 guided filter，epsilon .25²，再 resize **low-grid result**，不是 high-resolution guide reconstruction。保留全域 phase，ROI 不會重新建 local field。float CPU 與 GPU 會有可量測 rounding residual，而非宣稱 bit-exact B。

新增 `NativeHighlightsService.swift`：單一 prepared entry、單一序列 preparation lock、短 state lock、immutable source recipe／CI graph、完整 develop identity、source size/mtime/inode guard、cancellation 與 cache generation guard。replacement preparation 前釋放 cache 舊 graph；不保存多個 full holders。prepared image 包含兩個 lazy RAW endpoints 與 quarter field，不保留 native full float raster。128MP resource guard；超過此上限會拒絕 preparation，沒有偷偷改用 proxy。Core Image 的內部資源池與 active consumers 不等同於這個 entry limit。

Fit/native ROI/full 經 `RAWImageLoader`，export、edited RAW thumbnail 與 histogram 都接到 native service；histogram preparation 移至 detached task。RAW holder 只新增 immutable source ownership。既有 ROI1.5.5 geometry、handoff、processed-bitmap ownership／budget 沒有重設或改寫。主執行緒不能執行這個同步 preparation；actual app callers 在 off-main render 路徑，exportBatch 也使用可取消 detached work。

所有 develop values（含 exposure/WB/tint、Highlights/Shadows、Whites/Blacks、contrast/dehaze、vibrance/saturation、clarity/texture、profile/grayscale/crop）與 camera/source identity 都在 key 中。**目前任何 key 改變都重新準備 global field，包括 Highlights slider 本身。** warm timings 不代表拖曳改值也只花數毫秒。

## Strength policy／保留行為

- `H >= 0`：完全走原有 rendering pipeline；不進入 native Highlights service。
- JPEG／不具可驗證 native RAW recipe 的 holder：保留原有 path，不假稱具有雙 RAW recovery endpoints。
- `H < 0`：`s = -clamp(H, -100, 0) / 80`。
- `Z` = 相同其餘設定、legacy H0，轉為 display-linear 並 clamp 到 display gamut。
- `B` = 相同其餘設定、固定 legacy H−80 endpoints 得到 accepted-B。
- 結果為 `clamp(Z + s * (B - Z), 0, 1)`；H−80 直接使用 B，避免多餘 interpolation。
- 因此 H−1：1.25%；H−40：50%；H−80：100%；H−100：125% linear extrapolation，最後 gamut clamp。這是清楚定義的 app strength policy，不是 Adobe slider calibration。Shadows 控制實作不變；它仍參與 legacy endpoints，不能將全圖受 Highlights 影響誤述為所有 shadow pixels 絕對不變。

### Exposure domain 的必要區分

negative path 保留既有 viewer 的 EV0 RAW base + `CIExposureAdjust(target-base)` exposure domain。暗 endpoint 的 RAW−2 attenuation 是 recipe 固有 attenuation，兩個 reference holder metadata EV 均為0，不讓 delta stage 抵消−2；XMP exposure 仍實際作用於兩端的 downstream pipeline。這使 preview H0→−1 在 EV±1 仍连续，accepted-B H−80 anchor 不變。最終修正以 `NeutralDomain.preview / .nativeRAWExport` 區分 H0 neutral endpoint，並納入 cache key：preview 保持原 post-decode EV；export 使用與 legacy H0 相同的 native RAW EV holder。故非零 EV、H≠−80 的 preview/export negative interpolation 不再宣稱逐像素相等；兩者各自連續收斂到自己的 H0。

另行修復既有 export defect：legacy nonnegative RAW export 原本僅寫 `baseExposure = ev`、未寫 `rawFilter.exposure`；現在真的設定 RAW exposure，metadata 記錄相同值，不再取消未套用的 EV。**不要宣稱非零 Exposure 下，legacy nonnegative preview 與 export 的 tone 已逐像素相等**：前者保留原有 post-decode CI EV，後者按此 defect fix 使用 native RAW EV；Boost1 時兩域不等價。這個跨域 legacy 差異未藉由改動 H0/positive preview 來掩蓋。EV0 下本次的 preview/export parity 已實測。

## 測試與 RED 證據

- PR 包裝在獨立 worktree 重跑：基底 `afcee2c` **96 tests／3 skipped／0 failures**；本版（fixture/output path 改為 environment-configurable 後）**109 tests／5 skipped／0 failures**，opt-in integrated benchmark **1 test／0 failures**，Xcode Release build 成功。production kernel/math 未改；排除另一項 hang investigation 的 test、queue 與 1.6.1 version bump。
- 最終完整 Release Swift suite：**109 tests，5 skipped，0 failures**；`full-suite-continuity-final.log`。
- 舊 baseline 為96 tests／3 skips；新增兩個 opt-in harness 是額外 skips，不是遺漏原有測試。
- 單獨啟用 actual integrated benchmark：**1 test，0 failures**；含 full/ROI、0/+40 full-byte identity、strength、實際 JPEG export。
- isolated saved-TIFF GPU harness 另行執行，並非把其預設 skip 當作 parity 通過。
- 實際 pre-integration native face/hands 與 B 的 regression：12 個數值 assertions 失敗，`integration-red.log`，之後轉綠。
- export 專用 regression 曾在受限工具環境先因 Metal access 失敗，那不是正確 RED；另以 HEAD production source 重跑實際 EV0/+1 pixel assertion，確實失敗（`export-real-red.log`），修正後 pass。這個 specific-regression 的 HEAD replay 是回溯驗證；更早 checkpoint 有真正 production export assertion RED，不混稱所有步驟都是 chronological TDD。
- 新增 EV±1 H0→−1 continuity regression，先實際失敗（max約.24–.25），修正 endpoint EV domain 後 pass；`nonzero-ev-continuity.log` / `nonzero-ev-continuity-green.log`。
- nonzero full-extent translation regression 先失敗（max.0494771），修正 quarter field 的 origin translation 後 pass；`translation-red.log` 與最終 suite。
- settings-complete key／實際 source replacement、取消不發布、main-thread preparation refusal、strength anchors 均有 assertions。新增 domain cache 實際切換測試：preview hit、export replacement、返回 preview reprepare，單一 entry；EV+1 的 H−80 兩域 sample pixels 完全一致。此 cache test 是 fix 後新增，不冒稱 test-first RED。
- production actual JPEG EV+1 H0→−1 regression 先失敗：mean `.06539855`、max `.22417581`；窄移植 scratch NeutralDomain 修正後 mean **`.0066027227`**、max **`.035409033`**，mean<.02 assertion 通過；`export-continuity-live-red.log` / `export-continuity-live-green.log`。未改 accepted kernel、H0/positive 或 ROI geometry。

## 實際 DNG parity

來源：私人 acceptance DNG，唯讀；照片及 reference arrays 不隨 repository 分發。以 `LUMIBASE_HIGHLIGHTS_DNG` 指定其位置，不需重建作者的磁碟路徑。

前後 SHA-256：`653cd8bf060b5295f0b8bd4c74d2b87d8155612fd9cd13e63e9f2501a5ade1a1`。

固定 WB3650/tint8、EV0、H−80，其餘原 checkpoint 設定；8192×5464。以下比較是 **actual integrated RAW source graph** 到 preserved `B_OrangeSoft.npy`，非僅重放 saved TIFF。

| Region | max absolute linear RGB | mean absolute linear RGB |
|---|---:|---:|
| Full（134,283,264 RGB samples） | 0.0000789464 | 0.0000001720 |
| Face | 0.0000789464 | 0.0000004948 |
| Hands | 0.0000789464 | 0.0000006758 |

- Native full vs separate ROI renders：face、hands、image edge **max float difference 0**。
- H0 與 +40：整張 RGBA8 與同設定 legacy graph **byte-identical**。
- H−40 interpolation max residual `2.98e-8`；H−1 與 display H0 sample ROI 最大差約`.00692`；另已驗證 EV±1 的 H0→−1 continuity。
- JPEG quality1 actual export vs native preview face 平均 linear RGB error 約`.00134`，包含 JPEG quantization/chroma effects，不能宣稱 JPEG bit-exact。
- face/hands native comparison 與 quarter-scale full-frame comparison 已視覺檢查，沒有明顯 color/detail/geometry mismatch；數值 residual 如上，不以肉眼等同證明數值相等。
- 已校準這一張 supplied DNG；沒有據此宣稱各相機／所有場景具有普遍審美優勢。

## 成本：最終獨立序列實測

Release integrated path、同一 mounted DNG、forced RGBA8 sRGB raster、provider page read。三個 serial trials，每個 trial 清除 prepared entry，先記錄 prepare，再各 mode 一次 first + 三次 warm；每個 mode 共9次 warm。GPU worker 已退出才執行最終 lean benchmark。未清 OS disk cache，因此不是冷磁碟結果。first ROI/full 已共享該 trial 前面 Fit 的 graph/resource warming。

Global preparation（含 endpoint construction、band raster/RAW work、quarter CPU filter，不宣稱各子階段完全分離）：1030.09／1020.63／1043.51 ms，median **1030.09 ms**。

| Mode | first median（3 trials） | warm median（9 repeats） |
|---|---:|---:|
| Fit1440 | 27.22 ms | 3.77 ms |
| Fit2560 | 33.80 ms | 9.56 ms |
| native face ROI1016×858 | 4.05 ms | 2.99 ms |
| full8192×5464 | 120.44 ms | 121.39 ms |

以上 render 欄 **不包含**另列約1.03秒 preparation；首次／設定改變須加上 preparation。warm 也包含 prepared lookup、source guard、NSImage/CGImage materialization 與 provider page read，非純 shader instruction time。沒有用 checkpoint 的舊 native timings 冒充本版成本，也沒有做不匹配條件的 CPU/GPU speedup 倍數宣稱。

最終 direct-xctest lean run：prepared entries1，preparations3，hits48；process max RSS **1,283,981,312 bytes**，`/usr/bin/time` peak memory footprint **2,120,517,216 bytes**。兩個系統欄位是不同 accounting，不能相減推論 GPU allocation。完整 parity/strength/export harness max RSS4,704,124,928 bytes，包含 full float array、Data copies、reference context，不是 app resident-memory limit；其 `swift test` wrapper footprint 不代表子程序，故不引用。實際單次 H−80 JPEG export 1382.35ms（含 domain cache miss 的 preparation1227.69ms）；此單次非三次 export benchmark。最終表取 `lean-direct-continuity-final.log` 的3 serial trials，無其他 highlights GPU worker 同時執行。

## Reviewer build／測試步驟

需 macOS、Xcode/Swift toolchain 及可使用 Metal 的登入環境。已驗證環境為 macOS 26.6.2／Apple M5 Pro；package deployment target 為 macOS 14，但不能把本次驗證當成所有 OS/GPU 的相容性證明。CI kernel-language API 仍可用但已 deprecated。

在 checkout 根目錄執行，scratch 可改成任何可寫位置：

```sh
export SCRATCH="$HOME/Library/Caches/LumiBase-highlights-review"
mkdir -p "$SCRATCH/tmp" "$SCRATCH/modules" "$SCRATCH/home" "$SCRATCH/artifacts"
export TMPDIR="$SCRATCH/tmp/"
export CLANG_MODULE_CACHE_PATH="$SCRATCH/modules"
export SWIFTPM_MODULECACHE_OVERRIDE="$SCRATCH/modules"
export CFFIXED_USER_HOME="$SCRATCH/home"
export LUMIBASE_TEST_OUTPUT="$SCRATCH/artifacts"
swift test -c release --disable-sandbox --scratch-path "$SCRATCH/build"
xcodebuild -project LumiBase.xcodeproj -scheme LumiBase -configuration Release \
  -derivedDataPath "$SCRATCH/xcode" CODE_SIGNING_ALLOWED=NO build
```

以上不需私人 DNG 即可執行 synthetic kernel／extent／ROI／cache-key 測試；缺少 fixture 的 tests 與 opt-in harness 會明確 skip，**skip 不是 parity pass**。原有測試仍可能引用本地 legacy fixtures；未取得它們時 skip 數會增加。使用隔離 home/output，不需要啟動 GUI 或修改原始檔／sidecar。

### 實際 RAW regression 與 benchmark

```sh
# 私下取得已授權的 acceptance fixture；不要提交照片或 sidecar。
export LUMIBASE_HIGHLIGHTS_DNG="/absolute/path/to/accepted-highlights.dng"
shasum -a 256 "$LUMIBASE_HIGHLIGHTS_DNG"
swift test -c release --disable-sandbox --scratch-path "$SCRATCH/build"
LUMIBASE_HIGHLIGHTS_BENCHMARK=1 swift test -c release --disable-sandbox \
  --scratch-path "$SCRATCH/build" --filter HighlightsNativeBenchmarkTests
# 僅測量 preparation + 3 serial trials，不產生 full-float parity dump：
LUMIBASE_HIGHLIGHTS_BENCHMARK=1 LUMIBASE_HIGHLIGHTS_TIMING_ONLY=1 \
  swift test -c release --disable-sandbox --scratch-path "$SCRATCH/build" \
  --filter HighlightsNativeBenchmarkTests
```

Fixture SHA-256 必須對應上方值；測試固定 WB3650/tint8、8192×5464 的座標與 acceptance samples。不能替換成任意 DNG 後仍宣稱相同 parity；測其他照片需另定 ROI/oracle。full-float harness 需要數 GB RAM 和至少約 1 GB 可寫磁碟。請序列執行 GPU benchmarks，避免同時跑其他 rendering jobs。

Outputs 在 `$LUMIBASE_TEST_OUTPUT/highlights-integrated-results/`：
`integrated-timings-parity.json`、`integrated-Hminus80.jpg`、`integrated-full-linear-rgba.f32`（top-down RGBA float32）、`integrated-lean-timings.json`。Harness 檢查 full/ROI parity、strength、H0/+40 legacy byte identity、JPEG export。完整 preserved-B array comparison 的上方數值是原先私有 oracle 的歷史結果；該 array 未分發，僅靠 checkout 不能重現那個 full-frame B comparison。

Saved-TIFF kernel-only harness 可另設 `HIGHLIGHTS_BASELINE_TIFF`、`HIGHLIGHTS_TARGET_TIFF`、`HIGHLIGHTS_NATIVE_RAW`（output path），執行 `--filter AcceptedHighlightsKernelTests/testScratchActualEndpointParityHarness`。兩個 TIFF 必須是相同 legacy endpoints；它不包含實際 RAW decode，不能拿其成本代替 app benchmark。

上文 log 名稱是原驗證的 evidence labels，不是 reviewer 必須取得的私人路徑。重新執行時請保存 stdout/stderr；Metal access error 是執行環境問題，不是有效 algorithm RED。已交付 app 的 SHA-256 只識別當時 binary，不保證不同 toolchain/build path 會產生相同 binary。
