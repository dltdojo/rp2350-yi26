# 在 Lean 4 中構建 RISC-V M-mode 特權微模型與驗證監控程式（Micro-Monitor）設計規劃

<!-- SPDX-License-Identifier: Apache-2.0 -->

2026-10-14 的設計規劃。起因於 [硬體錢包評估文件](../2026-10-11-0610-verified-bytes-for-a-hardware-wallet-zh-tw.md) 提出的核心結構問題：

> 目前證明過的核心運行在 User 模式，受 PMP 限制；而負責周邊與初始化的 C 殼層卻運行在擁有最高特權的 Machine 模式，能讀取整塊記憶體。證明說的是「核心不會越界」，沒有說「殼層不會洩漏」。

要守住硬體錢包「種子絕不離開裝置」的承諾，必須將 Machine 模式縮小至一個極小且**本身經過形式化驗證的監控程式（Micro-Monitor）**，並將 USB 堆疊、通訊協議與顯示驅動徹底降權隔離至 User 模式。

本文件規劃如何以**路徑 B（微模型路線，Micro-Model in Lean 4）**實現此目標，並論證其如何 **100% 保持既有 U-mode 核心成果（exp229、exp228、exp208 等）的相容性**。

---

## 一、動機：解決特權邊界倒置

目前本倉庫的軟體架構呈現「沙盒化未信任程式」的樣態，而非硬體錢包所需的「安全飛地（Secure Enclave）」架構：

| 架構模式 | Machine 模式（最高特權） | User 模式（受限區域） | 安全承諾 |
| --- | --- | --- | --- |
| **目前現況** | 未經驗證的 C 語言 / 組語大型殼層（掌控全部記憶體、CSR 與周邊） | **形式化驗證的核心**（exp229 模運算、exp228 Script 解譯器） | 核心不會越界；但殼層若有漏洞或被攻陷，全系統失守 |
| **目標終態** | **形式化驗證的 Micro-Monitor**（僅負責 PMP 配置、Trap 轉發與清零） | **Domain 1**：密碼核心（持有私鑰）<br>**Domain 2**：USB / 螢幕 / 通訊（不可信） | 即使 USB 堆疊被惡意封包攻陷，硬體 PMP 保證其碰不到私鑰 |

要翻轉這個架構，必須在 M-mode 植入一個小而精準、可被定理證明的監控程式。

---

## 二、為何選擇「路徑 B：微模型路線」

社群中有兩種將 RISC-V 特權架構引進 Lean 的路線：

* **路徑 A（全量轉譯路線）**：引入劍橋大學 OpenCompl 團隊的 `opencompl/sail-riscv-lean`（及衍生之 `opencompl/riscv-lean`），將官方 Sail RISC-V 特權規格自動轉譯至 Lean 4。
* **路徑 B（微模型路線，Micro-Model）**：在現有 `lean/Rv32` 基礎上，只針對 RP2350（Hazard3 核心）所實作的硬體子集建立極小的特權語意模型。

本規劃明確選擇**路徑 B**，原因如下：

1. **信任基底最小化（Minimal TCB）**：Sail 轉出的全量模型以 RV64 為主且動輒數萬行，引入大量本專案用不到的虛擬記憶體（Sv39/48）、S-mode、浮點與向量語意。自建微模型可將程式碼壓在 300 行以內。
2. **避免 Lean 記憶體耗盡（OOM）**：先前的實驗（exp201、exp229）顯示，過大的模型展開會使 Lean 的 `simp` 與 `decide` 耗盡記憶體被系統殺死。微模型能在數秒內完成檢查。
3. **緊扣硬體真實特性**：RP2350 晶片上的 Hazard3 核心存在實體特異性（如 exp209 的 PMP 讀寫差異、exp203 的 `minstret` 計數特性）。通用標準模型無法反映這些晶片實體落差，自建微模型則能精確刻畫。

---

## 三、雙層精化架構（Two-Tiered Refinement）

為了讓既有的所有演算法成果**完全不用重寫、不用修改**，形式化模型採用雙層精化架構：

