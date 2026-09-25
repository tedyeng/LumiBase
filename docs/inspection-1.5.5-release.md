# LumiBase Inspection ROI 1.5.5：交付與審查摘要

## 交付狀態與範圍

使用者已實際操作 `LumiBase-Inspection-1.5.5-ROI.app`，確認 ROI「正常了」。這是使用者的 GUI 驗收回報，不是自動化 GUI 測試，也不代表所有相機、照片或資料夾負載均已驗證。

本次整理並交付既有 1.5.1–1.5.5 ROI／顯示／快取／資料夾生命週期修正，不再修改產品程式碼或重建 Release。版本及 build 保持 **1.5.5**；bundle ID 保持 `com.lumibase.LumiBase.Inspection.ROI`。獨立的高光／RAW-detail 實驗、scratch、app 與 build 產物均不納入。

分支 `feature/bounded-inspection-preload` 以既有 `03033d6`（1.5.0）及 `e936858`（合入 upstream main）為基礎。因此對 upstream `main` 的完整 PR 也包含先前尚未合入的 bounded preload／ROI 基礎、測試及研究文件；本次新 commit 則集中在後續修正與交付文件。不重寫歷史、不強制推送、不直接合併朋友的 repo。

## 最終行為

- **有限預載**：一般 preview 預載目前篩選／排序清單的前後各最多 3 張，依移動方向排序；native ROI 由目前照片的前景工作處理，再推測預載相鄰 ±1 張。ROI 背景 worker 同時最多一個，前景優先、取消及 generation 檢查保留。這是工作視窗，不是最終共享快取最多只能保留三筆。
- **單一 ready-frame store**：預載 preview、完成的 Fit render 與處理後 ROI 共用 immutable `CGImage` store，合計 **128 MiB LRU 像素 byte budget**。記憶體壓力清除消費端可見資料；這不限制總 RSS、GPU、RAW holder、暫存 render allocation 或其他 thumbnail cache。
- **同步首幀交接**：Loupe 只讀記憶體中的符合照片 owner、完整設定及來源版本的 frame；native ROI 另核對相機、orientation、中心、viewport、backing scale 與 source rect。冷啟動仍可能顯示 loading，不保證每次零黑幀或零延遲。
- **同照片修改不閃回舊照片**：等待新設定時可保留同張照片最後有效畫面，明確標示 updating；不能把舊設定標成最新，也不能跨 owner 借用。已修改 RAW 的 thumbnail 處理失敗時，不再回退成未修改的內嵌 JPEG。
- **非同步設定與 owner**：cache await 後核對 publication state；延遲 XMP observer 執行時取目前設定；保留 selection/render generation、foreground owner 完成與 holder warmup 檢查，拒絕過時回傳。
- **100% 幾何**：400／1600 px proxy 的像素尺寸與原圖 oriented extent 分開。等待 native 時以原圖 extent 定義比例及中心，避免換成 native 時突然縮放。來源尺寸未知則暫用 Fit，不假裝 proxy 尺寸就是 native。cached ROI 與 holder extent 不一致時重新要求 native render。
- **資料夾切換**：quick scan 移出 main actor；AppState 持有可取消工作與 generation，拒收舊 A/B/A 掃描及 refresh；full scan 最多四個 metadata 工作並行，security-scope 存取生命週期成對管理。

## 版本沿革

| 版本 | 重點 | 原始調查／測試紀錄 |
| --- | --- | --- |
| 1.5.0 | bounded preview 與 processed ROI 基礎、owner 隔離 | [ROI cache checkpoint](inspection-1.5.0-roi-cache.md) |
| 1.5.1 | await 後的舊 develop 設定拒收、deferred observer 取最新值 | [develop race](inspection-1.5.1-develop-race.md) |
| 1.5.2 | warm thumbnail handoff、完整 develop cache key／v4 namespace | [handoff](inspection-1.5.2-handoff.md) |
| 1.5.3 | producer 與 Loupe 共用 ready-frame store、同照片設定更新保留畫面 | [ready frame](inspection-1.5.3-ready-frame.md) |
| 1.5.4 | off-main quick scan、取消與 A/B/A stale completion 防護 | [folder switch](inspection-1.5.4-folder-switch.md) |
| 1.5.5 | proxy/native 幾何一致、holder extent 驗證；使用者 ROI 驗收正常 | [preview scale](inspection-1.5.5-preview-scale.md) |

各版文件的「未 GUI 驗收／未 commit」描述是當時 checkpoint 狀態，不是本次交付狀態；最終狀態以此摘要與 PR 為準。1.5.3 已註明哪些 RED 證據是事後 old-rule replay，不把它當成修改前的 TDD 紀錄。

## 驗證

- 本次交付重新以隔離 SwiftPM build path 跑完整 suite：**96 tests、3 skipped、0 failures**。跳過的是需 opt-in 環境與 manifest 的 benchmark，不能宣稱本次重跑了真實 RAW 效能 benchmark。
- 指令：`swift test --scratch-path "$HOME/.hermes/cache/scratch/lumibase-1.5.5-delivery/swift-build"`。
- 本機完整 log：`~/.hermes/cache/scratch/lumibase-1.5.5-delivery/swift-test.log`。`git diff --check` 通過。
- 既有 1.5.5 Release build 成功，交付 app hash 已在前一輪核對；本次不改產品程式碼、不重建 app。既有 executable SHA-256：`52eb7ced326af2223cb324af09c09ea58a43e1e6fbc54bec1ec9b65021672944`。此本機 artifact 不隨 PR 上傳。
- 自動測試涵蓋真實 preview producer → ready store → selection handoff、synthetic ROI producer、混合 LRU／記憶體壓力、設定／orientation／幾何拒收、held／Fit／native 尺寸與中心、資料夾 A/B/A 過時回傳。

## 已知限制與審查注意

1. **原先切換資料夾需 force quit 的症狀尚未證明完全修好。** 已知 sample 是 restart 後 AppKit idle，沒有捕捉確認中的 hang；已修正可重現的 main-thread listing／過時發布問題，但不能据此歸因所有卡死。
2. Sidebar 展開資料夾仍可能同步列舉；thumbnail decode 可能活得比已取消的 view task 久。未量測這些路徑對卡頓的影響。
3. 來源版本採 scanner 的 size／mtime／orientation；外部檔案變更要等 scanner refresh 才更新。128 MiB 不是 process memory 上限。
4. 測試 fixture helper 目前仍保留先前修正中的作者本機 scratch 絕對路徑（`inspectionTestScratchURL` 與 folder-switch fixture）。本次不額外改碼；朋友在不同帳號／CI 執行前需檢查路徑可寫性，這次測試結果僅證明本機環境。
5. 本次交付未啟動 GUI、未手動操作使用者照片／sidecar／偏好設定；完整 suite 的寫入測試使用 synthetic fixtures。GUI 正常的證據來自使用者上述回報。
