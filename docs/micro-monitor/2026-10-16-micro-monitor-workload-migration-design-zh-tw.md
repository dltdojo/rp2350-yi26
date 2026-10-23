# Micro-Monitor 跨應用負載移植與架構演進設計規劃（exp238–exp240）

<!-- SPDX-License-Identifier: Apache-2.0 -->

* **文件日期**：2026-10-16
* **前置基礎**：
  * `exp235-the-boundary-the-proof-bridges`（Hazard3 特權模型 `PrivMachine` 與 U-mode 精化橋樑定理）
  * `exp236-the-wall-the-monitor-holds`（143 字 `monitor.bin` 形式化驗證）
  * `exp237-the-enclave-on-the-chip`（RP2350 Pico 2 晶片純 C + 組語硬體飛地與 `exp229` 有限體運算驗證）
* **規劃目標**：將既往已驗證的三大代表性核心（`exp228` Tapscript 解譯器、`exp223` TRNG 健康檢驗與條件摘要、`exp225` Rule 30 狀態演進）嵌移至 `monitor.bin` 架構，系統性檢驗並升級現有 Micro-Monitor 在**雙向系統呼叫**、**Fail-Closed 記憶體抹除**與**多條目 W^X PMP 權限細分**上的設計缺口。

## 一、現有 `monitor.bin`（exp236 / exp237）之架構假設與局限分析

在 `exp236` 與 `exp237` 中，`monitor.bin` 針對 `exp229`（secp256k1 模運算）完成端到端證明與晶片實測。然而 `exp229` 屬於「純暫存器/固定緩衝區運算、無中途外部服務請求、單次執行即停機」的最簡負載，使現有 `monitor.bin` 隱含了四項結構性假設：

| 架構維度 | 現有 `monitor.bin`（exp236 / exp237）實作現況 | 面對複雜應用時的結構性局限 |
| :--- | :--- | :--- |
| **1. 系統呼叫（Syscall ABI）** | 僅支援 `ecall t0 = 1`（`SYS_HALT`）；其餘任何 `t0` 值一律跳轉 `handle_fault` 並中止 | 無法支援執行中途請求雜湊（`t0 = 0/2`）或驗章（`t0 = 3`）再返回 U-mode 繼續執行的解譯器或協定核心 |
| **2. 指標邊界防禦（Confused Deputy）** | 無需檢查指標（因無中途中介讀寫服務） | 一旦開放 M-mode 代行服務，若未驗證 U-mode 傳入之 `(ptr, len)` 是否落在沙盒內，惡意負載可誘騙 Monitor 讀寫 M-mode 機密區 |
| **3. 退場零化範圍（Zeroization）** | 僅清除通用暫存器 `x1..x9, x11..x31`、`mscratch` 與 2 個暫存字組；**不動搖 Payload SRAM** | 若負載為 TRNG 熵源檢驗或私鑰簽章，在拒絕服務（Fail-closed）或退場時，私密中間態仍殘留於 SRAM 中 |
| **4. PMP 權限粒度（W^X 與分區）** | 單一 `pmpaddr0` 配置 64 KiB `NAPOT` 全開權限（`R/W/X = 111`） | 未落實 **W^X（Write XOR Execute）**；U-mode 程式碼可覆寫自身指令，且未區分「私密工作區」與「外部共享輸出區」 |

為徹底檢驗上述四個維度，本文件規劃三個循序漸進的移植實驗（`exp238`、`exp239`、`exp240`），每一個實驗鎖定一組核心能力進行擴充與證明。

## 二、三階段實驗總覽與架構演進矩陣