```
+---------------------------------------------------------------+
| Tier 2: M-mode 特權微模型 (PrivMachine)                       |
|   - 檔案: lean/Rv32/Priv.lean (新增)                          |
|   - 建模: Privilege Mode, 特權 CSR (pmpcfg, pmpaddr, mepc 等) |
|   - 定理: Micro-Monitor 的隔離性、清零保證與 Trap 轉發正則性   |
+---------------------------------------------------------------+
                               │
               [橋樑定理 / Refinement Theorem]
      "若 PrivMachine 處於 U-mode 且 PMP 鎖定 [lo, hi)，
       則其單步與多步執行嚴格等價於 Rv32.step 與 Rv32.run"
                               │
                               ▼
+---------------------------------------------------------------+
| Tier 1: 既有 U-mode 純計算模型 (Rv32.Machine)                 |
|   - 檔案: lean/Rv32/Machine.lean (保持不動)                   |
|   - 現有定理: exp229 (模 p)、exp228 (Script)、exp208 (SHA)   |
|   - 機器碼二進位檔: kernel.bin (完全相容，一位元組不改)       |
+---------------------------------------------------------------+
```

### 1. 既有成果 100% 向下相容的理由
* **二進位層級（ABI）**：既有的所有 `kernel.bin` 都是純 RV32IM 使用者模式程式碼，從不發出特權指令，只透過 `ecall`（`t0=1` 停機、`a0` 回報狀態）與外界互動。Micro-Monitor 只要維持該 ABI 約定，二進位檔即完全相容。
* **定理證明層級（Logic）**：現有 `Machine.lean` 的 `(env : Env)` 與 `(s : Machine)` 實際上就是 U-mode 執行時在 PMP 邊界內的數學投影。只要證明「特權狀態在 U-mode 下的轉移相容於投影狀態」，所有既有定理可直接套用為引理，一行都不必重寫。

---

## 四、Micro-Monitor 功能與模型規格

### 1. 最小特權 CSR 集合
微模型僅建模 Hazard3 上 M-mode 運作必須的暫存器（RP2350 硬體共提供 8 組 PMP 區域，微模型僅需建模前 4 組即可滿足隔離需求）：

| CSR | 作用 | 模型處理 |
| --- | --- | --- |
| `mstatus` | 特權模式與中斷控制 | 僅建模 `MPP`（前次特權級）、`MPIE`（前次中斷致能）與 `MIE`（全域中斷致能） |
| `mtvec` | Trap 向量基底 | 固定為 Direct 模式並指向 Micro-Monitor 的 Trap 進入點 |
| `mepc` | 例外返回位址 | 儲存發生 Trap/`ecall` 時的指令 PC；非停機 Syscall 完成後須加 4 再以 `mret` 還原 |
| `mcause` | 例外原因 | 識別 U-mode `ecall`（原因 8）與非法指令/存取錯誤（原因 1, 2, 5, 7） |
| `mscratch` | 暫存暫存器 | 用於進入 Trap 時交換上下文/堆疊指標，避免污染 U-mode 暫存器 |
| `pmpcfg0` | PMP 權限旗標 | 建模前 4 組區域的 R/W/X 與定址模式（RP2350 硬體僅支援 `OFF` 與 32-byte 粒度之 `NAPOT`） |
| `pmpaddr0..3` | PMP 邊界位址 | 定義沙盒的實體記憶體範圍（以 `NAPOT` 編碼對齊區間 `[lo, hi)`） |
| `mcountinhibit` | 計數器凍結 | 進入監控程式時凍結 `minstret`/`mcycle`（設定 `IR` 與 `CY` 位元），維持常數時間量測 |

### 2. 監控程式（Micro-Monitor）的職責
Micro-Monitor 由大約 100~150 條精簡的 `RV32I + Zicsr` 與 M-mode 特權指令（如 `mret`）組成，證明以下四大核心安全性質：

1. **隔離保證（Isolation Property）**：
   在執行 `mret` 進入 U-mode 前，PMP `entry 0`（或對應條目組）必被配置為目標 U-mode 區域（`NAPOT` 模式），其餘未授權空間（包括 M-mode 專屬程式碼、機密區與其他 Domain 資料區）依 RISC-V PMP 預設規則對 U-mode 皆不可存取。任何 U-mode 越界存取必定觸發存取錯誤 Trap（`mcause = 1, 5, 7`）回到 M-mode。
2. **上下文乾淨切換與清零（Zeroization）**：
   當從持有私鑰的 U-mode 任務（如 exp229 模運算或簽章核心）返回 M-mode 或切換至不可信通訊任務時，監控程式證明：除必要的輸出結果暫存器 `a0`（`x10`）外，其餘可寫通用暫存器 `x1..x31`（`x0` 恆為 0）與機密暫存 SRAM 區域全數清零，機密不會殘留給後續運行的通訊任務。
