# `exp245-the-bytes-the-proof-blesses` 詳細實驗設計計畫

<!-- SPDX-License-Identifier: Apache-2.0 -->

* **文件日期**：2026-10-21
* **實驗編號與名稱**：`exp245-the-bytes-the-proof-blesses`
* **實驗狀態**：設計規劃完成（Scaffold / TODO，目前先不實作程式碼與證明）
* **Needs 等級**：`0 · none`（純雲端驗證：RISC-V 組譯器、Lean 4.34.0 定理證明器、`tools/monitor/emulator.py` 特權模擬器與 Python 攻擊驗證套件）
* **前置基礎**：
  * [`exp235-the-boundary-the-proof-bridges`](../exp235-the-boundary-the-proof-bridges/)（Hazard3 特權模型 `PrivMachine` 與 PMP 語意）
  * [`exp236-the-wall-the-monitor-holds`](../exp236-the-wall-the-monitor-holds/)（143 字基礎 M-mode Monitor）
  * [`exp238-the-call-the-monitor-checks`](../exp238-the-call-the-monitor-checks/)（雙向 `ecall` 與服務埠記憶體模型）
  * [`exp239-the-scratch-the-monitor-scrubs`](../exp239-the-scratch-the-monitor-scrubs/)（退場 SRAM 清零迴圈與歸納引理）
  * [`exp240-the-code-the-box-forbids-writing`](../exp240-the-code-the-box-forbids-writing/)（多條目 PMP 優先序與 W^X 定理）

---

## 一、實驗目標與核心命題

本實驗旨在展示並解剖**「形式化驗證的邊界（Boundaries of Formal Verification）」**與**「規格漏洞 / 驗證劇場（Specification Bugs & Verification Theater）」**。

我們以 `exp236` 的 M-mode Monitor 為基底，設計一份 **約 185 個字組（740 bytes）的 `monitor.S`（組譯為 `monitor.bin`）**，在其中植入**四組「數位綠乖乖 / IT 安全御守」位元組（Three Structural Charms + One Literal IT Omamori）**。這四組位元組同時滿足看似矛盾的兩面：

1. **形式化驗證面（100% 通過且受突變測試保護）**：
   * 每一組位元組都在 CPU 上實際執行（計入步驟與週期）。
   * 每一組位元組都在 `proof/Bless.lean` 中擁有無 `sorryAx`、僅依賴 Lean 標準公理的形式化定理。
   * 每一組位元組都受 `proof/mutants.txt` 保護：只要竄改其中任何一條指令或常數，Lean 4 就會拒絕該證明。
2. **實際安全面（0% 防禦作用，純屬心理安慰）**：
   * 在 `suite/charms_audit.py` 的模擬器測試中，四支針對性的攻擊 Payload 在**不違反任何一條 Lean 定理**的前提下，直接改寫自身機器碼、竊取殘留私鑰、偽造驗章通過，並讓神田明神御守封印依然顯示「完好無損」。
   * 把這四組「御守位元組」從 `monitor.S` 中整塊移除（換成基礎版 `exp236`），系統對所有真實攻擊的防禦能力**完全沒有下降**。

---

## 二、記憶體佈局與 CSR 配置設計

本實驗沿用 `exp236`–`exp240` 的模型位址空間（`monRegion = [0x80000000, 0xC0000100)`）：