| 實驗規劃 | 嵌移目標負載 | 核心檢驗目的 | 對 `monitor.bin` 的關鍵修改與調整 | Needs 等級 |
| :--- | :--- | :--- | :--- | :---: |
| **`exp238`**<br>*(雙向系統呼叫與代理防禦)* | **`exp228`**<br>Bitcoin Tapscript 解譯器<br>*(881 指令)* | 檢驗**非停機雙向 Syscall（`HASHB` / `CHECKSIG`）**、溢位安全之 **Confused-Deputy 邊界檢查**，以及 `mepc + 4` 恢復執行與固定指令數補償 | 1. 擴充 Trap 上下文保存（完整保存 U-mode 暫存器）<br>2. 新增 `t0 = 2` 與 `t0 = 3` 分發與無溢位 PMP 區間檢查<br>3. 新增 `trap_return`（`mepc += 4`、解凍計數器、`mret`） | `0 · none`<br>*(或 `2` 含晶片實測)* |
| **`exp239`**<br>*(Fail-Closed 與記憶體零化)* | **`exp223`**<br>NIST SP 800-90B 健康檢驗 + SHA-256 條件摘要<br>*(8484 Bytes, 33.4 萬指令)* | 檢驗 **Fail-Closed 安全拒絕承諾**、長週期大負載穩定性，以及退場時**敏感 SRAM 工作區硬體級清零** | 1. 劃分 Enclave 內部為「敏感樣本/工作區」與「公開摘要輸出區」<br>2. 於 `scrub_exit` 及 `handle_fault` 加入固定迴圈清除敏感 SRAM 區段<br>3. 當 `a0 != 0`（檢驗失敗）時連同輸出區一併強制歸零 | `0 · none`<br>*(或 `2` 含晶片實測)* |
| **`exp240`**<br>*(多輪重入與多條目 W^X PMP)* | **`exp225`**<br>Rule 30 元胞自動機<br>*(76 Bytes, 3079 指令/輪)* | 檢驗**多輪連續重入（Stateful Re-entry）**與啟用 **3 組 PMP 條目實現 W^X（代碼唯讀執行、工作區讀寫不執行、輸出區唯讀共享）** | 1. 同時啟用 `pmpaddr0`（Code `RX`）、`pmpaddr1`（Scratch `RW`）、`pmpaddr2`（Output `RW`）<br>2. 驗證跨百輪連續重入時 CSR 與計數器之冪等性與無狀態洩漏 | `2 · a moment`<br>*(含 Pico 2 與 WebUSB)* |

## 三、實驗一設計：`exp238` — 嵌移 `exp228` Tapscript 解譯器（雙向 Syscall 與邊界檢查）

### 1. 負載行為與現有 `monitor.bin` 的衝突點
`exp228` 的 Tapscript 解譯器（`kernel.bin`，881 條指令）在 U-mode 執行腳本時，會動態發出三種 `ecall`：
* **`t0 = 2` (`HASHB`)**：請求計算位於 `a0`、長度為 `a1` bytes 的資料之 SHA-256 雜湊，並寫入 `a2` 指向的 32-byte 緩衝區。
* **`t0 = 3` (`CHECKSIG`)**：請求驗證 32-byte 公鑰（位於 `a0`）與 64-byte BIP340 簽章（位於 `a1`），將結果 `1`（有效）或 `0`（無效）寫回 `a0`。
* **`t0 = 1` (`HALT`)**：腳本解譯結束，回傳最終判定碼 `a0`（`0` 為接受，`1..12` 為各類拒絕原因）。

若直接在現有 `exp236/exp237` 的 `monitor.bin` 上執行 `exp228`：
1. 第一個包含 `OP_SHA256` 或 `OP_CHECKSIG` 的腳本觸發 `ecall` 時，Monitor 見 `t0 != 1` 會直接進入 `handle_fault`，將 `a0` 改寫為 `1` 並強制退場，無法完成解譯。
2. 現有 Monitor 的 Trap 入口僅保存 `t0` 與 `t1`，未保存解譯器正在使用的其餘暫存器。

### 2. `monitor.bin` 架構調整設計（v2：Interactive Syscall Monitor）

#### (A) 完整上下文保存框（Context Frame at `0x20008000`）
當 `t0 = 2` 或 `t0 = 3` 轉交處理（無論是由 M-mode 內建常數時間雜湊處理，或透過 Upcall 交由宿主處理後重返）時，U-mode 解譯器的所有工作暫存器 `x1..x31` 必須在返回 U-mode 時保持原樣（僅 `CHECKSIG` 更新 `a0`）：
* 在 `mscratch`（`0x20008000`）建立 32-word 上下文框（`0x20008000 .. 0x2000807C`）。
* Trap 入口凍結計數器（`csrwi mcountinhibit, 5`）後，交換 `sp` 與 `mscratch`，依序將 `x1..x31` 存入上下文框。

#### (B) 無溢位 Confused-Deputy 邊界檢查序列（`pmp_bounds_check`）
對應 `lean/Rv32/Machine.lean` 中 `syscall` 的 `env.region.ok` 條件，Monitor 在執行 `HASHB` 或 `CHECKSIG` 前，必須在 M-mode 組語中直接檢驗指標區間 `[ptr, ptr + len)` 是否完全落在當前 U-mode 沙盒 `[BOX_LO, BOX_HI)`（即 `[0x20010000, 0x20020000)`）內。為防止 `ptr + len` 發生 32-bit 無符號整數溢位（Wraparound），採用減法邊界檢查：