3. **Syscall ABI 轉發保證**：
   嚴格保持既有介面（非停機呼叫於完成後將 `mepc ← mepc + 4` 並執行 `mret`）：
   - `t0 = 1`（HALT）：讀取 `a0` 退出碼，記錄於回報結構中，執行清零並安全停機（或切換至下一任務）。
   - `t0 = 0 / 2`（HASH）：檢查傳入指標與長度完全落在當前 U-mode 授權之 PMP 記憶體邊界內（防止 Confused Deputy 越權讀寫），安全轉發至硬體 SHA-256 加速器，結果寫回後推進 `mepc` 並恢復 U-mode。
   - `t0 = 3`（CHECKSIG）：檢查金鑰、訊息與簽章緩衝區邊界，安全呼叫驗章模組，完成後推進 `mepc` 並恢復 U-mode。
4. **確切的指令數定理**：
   進入與退出 Micro-Monitor 的每條執行路徑皆為固定指令數，將原本依賴晶片實測的殼層補償常數（如 exp203 的 $+3$、exp228 的 $+4$）升格為由 Lean 形式化證明的常數定理。

### 3. 規避晶片實體缺陷（Silicon Quirks）
根據過去實驗的量測經驗，Micro-Monitor 的實作與證明必須遵循以下防禦規則：
* **不依賴 PMP 讀回原始寫入值比對**：RP2350 的 Hazard3 核心將 PMP 粒度固定為 32 bytes（`PMP_GRAIN = 3`），依規格當 `pmpcfg.A = OFF` 時 `pmpaddr` 的 bits `[2:0]` 讀回強制為 `0`，而當 `pmpcfg.A = NAPOT` 時 bits `[1:0]` 讀回強制為 `1`（即 exp209 觀察到讀回 `pmpaddr0` 與寫入值不同的成因）。因此證明僅約束「寫入指令序列保證硬體生效」，而不使用「寫入後讀回與原始寫入值逐位元相等」的確認邏輯。
* **計數器凍結序列**：進出 Trap 時首條指令固定為 `csrwi mcountinhibit, 5`（同時置位 bit 0 `CY` 與 bit 2 `IR`），避開 Hazard3 對 `ecall` 與 `mret` 的微架構計數異常。

---

## 五、分階段落地計畫

| 階段 | 內容 | 產出 | Needs | 說明 |
| --- | --- | --- | --- | --- |
| **階段 1** | **特權微模型語意** | `lean/Rv32/Priv.lean` | 0 | 定義 `PrivMachine`、特權 CSR 語意、PMP 存取判定函式與 Trap 轉移規格 |
| **階段 2** | **橋樑定理證明** | `lean/Rv32/Refinement.lean` | 0 | 證明「U-mode + PMP 下的 `PrivMachine` 精化 `Rv32.Machine`」，接通既有核心證明 |
| **階段 3** | **Micro-Monitor 機器碼與證明** | `monitor.bin`、`proof/Monitor.lean` | 0 | 實作約 120 條 `RV32I + Zicsr` 監控指令，證明隔離性、清零定理與固定指令數 |
| **階段 4** | **端到端整合測試** | RTL 模擬與差分測試 | 0 | 在 Hazard3 Verilator RTL 上運行：Monitor 架牆 → 載入 exp229 核心 → 運算 → Trap 返回 → 驗證清零 |
| **階段 5** | **Pico 2 晶片實測** | 板載驗證 | 2 或 3 | 燒錄至 Pico 2，以 LED 閃爍或 USB 檢驗晶片執行週期與指令數是否吻合定理 |

---

## 六、總結與效益

採用「路徑 B：微模型路線」建立 M-mode Micro-Monitor，能以最小的工程代價達到硬體錢包最嚴苛的安全等級：

1. **既有資產零浪費**：已證明之有限體運算（exp229）、Script 解譯器（exp228）與雜湊核心（exp208）完全原封不動繼承。
2. **信任邊界徹底收窄**：未經驗證的 C 語言殼層（`harness.S` 與 `shell.c`）自最高特權區徹底拔除，換上形式化驗證的極小機器碼。
3. **奠定硬體錢包終態架構**：使 RP2350 能夠在缺乏 S-mode 的硬體限制下，僅靠單一 `pmpcfg0` 控管的 4 組 PMP 條目子集（硬體共 8 組）就安全構建出「持鑰安全飛地」與「不可信通訊層」的硬體級隔離。