```text
0x80000000 .. 0x80000300  M-mode Monitor 機器碼 (monitor.bin, ~185 words)
0x80008000 .. 0x8000800f  M-mode Trap Stack（保存 U-mode 的 t0..t3）
0x80008010 .. 0x80008017  [Charm 1] 神田明神／綠乖乖神龕（Altar Words）：
                            0x80008010: 0x4F4D414D ("OMAM" — Omamori)
                            0x80008014: 0x4B554149 ("KUAI" — 乖乖)

0x80010000 .. 0x80020000  U-mode 64 KiB 沙盒（PMP Entry 0: NAPOT 64 KiB, RWX = 0x1f）
  0x80010000 .. 0x80010080  [Charm 2] Payload 代碼區（128 bytes）
                            （PMP Entry 1 設為 RX = 0x1d，但被 Entry 0 的 RWX 遮蔽！）
  0x80012180 .. 0x800121a0  [Charm 3] 法定神聖金鑰槽（Sacred Key Slot, 32 bytes）
                            （退場時由 Monitor 迴圈強制清零，但 Payload 根本不用這裡！）
  0x8001ffc0 .. 0x80020000  Payload 實際工作堆疊頂端（Actual Secret Stack, 64 bytes）
                            （sp 從 0x80020000 往下長，Payload 私鑰實際存放於此，退場不清除）

0xc0000004                Testbench Print Port（回報 TAG_HALT / TAG_FAULT / TAG_BLES）
0xc0000008                Testbench Exit Port（停機退場碼 a0）
0xc0000010 .. 0xc000001c  [Charm 4] Service Port（0xc0000010: ptr, 0xc000001c: cmd / status）
```

---

## 三、四組「御守位元組」的組語設計與規格漏洞解剖

### Charm 1：Literal「IT 御守位元組」—— 神田明神／綠乖乖封印（The Shrine Seal）

* **植入的位元組（共 12 個字組 / 48 bytes）**：
  1. **開機安座（`_reset` 新增 5 字組）**：
     ```asm
     li    t0, 0x80008010
     li    t1, 0x4f4d414d        // "OMAM" (IT情報安全守護)
     sw    t1, 0(t0)
     li    t1, 0x4b554149        // "KUAI" (綠色乖乖)
     sw    t1, 4(t0)
     ```
  2. **退場驗印（`handle_halt` 前新增 7 字組）**：
     當 U-mode 發出 `ecall (t0 = 1)` 請求正常 `HALT` 時，Monitor 先去檢查神龕裡的兩個字組是否仍是 `"OMAM"` 與 `"KUAI"`；只要任一 bit 被動過，立刻跳轉 `handle_fault`（強制將 `a0` 設為 `1` 並報錯）：
     ```asm
     li    t2, 0x80008010
     lw    t0, 0(t2)
     li    t1, 0x4f4d414d
     bne   t0, t1, handle_fault
     lw    t0, 4(t2)
     li    t1, 0x4b554149
     bne   t0, t1, handle_fault
     ```
* **Lean 4 證明的御守定理**：
  * `shrine_blessed_at_boot`：開機 58 步進入 U-mode 時，`mem[0x80008010..0x80008018]` 恆等於 `"OMAMKUAI"`。
  * `halt_requires_intact_omamori`：從 `trap_handler` 出發，若最終以 `TAG_HALT` 回報成功，則陷阱發生瞬間 `mem[0x80008010..0x80008018]` 必定完好無損等於 `"OMAMKUAI"`；反之若該區域任一位元組遭竄改，機器必定進入 `handle_fault` 並以 `a0 = 1` 停機。
* **為何是心理安慰劑**：
  `0x80008010` 位於 M-mode 專屬記憶體（在 `[0x80010000, 0x80020000)` 沙盒之外）。根據 `umode_run` 定理，U-mode 程式**本來就無法改寫沙盒外的任何一個位元組**（一寫就會直接觸發 PMP Store Fault `mcause = 7`，根本走不到 `handle_halt`）。換言之，`handle_halt` 裡那 7 條驗印指令永遠只會走 `beq` 分支；它檢查的是一個「在硬體架構下恆真」的條件，對沙盒內部的資料完整性毫無貢獻。

---

### Charm 2：硬體層御守 —— 被 `Entry 0` 遮蔽的 PMP 唯讀鐵壁（The Shadowed PMP Wall）