```
# 檢查區間 [a0, a0 + a1) 是否落在 [t1=BOX_LO, t2=BOX_HI) 內：
# 條件 1: a0 >= BOX_LO
bltu  a0, t1, handle_fault
# 條件 2: a0 <= BOX_HI (確保 t2 - a0 不發生下溢)
bltu  t2, a0, handle_fault
# 條件 3: a1 <= BOX_HI - a0
sub   t3, t2, a0
bltu  t3, a1, handle_fault
```

* 對於 `t0 = 2` (`HASHB`)：檢查 `[a0, a0 + a1)` 與 `[a2, a2 + 32)` 皆在沙盒內；任一越界即跳轉 `handle_fault`（清零並中止）。
* 對於 `t0 = 3` (`CHECKSIG`)：檢查 `[a0, a0 + 32)` 與 `[a1, a1 + 64)` 皆在沙盒內；任一越界即跳轉 `handle_fault`。

#### (C) 雙向返回路徑（`trap_return`）與精確計數器對帳
當邊界檢查通過並完成雜湊或驗章後：
1. 讀取 `mepc`，計算 `mepc ← mepc + 4` 並寫回 `mepc`（跳過剛執行的 `ecall` 指令）。
2. 從 `0x20008000` 上下文框還原 `x1..x31`（若為 `CHECKSIG`，`a0` 載入驗章結果 `0` 或 `1`）。
3. 執行 `csrrw sp, mscratch, sp` 恢復 U-mode 堆疊指標。
4. 執行 `csrwi mcountinhibit, 0` 解凍計數器，緊接著執行 `mret` 返回 U-mode。

**硬體計數器定理論證**：
在 `PrivMachine` 與 Hazard3 硬體上，一次非停機 Syscall 的 `minstret` 增量嚴格為常數：
* U-mode 執行 `ecall`（此時 `mcountinhibit.ir = 0`）：`minstret + 1`
* Trap 入口首條指令 `csrwi mcountinhibit, 5`：立即生效，本身不計入 `minstret`（`+0`）
* Monitor 內部所有檢查與服務指令：`mcountinhibit.ir = 1`（`+0`）
* 返回前執行 `csrwi mcountinhibit, 0`：寫入後 `ir` 變為 `0`，計數器推進（`+1`）
* 執行 `mret`（此時 `ir = 0`）：計數器推進（`+1`）
* 這將過去在 `exp228` C 殼層中經驗測得的常數補償，轉化為由 Lean 4 形式化證明的常數定理。

### 3. `exp238` 的 Lean 4 定理規劃
* `monitor_hashb_ok`：在 `UBoxed` 狀態下觸發 `ecall t0 = 2` 且 `[a0, a0+a1)`、`[a2, a2+32)` 位於沙盒內，Monitor 驗證通過並將 `mepc` 推進 4、保持 `UBoxed` 不變返回 U-mode。
* `monitor_hashb_oob_fault`：當 `a0`、`a1` 或 `a2` 越界（含 `a0 + a1 >= 2^32` 溢位攻擊）時，Monitor 必定拒絕服務並走入 `scrub_exit` 將暫存器全數清零停機。
* `monitor_checksig_ok` / `monitor_checksig_oob_fault`：對 `t0 = 3` 證明相同之邊界安全性與狀態推進性質。

### 4. 實作結果與本設計的差異（2026-10-17，exp238 完成後補記）

`exp238` 已完成並合併，下列幾點與上文不同，以實作為準：

* **只保存 `t0..t3`，不保存 `x1..x31`。** Monitor 只動用這四個暫存器，Trap 入口就只存這四個；其餘暫存器在呼叫前後原樣，由 `monitor_hashb_ok` / `monitor_checksig_ok` 證明（`CHECKSIG` 的 `a0` 除外）。
* **Monitor 不做雜湊也不驗章。** 通過邊界檢查的呼叫轉給宿主的服務埠（`0xc0000010..0xc000001c`），Monitor 只負責「被要求的範圍都在盒子內」。
* **位址用模型的 `0x80010000..0x80020000`**，不是本文的晶片位址 `0x2001xxxx`。
* **`monitor.bin` 正好 200 字（800 bytes）**，已用滿第六節的預算。2026-10-23 在 `CHECKSIG` 讀回答案之後加了兩個字：答案不是 0 或 1 就走 fault（見 [稽核](../2026-10-23-1116-emulator-verdicts-vs-theorems-audit-zh-tw.md) 的 G6），成為 202 字（808 bytes），比預算多兩個字。
* **Lean 證明**：`proof/Calls.lean` 由產生器 `proof/gen.py` 寫出，12 個定理，含任意次呼叫與從重置開始的端到端。完整檢查約半小時，大部分花在 Lean 拒絕突變上。

## 四、實驗二設計：`exp239` — 嵌移 `exp223` TRNG 健康檢驗與條件摘要（Fail-Closed 與 SRAM 零化）

### 1. 負載行為與現有 `monitor.bin` 的衝突點
`exp223`（`kernel.bin`，8,484 bytes）結合了 `exp222` 的 NIST SP 800-90B 連續健康檢驗（Repetition Count Test 與 Adaptive Proportion Test）與 `exp208` 的 SHA-256 壓縮核心：
* 輸入為位於 `base + 0x3000` 的 1,024 個 32-bit 原始熵源樣本（4,096 bytes）。
* **若檢驗失敗（Broken Entropy）**：核心在精確 **17,425** 條指令後執行 `ecall (t0 = 1, a0 = 1)` 停機，保證不寫入摘要區 `base + 0x2140`。
* **若檢驗通過（Healthy Entropy）**：核心繼續對該 4,096 bytes 計算 SHA-256，在精確 **334,284** 條指令後將 32-byte 摘要寫入 `base + 0x2140`，並以 `ecall (t0 = 1, a0 = 0)` 停機。

現有 `monitor.bin` 面對此應用有兩項缺陷：
1. **私密原始樣本與中間態殘留於 SRAM**：當 `exp223` 計算完畢退場後，雖然通用暫存器被 Monitor 清零，但位於 `base + 0x2200 .. 0x2440` 的 SHA-256 工作排程陣列 $W[0..63]$、內部狀態 $H$，以及 `base + 0x3000 .. 0x4000` 的 4,096 bytes 原始未白化熵源樣本，仍然明文留在 SRAM 中。
2. **Fail-Closed 的特權層強制力不足**：若 U-mode 核心因檢驗失敗（`a0 = 1`）或發生例外（Fault）退場，Monitor 本身應主動銷毀沙盒內的輸出區與工作區，確保外部不可信程式即使讀取共享記憶體也讀不到任何殘留位元。

### 2. `monitor.bin` 架構調整設計（v3：Memory-Scrubbing & Fail-Closed Monitor）

#### (A) 沙盒記憶體子區域正規劃分
在 64 KiB 沙盒 `[0x20010000, 0x20020000)` 內明確定義三個區域角色：
* `0x20010000 .. 0x20012140`：唯讀核心代碼與常數區（Code & K/IV Constants）
* `0x20012140 .. 0x20012160`：**公開摘要輸出區（Public Digest Output, 32 bytes）**
* `0x20012200 .. 0x20014000`：**機密工作與原始熵源區（Confidential Scratch & Raw Samples）**

#### (B) 硬體級 SRAM 退場清零迴圈（Scratch Zeroization）與 Fail-Closed 強制抹除
修改 Monitor 的 `scrub_exit` 階段：
1. **無條件清除機密工作區**：在退場前，Monitor 使用固定邊界迴圈（或針對關鍵敏感區段 `0x20012200 .. 0x20014000`）以 `sw x0, 0(t0)` 覆寫歸零。
2. **Fail-Closed 條件抹除輸出區**：檢查退場狀態 `a0`。若 `a0 != 0`（包含健康檢驗失敗 `HALT 1` 或任何硬體 Trap Fault），Monitor **額外將公開摘要輸出區 `0x20012140 .. 0x20012160` 強制覆寫為全 0**。
3. 這使得「只有通過 SP 800-90B 檢驗且無任何硬體錯誤時，輸出區才可能存在非零摘要」成為不僅由 U-mode 核心保證、更由 **M-mode Monitor 特權層雙重背書（Defense-in-Depth）** 的硬體定理。