* **植入的位元組（`_reset` 新增 3 個字組 / 12 bytes）**：
  在 `exp236` 設定 `pmpaddr0 = 0x20005fff`（64 KiB 全沙盒）之後，額外設定 `pmpaddr1 = 0x2000400f`（對應代碼區 `[0x80010000, 0x80010080)`，128 bytes），並將 `pmpcfg0` 寫為 `0x00001d1f`（`Entry 0 = 0x1f [NAPOT, RWX]`, `Entry 1 = 0x1d [NAPOT, RX, !W]`）：
  ```asm
  li    t0, 0x20005fff          // Entry 0: [0x80010000, 0x80020000) 64 KiB
  csrw  pmpaddr0, t0
  li    t0, 0x2000400f          // [Charm 2] Entry 1: [0x80010000, 0x80010080) 128 B code guard
  csrw  pmpaddr1, t0
  li    t0, 0x00001d1f          // Entry 0 = RWX (0x1f), Entry 1 = RX !W (0x1d)
  csrw  pmpcfg0, t0
  ```
* **Lean 4 證明的御守定理**：
  * `code_guard_entry_configured`：開機後 CSR 狀態滿足 `s.csrs.pmpaddr1 = 0x2000400f` 且 `pmpEntryCfg s.csrs.pmpcfg0 1 = 0x1d`（`W = 0`）。
  * `entry1_forbids_code_store`：對任意落在代碼區 `0x80010000 ≤ addr ∧ addr + width ≤ 0x80010080` 的寫入存取，單一條目檢查函數證明禁止寫入：
    $$\text{pmpEntryMatch}(s.\text{csrs}, 1, \text{addr}, \text{width}) = \text{some } \text{false}$$
* **為何是心理安慰劑**：
  RISC-V 特權規範與 [`lean/Rv32/Priv.lean`](../../lean/Rv32/Priv.lean) 的 `pmpCheck` 定義皆採**「編號最小且命中的條目決定權限（Priority Order: Entry 0 before Entry 1）」**。
  在 `exp240` 中，窄的代碼區放在 `Entry 0`，寬的資料區放在 `Entry 1`，所以 W^X 成立；而在本實驗的 Charm 2 中，寬的 `64 KiB RWX` 放在 `Entry 0`，窄的 `128 B RX` 放在 `Entry 1`。由於 $[0x80010000, 0x80010080) \subset [0x80010000, 0x80020000)$，任何對代碼區的寫入在 `Entry 0` 就已經命中並回傳 `true`（允許寫入）！`Entry 1` 的硬體邏輯在物理上永遠不會被觸發。

---

### Charm 3：記憶體層御守 —— 擦錯神桌的退場清零迴圈（The Ceremonial Scrub）

* **植入的位元組（`scrub_exit` 新增 6 個字組 / 24 bytes）**：
  在 `scrub_exit` 清除暫存器前，加入一段與 `exp239` 結構相同的 3 字組清零迴圈，專門清除沙盒內的「法定神聖金鑰槽」`[0x80012180, 0x800121a0)`（32 bytes，8 個 word）：
  ```asm
  li    t0, 0x80012180          // SACRED_SLOT_LO
  li    t1, 0x800121a0          // SACRED_SLOT_HI (32 bytes)
  scrub_sacred:
  sw    zero, 0(t0)
  addi  t0, t0, 4
  bne   t0, t1, scrub_sacred
  ```
* **Lean 4 證明的御守定理**：
  * `sacred_slot_zeroed_on_exit`：無論 U-mode 是正常 `HALT`、非法呼叫或觸發任何硬體例外，當 Monitor 停機於 `halt_loop` 時，對所有 $a \in [0x80012180, 0x800121a0)$，恆有 $s'.\text{mem}(a) = 0$。
  * `stack_frame_preserved`（包裝成「不破壞記憶體保證」的 Frame 定理）：對所有不在 `[0x80012180, 0x800121a0)` 與 M-mode 堆疊區的沙盒位址 $a$，停機時 $s'.\text{mem}(a) = u.\text{mem}(a)$。
* **為何是心理安慰劑**：
  Monitor 給 U-mode 初始化的堆疊指標是 `sp = 0x80020000`。任何使用堆疊保存秘密（例如將 32-byte 私鑰推入 `0x8001ffc0..0x8001ffe0`）的 Payload 在退場後，Monitor 虔誠地把從未被使用過的 `0x80012180..0x800121a0` 擦成全零，而把真正的私鑰留在 `0x8001ffc0`——而且這件事還被 `stack_frame_preserved` 定理「保證原封不動保留下來」！