### 3. `exp239` 的 Lean 4 定理與晶片驗證規劃
* `monitor_fail_closed_scrub`：證明當 U-mode 以 `a0 != 0` 停機或發生任何 Fault Trap 時，Monitor 停機狀態下不僅 `x1..x9, x11..x31` 為 0，且摘要輸出區 `[0x20012140, 0x20012160)` 與機密工作區之每一個位元組皆為 `0`。
* `monitor_pass_digest_kept`：證明當 U-mode 以 `t0 = 1, a0 = 0` 正常停機時，機密工作區被清零，而摘要輸出區的 32 bytes 完整保留 U-mode 核心寫入的 SHA-256 結果。
* **晶片實測（Pico 2）**：驗證三種熵源（RP2350 硬體 TRNG、全 1 故障源、9 個 1 加 1 個 0 週期源）在 Monitor 保護下的 `minstret`（通過為 `334,284`，拒絕為 `17,425`）與記憶體清零結果。

### 4. 修正（2026-10-17，exp238 完成後）

動工前讀了 `exp223` 與 `exp238`，上文有四處要修正：

1. **以 `exp236` 為底，不以 `exp238` 為底。** `exp223` 的 SHA-256 在 U-mode 核心內自己算，只用 HALT，用不到 `exp238` 的呼叫。`exp238` 已用滿 200 字，再加清零迴圈必然超出預算；以 `exp236`（143 字）為底，預估約 160 字。三版合計 200 字以內（第六節第 4 點）因此不成立：`exp238` 與 `exp239` 是兩條分支，各自在預算內，不是疊加。
2. **清零是迴圈，證明要換方法。** 機密區 `+0x2200..+0x4000` 共 1,920 個字。`exp238` 的產生器只做直線程式的逐步符號執行；`exp239` 需要一條迴圈不變式引理，證明迴圈結束時該區每個位元組為 0、區外不變。這是本實驗最主要的新工作。
3. **核心的正確性不串進 Lean。** `exp223` 的核心定理要求 128 KiB 的區域（`exp208` 的 SHA 從 `0x1000` 起，其 64 KiB 區域延伸到 `0x11000`），而 Monitor 的盒子是 64 KiB。核心實際只碰 `0x4000` 以下，在盒子裡跑沒有問題，但「摘要等於 `exp223` 證明的那個值」不能直接接上。做法比照 `exp238`：Monitor 的行為由 Lean 證明，核心的結果在模擬器上與無 Monitor 的執行逐位元組比對。
4. **不含晶片實測，Needs 維持 `0 · none`。** 上文第 3 節的 Pico 2 實測需要這個 Monitor 的晶片版，目前沒有（`exp237` 的 `monitor_chip.S` 由 `exp236` 衍生、未經證明）。晶片移植另開實驗，帶一份與 `monitor.S` 的機械檢查差異。

位址同 `exp238`：用模型的 `0x80010000` 加偏移量，摘要輸出區 `+0x2140..+0x2160`、機密區 `+0x2200..+0x4000`。

### 5. 實作結果與本設計的差異（2026-10-17，exp239 完成後補記）

`exp239` 已完成，下列幾點與上文不同，以實作為準：

* **`monitor.bin` 為 156 字（624 bytes）**，比第 4 小節預估的約 160 字略少，離第六節第 4 點的 200 字預算仍有餘裕。新增的 13 個字插在 `exp236` 的 `scrub_exit` 前三個字之後，其餘 143 個字與 `exp236` 逐字相同。
* **摘要區也用迴圈，不用 8 個直線 `sw`。** 兩個迴圈是同一組三個字（`sw zero, 0(t0)`、`addi t0, t0, 4`、`bne t0, t1, loop`），迴圈引理只證一次、用兩次；清零的範圍剛好是摘要區 32 bytes，不會多帶走中間 160 bytes。
* **條件只看 `a0`。** 錯誤路徑把 `a0` 設成 1，所以 `a0 ≠ 0` 涵蓋健康檢驗失敗（`HALT 1`）、其他非零的 `HALT`、不提供的 `ecall` 與所有例外。Monitor 不認得「摘要」，只認得「`HALT 0`」；「`HALT 0` 即代表健康檢驗通過、32 bytes 是樣本的 SHA-256」是 `exp223` 對其核心的定理，沒有串進這份證明。
* **定理**：`monitor_fail_closed_scrub` 與 `monitor_pass_digest_kept` 如設計；另有 `monitor_scrubs`（任何一種陷阱都停泊，且記憶體依結束碼洗淨）、`monitor_end_to_end`（從重置開始）、迴圈引理 `zloop_conf` / `zloop_dig`（對迭代次數歸納）。
* **證明產生器共用的部分抽到 `tools/monitor/chunks.py`**，`exp238` 與 `exp239` 共用；`exp238` 的 `Calls.lean` 逐位元組不變。
* **模擬器**：`exp223` 的核心在 `exp222` 的 14 條樣本串流（8 條通過、6 條不通過）上，單獨執行與在 Monitor 下執行逐一比對：行為一致，Monitor 只多 2 條已計數指令（框架），退場後 256 KiB 記憶體與預期逐位元組相同。

## 五、實驗三設計：`exp240` — 嵌移 `exp225` Rule 30 自動機（多輪重入與多條目 W^X PMP）

### 1. 負載行為與現有 `monitor.bin` 的衝突點
`exp225`（`kernel.bin`，76 bytes）每次執行 3,079 條指令，從 `base + 0x100` 讀取 32-bit 種子，演化 256 代並寫入 `base + 0x200 .. 0x600`（1,024 bytes），隨後將第 256 代作為下一輪的種子，無限世代連續執行。

此應用暴露現有 `monitor.bin` 的另外兩個設計問題：
1. **單一 PMP RWX 條目違反 W^X 原則**：現有 `monitor.bin` 將整個 64 KiB 設為 `pmpcfg0 = 0x1F`（`R=1, W=1, X=1`）。若負載存在指標錯誤，U-mode 程式可以覆寫位於 `0x20010000` 的自身機器碼，破壞「執行代碼不可變（Code Immutability）」假設。
2. **多輪連續重入（Multi-Round Re-entry）的狀態隔離**：在 `exp237` 中僅執行 3 次獨立運算，而在 `exp225` 中需要連續執行數十至數百輪，且每一輪的輸出直接成為下一輪的輸入，需檢驗 Monitor 在高頻重入下對 CSR、堆疊與權限的穩定維持能力。

### 2. `monitor.bin` 架構調整設計（v4：Multi-Entry W^X PMP Monitor）

#### (A) 啟用 `pmpcfg0` 多組 PMP 條目實現嚴格 W^X 分離
利用 `lean/Rv32/Priv.lean` 已建模的 4 組 PMP 條目（`pmpaddr0..3` 與 `pmpcfg0` 的 4 個配置位元組），將 Enclave 內部細分為三個獨立權限的 `NAPOT` 子區域，**徹底消除任何同時具備 `W` 與 `X` 的記憶體位址**：

| PMP 條目 | 區域用途 | 實體位址範圍 `[lo, hi)` | 大小 | `pmpaddr` 編碼值 | `pmpcfg0` 位元組權限 | 安全意義 |
| :---: | :--- | :--- | :---: | :---: | :---: | :--- |
| **Entry 0** | **Code 區** | `0x20010000 .. 0x20011000` | 4 KiB | `0x080041FF` | `0x1D` (`NAPOT`, **`R+X, !W`**) | U-mode 核心代碼唯讀可執行，任何寫入嘗試立即觸發 Store Access Fault (`mcause = 7`) |
| **Entry 1** | **Data / I/O 區** | `0x20011000 .. 0x20012000` | 4 KiB | `0x080045FF` | `0x1B` (`NAPOT`, **`R+W, !X`**) | 存放種子（`+0x100`）與 256 代輸出（`+0x200..0x600`），可讀寫但不可執行 |
| **Entry 2** | **Stack 區** | `0x2001F000 .. 0x20020000` | 4 KiB | `0x08007DFF` | `0x1B` (`NAPOT`, **`R+W, !X`**) | U-mode 獨立堆疊空間，與資料區隔離（中間 `0x20012000..0x2001F000` 未映射，作為硬體 Guard Page 防止 Stack Overflow） |
| **Entry 3** | *保留未用* | — | — | `0x00000000` | `0x00` (`OFF`) | 預設關閉 |

* 合成之 32-bit `pmpcfg0` 配置常數為：**`0x001B1B1D`**（Entry 0 = `0x1D`, Entry 1 = `0x1B`, Entry 2 = `0x1B`, Entry 3 = `0x00`）。

#### (B) 硬體 Guard Page 與 W^X 故障攔截
* 若 U-mode 程式發生堆疊溢位（Stack Underflow/Overflow 跨出 `0x2001F000 .. 0x20020000`），因中間區域未映射（`OFF`），硬體 PMP 立即觸發 Fault Trap。
* 若 U-mode 程式嘗試跳轉至資料區或堆疊區執行指令（Shellcode 注入攻擊），因 Entry 1 與 Entry 2 的 `X = 0`，硬體 PMP 立即在取指階段觸發 `CAUSE_FETCH_ACCESS_FAULT`（`mcause = 1`）。