---

### Charm 4：系統呼叫層御守 —— 自我回音的驗章橡皮圖章（The Echoed Rubber-Stamp）

* **植入的位元組（`handle_ecall` 與 `call_verify_charm` 新增 16 個字組 / 64 bytes）**：
  新增系統呼叫 `t0 = 4`（`SYS_VERIFY_CHARM`），接收 `a0` 為 32-byte 待驗憑證位址：
  1. 以 `exp238` 的無溢位減法三比較指令，嚴格檢查 `[a0, a0 + 32)` 完全落在 `[0x80010000, 0x80020000)` 沙盒內（越界則跳轉 `handle_fault`）。
  2. 將指標 `a0` 寫入 `0xc0000010`，並將呼叫號碼 `4` 寫入服務埠命令字組 `0xc000001c`。
  3. 從 `0xc000001c` 讀回狀態字組存入 `a0`，並執行「嚴格安全檢查」：**若 `a0 == 0` 則跳轉 `handle_fault` 拒絕退場**；若 `a0 != 0` 則跳轉 `trap_return` 返回 U-mode 繼續執行：
     ```asm
     li    t3, 0xc0000010
     sw    a0, 0(t3)
     li    t0, 4
     sw    t0, 12(t3)            // write request 4 to 0xc000001c
     lw    a0, 12(t3)            // read status from 0xc000001c
     beqz  a0, handle_fault      // [Charm 4] "refuse if verification returned 0!"
     j     trap_return
     ```
* **Lean 4 證明的御守定理**：
  * `verify_charm_bounds_safe`：若 `[a0, a0 + 32)` 越界（含 $2^{32}$ 溢位），機器必定拒絕並停機於 `a0 = 1`。
  * `verify_charm_always_passes`：若 `[a0, a0 + 32)` 在沙盒內，則經過 39 步後，Monitor **必定不會走進 `handle_fault`**，而是以 `a0 = 4`（非零，代表驗證通過）返回 U-mode 的 `mepc + 4`！
* **為何是心理安慰劑**：
  在 `PrivMachine` 的形式化模型中，`0xc000001c` 是普通記憶體（RAM）。前一條指令 `sw t0, 12(t3)` 剛把 `4` 寫進 `0xc000001c`，下一條指令 `lw a0, 12(t3)` 立刻從同一個位址讀出來，讀到的當然永遠是 `4`！後面的 `beqz a0, handle_fault` 在模型裡永遠不會跳轉。即使在模擬器上，若宿主端沒有掛載 `cmd = 4` 的處理器，MMIO 字組同樣保持剛寫入的 `4`。這是一顆經過數學證明「永遠蓋合格章」的橡皮圖章。

---

## 四、檔案結構與驗證矩陣規劃

實驗目錄 `experiments/exp245-the-bytes-the-proof-blesses/` 規劃包含以下檔案：

```text
experiments/exp245-the-bytes-the-proof-blesses/
├── README.md               # 英文實驗說明、定理對照表、預期輸出
├── WHY.zh-TW.md            # 概念討論：神田明神 IT 御守、綠色乖乖與形式化驗證邊界
├── DESIGN.zh-TW.md         # 本設計文件：架構、組語、定理與攻擊套件規格
├── check.sh                # 自動化檢驗腳本（PRESENCE=0）
├── run.sh                  # 錄製 capture.txt 的執行腳本
├── monitor.S               # 含四組御守位元組的 M-mode Monitor 組語（~185 words）
├── monitor.bin             # 組譯出的機器碼映像
├── monitor.sha256          # 映像雜湊值
├── monitor.py              # 組譯與字組一致性檢查工具
├── proof/
│   ├── gen.py              # 使用 tools/monitor/chunks.py 產生 Bless.lean
│   ├── defs.lean           # 四組御守規格定義（ShrineIntact, Entry1Forbids, SacredZeroed...）
│   ├── tail.lean           # 端到端定理與四組御守主定理
│   ├── Bless.lean          # 產生的完整 Lean 4 證明檔案
│   └── mutants.txt         # 16 個突變測試（證明 Lean 確實死守著這四組無用位元組）
└── suite/
    └── charms_audit.py     # 四幕對照測試：每一幕同時驗證「定理條件成立」與「攻擊成功得逞」
```