### 3. `exp240` 的 Lean 4 定理與驗證規劃
* 在 `lean/Rv32/Sandbox.lean` 擴充定義 `WXBoxed (s : PrivMachine) (codeLo codeHi dataLo dataHi stackLo stackHi : Nat) : Prop`。
* 證明 **W^X 互斥定理（`wx_no_write_exec`）**：在 `WXBoxed` 狀態下，對任意 32-bit 位址 `addr`，`pmpCheck s.csrs .U addr 4 .Fetch = true` 與 `pmpCheck s.csrs .U addr 4 .Store = true` 永遠不可能同時成立。
* 證明 **Code 區絕對不可變定理（`wx_code_immutable`）**：無論 U-mode 負載執行多少步，只要處於 `WXBoxed`，位於 `[codeLo, codeHi)` 內的機器碼位元組與初始載入時完全相同（不需要像單一條目 RWX 那樣依賴「負載自身不寫入代碼區」的軟體假設，而是由硬體 PMP 直接保證）。

### 4. 實作結果與本設計的差異（2026-10-17，exp240 完成後補記）

`exp240` 已完成，下列幾點與上文不同，以實作為準：

* **以 `exp236` 為底，151 字（604 bytes）。** 比 `exp236` 多 8 字，全部在開機：三個 PMP 位址與 `pmpcfg0` 各一個 `li` 加一個 `csrw`，原本只有一個條目，共多 7 字；另外 `mstatus` 改成整個寫 0（一個字，取代 `exp236` 只清 `MPP` 的三個字），並寫 `pmpaddr3`、`mcause`、`mtval`，淨多 1 字。處理常式與退場清零段整體往後移 `0x20` bytes，字與 `exp236` 逐字相同。（最初完成時是 150 字、移 `0x1c`；審查指出開機沒有寫到每一個 CSR，2026-10-17 改成現在這樣。）`exp240` 不含 `exp239` 的記憶體清零，兩者是 `exp236` 的兄弟，各有各的字數預算。Lean 檢查約 50 秒。
* **位址用模型的 `0x8001xxxx`，不是晶片的 `0x2001xxxx`。** 與 `exp236` 至 `exp239` 一致。
* **Code 與 Data 不是兩個不相交的 4 KiB 頁。** 設計表假設種子與輸出在 Data 頁，核心在 Code 頁；但 `exp225` 的核心用 `auipc` 取自己的位址，種子在 `+0x100`、歷史在 `+0x200..+0x600`，都是相對於核心自己的相對位置，與核心的 76 bytes 在同一頁。實作改為：Code 條目 128 bytes `[+0, +0x80)`（`pmpaddr0 = 0x2000400f`，`R+X`，`0x1d`），Data 條目 4 KiB `[+0, +0x1000)`（`pmpaddr1 = 0x200041ff`，`R+W`，`0x1b`），Stack 條目 4 KiB `[+0xf000, +0x10000)`（`pmpaddr2 = 0x20007dff`，`R+W`，`0x1b`）；`pmpcfg0 = 0x001B1B1D` 與設計相同。**Data 條目蓋住 Code 條目**，靠 PMP「編號最小且碰到存取的條目決定結果」把 Code 的 128 bytes 從 Data 挖出來。W^X 因此靠條目順序成立，不靠區域不相交；`wx_no_write_exec` 證明的正是這一點，把條目順序顛倒（`pmp_entries_tried_backwards`）就被 Lean 拒絕。副作用：負載必須放得進 128 bytes。
* **定理放在新檔 `lean/Rv32/WxBox.lean`，不是 `Sandbox.lean`。** `WXBoxed` 的參數是三個條目各自的 `lo`、`hi`；`wx_no_write_exec` 與 `wx_code_immutable` 如設計，另有 `wx_fetch_iff`、`wx_store_ok`、`wx_disjoint`、`wx_step`、`wx_run` 與 `pmpCheck_M_outside_in`（M-mode 在方塊之外永不被拒）。`wx_code_immutable` 不假設負載的指令長什麼樣，只靠 PMP。
* **「多輪重入」是重置後再來一輪。** Monitor 在 `HALT` 後停機、不返回，所以一輪是：重置、開機、負載跑到第一個陷阱、處理、停機。`monitor_boot` 證明開機後的 CSR 檔恰是常數 `csrsBooted`（計數器為 2），出發點可以是任何沒有鎖住 PMP 條目的 CSR，所以暫存器與 CSR 都不會帶到下一輪（記憶體會，負載自己讀它）；`resetOf` 是最弱的重置，連 CSR 都不重設；`monitor_round_ready` 證明一輪之後機器仍是 `Ready`（monitor 的字在原處、Code 的 128 bytes 與最初載入的相同）；`monitor_rounds` 對任意輪數歸納，輪與輪之間可以有任意多次主機寫入（`HostWrite`：除了 monitor 的字、Code 區與 PMP 的鎖定位元，什麼都可以改），也就是模擬器上 `rounds.py` 實際做的事。設計的 `monitor_reentry_invariant` 因此實作為這幾個定理。模擬器上每隔一輪的重置把 CSR 填滿垃圾值（`MPP` 為 M-mode、四個 PMP 條目都開），`exp240` 每輪停機時的機器仍相同；`exp236` 則不同，它只清 `MPP`、只設一個條目，找到的中斷致能與沒用到的條目位址會留到停機時。
* **每輪 `minstret` 是 3,081，不是 3,079。** 3,079 是核心本身（含最後那個 `ecall`），monitor 的框架另加 2 條（釋放計數器的 `csrwi` 與 `mret`），與 `exp239` 相同。模擬器上 100 輪每輪都是 3,081。
* **模擬器分得出「被 PMP 擋下」與「那裡沒有記憶體」。** 兩者的 `mcause` 與 `mtval` 相同（晶片上的匯流排錯誤也一樣），所以 monitor 的回報分不出來；模擬器記錄是哪一個，`check_fault` 要求是 PMP。第四個條目打開、蓋住位址 0 的 32 bytes（`entry_three_on`）只會被這一點抓到。
* **核心的行為沒有串進 Lean。** 與 `exp239` 同：Lean 證明的是 monitor 的字做什麼；`exp225` 的核心在這個方塊裡跑出對的 256 代、不踩任何一條 PMP，是在模擬器上與 `rule30.py` 逐位元組比對（100 輪、25,600 代）。
* **處理常式的證明是 chunk 表。** `proof/gen.py` 用 `tools/monitor/chunks.py` 的機制，與 `exp238`、`exp239` 同；開機與定義是 `exp236` 證明的文字，換掉 PMP 值並把位址往後移（`shift`）。處理常式每個 chunk 帶 `Frame`，所以「除了 monitor 自己的堆疊字與回報字，記憶體每個位元組都是負載留下的」是定理（`monitor_traps`），Code 區在整輪之後不變因此也是定理。