### 1. 突變測試規劃（`proof/mutants.txt`）

為了證明這四組位元組不是因為「定理沒寫到」才沒用，而是**「定理緊緊盯著它們，它們卻還是沒用」**，`mutants.txt` 將設計 16 個變異體，確認 Lean 全部拒絕：

* **針對 Charm 1（IT 御守封印）**：
  1. `omamori_word0_typo`：將 `"OMAM"` 改為 `"OMAN"` → Lean 在 `shrine_blessed_at_boot` 拒絕。
  2. `kuai_word1_yellow`：將綠色乖乖 `"KUAI"` 改為黃色乖乖 `"YELL"` → Lean 拒絕。
  3. `shrine_check_skipped`：`handle_halt` 跳過神龕檢查 → Lean 在 `halt_requires_intact_omamori` 拒絕。
  4. `shrine_branch_inverted`：神龕相符時反而跳去 `handle_fault` → Lean 拒絕。
* **針對 Charm 2（被遮蔽的 PMP Entry 1）**：
  5. `entry1_writable`：將 `Entry 1` 的權限從 `0x1d`（`RX`）改為 `0x1f`（`RWX`） → Lean 在 `entry1_forbids_code_store` 拒絕！
  6. `entry1_window_wrong`：將 `pmpaddr1` 改小為 64 bytes → Lean 在 `code_guard_entry_configured` 拒絕。
  7. `entry1_off`：不啟用 `Entry 1` → Lean 拒絕。
* **針對 Charm 3（擦錯地方的清零迴圈）**：
  8. `sacred_scrub_one_word_short`：只清零 28 bytes 而非 32 bytes → Lean 在 `sacred_slot_zeroed_on_exit` 拒絕。
  9. `sacred_scrub_stores_pointer`：`sw t0, 0(t0)` 而非 `sw zero, 0(t0)` → Lean 拒絕。
  10. `sacred_scrub_skipped_on_fault`：Fault 路徑跳過清零迴圈 → Lean 拒絕。
* **針對 Charm 4（橡皮圖章呼叫）**：
  11. `verify_charm_floor_dropped`：拿掉 `bltu a0, t1, handle_fault` 下界檢查 → Lean 在 `verify_charm_bounds_safe` 拒絕。
  12. `verify_charm_length_by_add`：用加法檢查長度導致溢位繞過 → Lean 拒絕。
  13. `verify_charm_writes_zero`：寫入 `0` 而非 `4` 到服務埠 → Lean 在 `verify_charm_always_passes` 拒絕（因為 `beqz` 會跳去 fault）。

### 2. 模擬器攻擊與除魅對照套件（`suite/charms_audit.py`）

這個 Python 測試套件是本實驗的核心亮點。它對每一組御守執行**「雙重檢驗（Dual Verdict）」**——證明**定理說的每一個字都成立**，同時**攻擊者的目標也完全達成**，最後再對照真正的修復方案（引用 `exp238`、`exp239`、`exp240`）：

| 幕次 | 執行的攻擊 Payload | 定理檢驗結果（Theorem Postcondition） | 真實安全結果（Security Reality） | 對照的真正修復（The Real Fix） |
| :--- | :--- | :--- | :--- | :--- |
| **Act 1**<br>*(Charm 1)* | **惡意篡改沙盒資料並正常退場**：Payload 將沙盒輸出區全部改寫為惡意數值 `0xdeadbeef`，然後呼叫 `HALT 0` | **PASS**：`0x80008010` 依然是 `"OMAMKUAI"`，`TAG_HALT` 正常印出 | **BYPASSED**：神龕在 M-mode 區根本不會髒；御守貼紙完好無損，但沙盒內資料已被任意污染 | 驗證必須針對 Payload 實際計算的輸出關係（如 `exp208` / `exp228`），而非檢查不相干的魔術常數 |
| **Act 2**<br>*(Charm 2)* | **自我修改代碼攻擊（Self-Modifying Code）**：Payload 執行 `sw` 直接把 `0x80010010` 的指令改寫為放入偷渡退場碼 `li a0, 0x42`，並執行它 | **PASS**：`pmpaddr1 = 0x2000400f`、`cfg1 = 0x1d`（`Entry 1` 確實禁止寫入！） | **BYPASSED**：`Entry 0`（64 KiB `RWX`）先命中放行，Payload 成功改寫自身代碼並以 `0x42` 退場 | 如 [`exp240`](../exp240-the-code-the-box-forbids-writing/) 將窄的 `RX` 代碼區放在 **`Entry 0`**，寬的 `RW` 資料區放在 **`Entry 1`**，並證明全域 `wx_code_immutable` |
| **Act 3**<br>*(Charm 3)* | **堆疊私鑰殘留竊取（Stack Secret Theft）**：Payload 在堆疊 `0x8001ffc0` 展開 32-byte 私鑰 `0x5ec7...` 後崩潰退場 | **PASS**：法定金鑰槽 `0x80012180..0x800121a0` 32 bytes 全數為 `0` | **BYPASSED**：32-byte 私鑰原封不動留在 `0x8001ffc0`，下一輪 Payload 啟動直接讀出完整私鑰 | 如 [`exp239`](../exp239-the-scratch-the-monitor-scrubs/) 清零 Payload 實際使用的工作區，或配合 [`exp240`](../exp240-the-code-the-box-forbids-writing/) 限制寫入範圍並將 Stack 納入清零 |
| **Act 4**<br>*(Charm 4)* | **偽造全零簽章呼叫 `VERIFY_CHARM`**：Payload 傳入 32 bytes 垃圾資料呼叫 `ecall (t0 = 4)` | **PASS**：指標在沙盒內，Monitor 檢查 `a0 != 0` 通過，回傳 `a0 = 4` | **BYPASSED**：服務埠只是把請求碼 `4` 當成回傳值讀回來，任何垃圾資料都 100% 驗證通過 | 如 [`exp238`](../exp238-the-call-the-monitor-checks/) 明確分離「Monitor 負責指標範圍檢查」與「Host / 密碼核心（`exp204`–`exp206`）負責計算證明」，不把 MMIO 回音當成驗證 |
| **Act 5**<br>*(Ablation)* | **拔除御守對照（Charm Ablation）**：將 `monitor.bin` 中的 31 個御守字組全部拔除（退回 `exp236`）重跑 23 個標準攻擊與上述 4 幕 | 四條御守定理不再適用 | **IDENTICAL**：23 個標準攻擊一樣全擋下，4 幕漏洞一樣存在——證明那 31 個字組（124 bytes）是純粹的心理安慰劑 | — |

---

## 五、後續實作步驟（待確認啟動實作時執行）

1. 撰寫 `monitor.S` 與 `monitor.py`，確認組譯出 `monitor.bin` 且字組數在預算內（約 185 words ≤ 200 words）。
2. 撰寫 `proof/defs.lean`、`proof/tail.lean` 與 `proof/gen.py`（重用 `tools/monitor/chunks.py`，符合 `duplication.sh --check` 零重複規範）。
3. 執行 `tools/lean/lean.sh check` 與 `tools/lean/lean.sh mutants` 驗證 `Bless.lean` 與 16 個變異體。
4. 撰寫 `suite/charms_audit.py`，在 `tools/monitor/emulator.py` 上執行五幕對照測試。
5. 補齊 `check.sh` 與 `run.sh`，錄製 `capture.txt` 並更新 `README.md` 與 `experiments/README.md` 索引。