## 六、綜合結論：對 `monitor.bin` 標準版之最終修正建議

透過將 `exp228`、`exp223` 與 `exp225` 三個實驗納入規劃，我們清楚界定出目前 `exp236/exp237` 的初版 `monitor.bin` 邁向「通用硬體錢包安全微核心」所需完成的四項核心演進：

1. **從單向停機升級為雙向受檢 Syscall 分發（由 `exp238` 驗證）**：
   補齊 `t0 = 0/2 (HASH)` 與 `t0 = 3 (CHECKSIG)` 的無溢位 PMP 邊界檢查與 `mepc + 4` 返回路徑，正式實例化 Phase 2 的 `MonitorImplementsEnv` 介面。
2. **從暫存器清零升級為涵蓋敏感 SRAM 的退場清零（由 `exp239` 驗證）**：
   在 `scrub_exit` 與 `handle_fault` 中加入對私密工作區 SRAM 的強制歸零，並對非零退出碼（`a0 != 0`）強制清空輸出緩衝區，落實特權級 Fail-Closed。
3. **從單一 RWX 沙盒升級為多條目 W^X + Guard Page 佈局（由 `exp240` 驗證）**：
   善用 `pmpcfg0` 的 4 個條目槽位，將 Code（`RX`）、Data（`RW`）與 Stack（`RW`）分離，由硬體直接保證執行期間代碼絕對不可篡改。
4. **保持極簡形式化驗證基底（Minimal TCB）**：
   上述三項升級合計僅增加約 45–60 條 `RV32I + Zicsr` 指令，完整版 `monitor.bin` 總體積仍可嚴格控制在 **200 條指令（800 bytes）以內**，完全維持在 Lean 4 符號執行可於數秒內完成全路徑定理證明的安全邊界內。

   **修正（2026-10-17）**：此估計不成立。`exp238` 單獨就用滿 200 字，其 Lean 檢查約需數分鐘、突變檢查約半小時，而非數秒。`exp239` 改從 `exp236` 分支，自己在預算內，見第四節第 4 小節；`exp240` 同樣從 `exp236` 分支，只多 8 字，見第五節第 4 小節。

