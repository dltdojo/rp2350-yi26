# 稽核：monitor 路線的模擬器判定，哪些有定理撐著

<!-- SPDX-License-Identifier: Apache-2.0 -->

2026-10-23 的稽核，是 [大規模二進位證明的分析](./2026-10-23-1048-verification-at-scale-vs-rv32-bytes-zh-tw.md) 第四節
建議 5「規格從測試來」的第一步。做法是把 exp236、exp238、exp239、exp240 的模擬器套件**實際判定的每一個條件**列出來，
逐條找出 Lean 裡陳述它的定理。目的是在動模型（建議 1、2）之前，先知道模型要改多大範圍，讓它只改一次。

**結論：判定「monitor 對機器狀態做了什麼」的條件，幾乎都有定理撐著；判定「機器對外說了什麼」的條件，沒有一條有。**

- 停機位置、暫存器、`mscratch`、保存字組、monitor 的字組、記憶體 frame、清零範圍、PMP 邊界、呼叫的範圍檢查：都有定理。
- 回報埠寫出的內容、結束碼埠、`mtval`、各類指令的陷阱原因、payload 在 monitor 下算出的結果：都只有模擬器在判定。
- 前一份分析留下的待查項目有了答案：**exp228 的 kernel 把 CHECKSIG 的「非零」當成有效，而 exp238 的模型讀回的是請求碼 3。**
  在模型裡，這個組合會接受任何簽章（G6）。

前兩類缺口有同一個根源：輸出埠被建模成記憶體，同一位址的連續寫入只留下最後一個字組，而 `Frame` 又把埠排除在外。
**所以第二步的模型修改，應該同時處理「讀」（建議 1）和「寫」（把埠的寫入變成事件序列）。**

第二節是讀原始碼與定理陳述得到的，沒有用到板子。第三節的突變則在同一天補上並實際跑過 Lean：29 個新突變全部被拒絕
（初稿寫「本機沒有安裝工具鏈」是錯的：Lean 4.34.0 早已裝在 `tools/lean/` 下，只是不在 PATH 上）。

---

## 進度（2026-10-24 G3 之後）

| # | 狀態 |
| :--- | :--- |
| G1、G2、G7 | **已關閉。** `lean/Rv32/Priv.lean` 把 M-mode 對埠的字組寫入依序記在 `io`；exp236、exp238、exp239、exp240 的定理都陳述 host 聽到的字組（`faultIo`、`haltIo`、`trapIo`、`callIo`），報告標籤、結束碼送錯埠的突變現在都被 Lean 拒絕 |
| G6 | **已關閉。** 埠的讀取回傳 `host io a`，一個定理不加限制的函數；exp238 的 monitor 在讀回答案之後多兩個字，答案不是 0 或 1 就走 fault（`monitor_checksig_bad_answer`），monitor 因此成為 202 字。模擬器上有四種無效回答的攻擊情境與兩個對應的錯誤 monitor |
| G3 | **已關閉，方向與原建議相反。** 查了 Hazard3 原始碼（固定的 commit `8af9929`）：`hdl/hazard3_csr.v` 的 `MTVAL` 分支註明「Hardwired to 0」，`doc/sections/csr.adoc` 也寫「Hardwired to 0.」；exp202 README 早已記下「Hazard3 writes zero on every fault here」。錯的是模擬器，不是模型。現在模型拿掉 `mtval` 欄位、讀出 0、寫入丟棄；模擬器也一樣，出錯位址只留在它自己的 `traps` 紀錄裡，`check_fault` 比對的是那份紀錄。exp240 開機的 `csrw mtval, zero` 因此是什麼都不做的一個字，`mtval_kept` 突變體被 Lean 接受是對的，已移除。exp237 的 fixture 裡兩個 fault 的 `mtval` 從位址變成 0，這才是晶片會印的值 |
| G5 | **對兩組 kernel 與 monitor 關閉。** [exp247](../experiments/exp247-the-remainder-behind-the-wall/)：exp229 的有限體 kernel 當作 exp236 的 payload，從 reset 到停機迴圈證明完畢——kernel 在第 53 + count op 步陷入時 R 是 `(a op b) mod p`，57 步後 monitor 停機，所有暫存器為零，host 聽到的字組恰好是 HALT 報告與結束碼 0。接縫在 `lean/Rv32/Join.lean`：盒子裡的 Tier 1 執行就是 Tier 2 執行，它的 HALT 就是 monitor 定理的起點。「`ecall` 在 Tier 1 是殼層服務、在 Tier 2 是陷阱」這個缺口，由 exp229 本來就通過的常數時間檢查器補上（`Ct.ecalls_halt`：檢查器在每個 `ecall` 都知道 `t0 = 1`），exp229 的證明沒有改動。仍未涵蓋：停機時的 R（定理只到陷入的那一刻）、會呼叫 HASH 或 CHECKSIG 的 kernel（exp238；exp239 的 monitor 只服務 HALT），以及 exp240 的回合。下一組是 exp239 與 exp223，分三輪：第一輪 [exp248](../experiments/exp248-the-samples-the-front-reads/) 把常數時間檢查器擴充成可達性檢查器（出口、盒子中段的程式、`lean/Rv32/Reach.lean`），證明 exp223 的前段在跳到 SHA-256 之前只讀樣本、不寫入、只呼叫 HALT；第二輪 [exp249](../experiments/exp249-the-words-the-hash-touches/) 讓檢查器的抽象值支援兩個計數器與範圍位移、記憶體裡的常數字、數字的 `srli` 與有序比較，證明 exp208 的 SHA-256 在 4096 位元組的訊息上每一步只寫入摘要、H、排程與填充區塊，只讀檢查器算出的範圍，只呼叫 HALT；第三輪 [exp250](../experiments/exp250-the-digest-the-wall-keeps/) 在 SHA-256 的入口把兩者接成 exp223 的一次執行，用 `Reach.step_same`／`run_same` 把 exp223 在 128 KiB 世界裡的定理收窄到 64 KiB 的盒子，再接上 exp247 的橋：從 reset 起，樣本健康時 kernel 在 334284 步內陷入、+0x2140 是樣本的 SHA-256，monitor 以結束碼 0 停機，摘要保留、機密暫存區歸零；樣本不健康時在 17425 步內陷入，monitor 以結束碼 1 停機，暫存區與摘要窗都歸零，其餘位元組與 reset 時相同；兩種情況 host 聽到的字組都恰好是 HALT 報告、計數與結束碼。陷入的確切步數（定理只說在 exp223 的步數之內）只有模擬器說了 |
| G4 | 未處理。第四步先做了兩個 monitor 之間的等價（exp246，exp240 與 exp245） |

## 一、範圍與方法

**判定條件的來源：**

- `tools/monitor/harness.py`：`check_parked`、`check_halt`、`check_fault`，以及 exp239 起的 `ReferenceEmulator`、`run_snapshot`，
  exp240 起的 `reenter`。
- exp236 `cases/{attack,normal}_cases.py`；exp238 `suite/{host,attack_cases,kernel_cases}.py`；exp239
  `suite/{attack_cases,kernel_cases,oracle}.py`；exp240 `suite/{wx_attacks,rounds,oracle}.py`。

**定理的來源：** 各實驗 README 的 *What is proved*，以及 `proof/` 裡定理的實際結論。以結論為準，不以 README 的描述為準；
兩者不一致的地方列在 G1。

**exp235 與 exp237 不在範圍內**：前者沒有 monitor 套件；後者是晶片上的實測，判定的是量測值，不是模型。

---

## 二、判定條件與定理的對照

### 有定理撐著的判定

| 判定（模擬器） | 定理（結論中的哪一項） |
| :--- | :--- |
| 停在 park loop、M-mode（`check_parked`） | `Parked`：`pc` 在 park loop、`halted = false`、`mode = .M` |
| `a0` 是 HALT 的結束碼，或 1 | `Parked … (exitCode u)`；exp239 另有 `exitCode_zero_iff` |
| 其他暫存器全為零 | `Parked`：`∀ r ≠ 10, reg r = 0` |
| `mscratch` 為零、保存的字組為零 | `Parked`；exp238 的 t2、t3 由它自己的 `monitor_halt` 系列陳述 |
| monitor 的字組沒有被改 | `Agree M0 … 0x80000000 <長度>` |
| park 時的記憶體 = payload 留下的，加上規定的清零（exp239 `oracle.check_memory`） | `monitor_scrub`、`Scrubbed`、`monitor_fail_closed_scrub`、`monitor_pass_digest_kept` |
| code 區的位元組與載入時相同（exp240） | `wx_code_immutable`、`monitor_end_to_end` |
| 盒子邊界兩側的存取：允許的照跑，禁止的被 PMP 擋下（exp240 `wx_attacks`） | `wx_fetch_iff`、`wx_store_ok`、`wx_load_ok`、`wx_store_allowed_*`、`wx_no_write_exec` |
| 擋下的是 PMP，不是匯流排（`check_fault` 的 `by == "pmp"`） | 模型裡沒有匯流排，拒絕只可能來自 PMP；盒內 PMP 允許的位址都有 RAM。exp240 的 `entry_three_on` 突變由 `monitor_boot_config` 拒絕 |
| 呼叫的範圍越界就停機、host 沒被問（exp238） | `bounds_ok_iff`、`monitor_*_oob_fault`（十二條）、`ends_refuses`、`SvcSame` |
| 一次呼叫之後暫存器不變、計數器加 2（exp238） | `monitor_hashb_ok`、`monitor_checksig_ok`、`monitor_cycle` 的 `Served` |
| 回合之間沒有暫存器或 CSR 帶到下一回合（exp240 `rounds`） | `monitor_reentry`、`monitor_round_ready`、`monitor_rounds` |
| 回合之間 host 的寫入不破壞 `Ready`（exp240） | `ready_of_host`；突變 `host_may_write_code`、`host_may_lock` |

### 沒有定理撐著的判定（缺口）

| # | 判定（模擬器，出處） | 為什麼沒有定理 | 嚴重度 | 歸屬 |
| :--- | :--- | :--- | :--- | :--- |
| **G1** | HALT／FAULT 回報：`TAG_HALT` 或 `TAG_FAULT`，以及其後的 `a0`、`minstret`、`mcycle` 或 `mcause`、`mepc`、`mtval`、`minstret`（`check_halt`、`check_fault`、exp238 與 exp240 的 `minstret` 精確值、`harness.reported`） | 列印埠 `0xc0000004` 在模型裡是記憶體，五次寫入只留下最後一個字組；`Frame` 排除 `InPorts`，所以連最後一個字組都沒有陳述。回報相關的 chunk 引理只陳述**暫存器**（`t1 = 0xc0000004`、`t0 = 標籤`）。**exp239 與 exp240 的 README 寫 "the report made"，但定理的結論裡沒有這一項** | 高：回報是 monitor 對外唯一的證詞，`minstret` 的精確值也是經由它驗的 | 第二步（埠的寫入改成事件） |
| **G2** | 結束碼埠 `0xc0000008` 的值等於 `a0`（`check_parked` 的 `exit_code`） | 同上：結束碼埠也在 `InPorts` 裡。定理只陳述暫存器 `a0` | 中 | 第二步 |
| **G3** | 存取錯誤的 `mtval` 等於出錯的位址（`check_fault`、exp240 `wx_attacks`） | 模型的陷阱**不寫** `mtval`（`Priv.lean` 第 309 行；exp240 README 已揭露），模擬器會寫。兩份讀法在這裡分歧 | 中：已揭露，但回報裡的 `mtval` 是錯的就沒人知道 | 第二步（陷阱寫入 `mtval`） |
| **G4** | 每一類指令的陷阱原因：U-mode 讀寫 CSR、`mret`、`wfi` 是 2，`ebreak` 是 3，未對齊載入是 4（exp236 23 個 payload、exp240 `wx_attacks`） | 原因由 `Priv.lean` 的 `uModeTrapCause` 定義，但只有 PMP 那幾類有定理。更根本的是，`PrivMachine` **沒有和模擬器交叉執行過**。kernel 路線的 `Machine.lean` 有 `rv32run` 對 riscv-tests 與 Hazard3 RTL（exp202）；monitor 路線的兩份讀法（`Priv.lean` 與 `emulator.py`）出自同一作者，各自只被自己的測試檢查 | 中：兩份讀法若犯同一個錯，不會被發現；若犯不同的錯，也只會在其中一邊出現 | 第二步之外，另立一項：可執行的 `PrivMachine` 對模擬器做差分 |
| **G5** | payload 在 monitor 下算出的結果與「單獨執行」相同：exp236 `normal_cases` 的有限體運算、exp238 `kernel_cases` 的結束碼與整個盒子、exp239 的摘要等於 SHA-256、exp240 `rounds` 的 Rule 30 世代與「盒子 = 單獨執行」 | kernel 的定理（Tier 1，`Machine.lean`）與 monitor 的定理（Tier 2，`PrivMachine`）沒有接起來。`Refinement.lean` 只涵蓋「安全的」指令；`ecall` 在 Tier 1 是殼層服務，在 Tier 2 是陷入 monitor，兩者沒有共同的結束狀態可比（它的檔頭寫明了）。exp240 README 也寫明 "The kernel's correctness is not joined to this proof" | 高：這是整條路線「證明過的 kernel 跑在證明過的 monitor 上」的接縫 | 第四步（等價定理） |
| **G6** | CHECKSIG 之後 `a0` 是 0 或 1（exp238 `attack_cases.py` 第 205 行） | **模型說的是相反的事**：`monitor_checksig_ok` 的結論是 `a0` 為從埠讀回的字組，模型裡就是請求碼 3。而 exp228 的 kernel 在 CHECKSIG 之後是 `beq a0, zero, F_INVALID`（`kernel.py` 第 406 行），**非零即有效**。在 exp238 的模型裡，這個組合接受任何簽章。模擬器上沒事，只因為 `ServiceEmulator` 的 host 一定會回答 0 或 1 | 高：fail-open，而且是在「沒有 host 回答」這個最可能出錯的情況 | 第二步（建議 1：埠的讀取改成參數）；另見第四節的決定 |
| **G7** | host 收到的請求依序是哪些（exp238 `expect_served`、`kernel_cases`） | 每一次呼叫的請求由 `Served` 陳述（埠裡的參數與請求碼），多次呼叫靠 `safe_for` 的歸納串起來。但「請求序列」本身不是任何定理的結論 | 低：每一步都有，只差把它們寫成一條序列 | 第二步（與 G1 同一個事件序列） |

另有一項判定是量測，不該有定理：exp238 `kernel_cases` 把單獨執行的指令數對照 exp228 在 Pico 2 上的實測（模型 + 4 + 每次呼叫 4）。
它是模型與晶片之間的橋，靠的是量測，不是證明。

---

## 三、反方向：被套件抓到、但沒有對應 Lean 突變的錯誤 monitor

每個實驗都有兩組「錯誤版本」：`broken_monitors.py`（模擬器必須抓到）與 `proof/mutants.txt`（Lean 必須拒絕）。依名稱與內容比對，
下列錯誤 monitor 在同一實驗的 `mutants.txt` 裡沒有對應的突變。

**已補上，並跑過 Lean。** 每個突變都是把錯誤 monitor 自己的修改拿來組譯，刪掉的指令換成 `nop` 以維持 `monitorCode` 的長度，
再與 `monitor.bin` 逐字比對得出要改的字組。29 個全部被拒絕：

| 實驗 | 突變數（前 → 後） | 新增的突變 |
| :--- | :--- | :--- |
| exp236 | 18 → 22 | `pmp_window_4gib`、`pmp_window_covers_monitor`、`scrub_skips_ra`、`mscratch_stays`（既有的 `mscratch_wrong` 改的是開機，不是清零） |
| exp238 | 8（另 15 個註解保留） | `hashb_input_ceiling_dropped`、`hashb_length_dropped`、`hashb_output_floor_dropped`、`hashb_output_ceiling_dropped`、`checksig_key_floor_dropped`、`checksig_key_room_dropped`、`checksig_signature_floor_dropped`、`checksig_is_hashb`、`return_skips_two_words`、`return_leaves_t1`、`return_leaves_t3`、`return_keeps_monitor_sp`、`counters_released_one_early`、`scrub_keeps_saved_t3`、`fault_does_not_scrub` |
| exp239 | 30 → 34 | `scratch_starts_early`、`scratch_not_scrubbed`、`digest_window_one_word_long`、`digest_loop_runs_to_scratch_end` |
| exp240 | 47 → 53 | `data_entry_off`、`stack_entry_off`、`stack_entry_32_kib`、`data_tried_before_code`、`scrub_skips_ra`、`mscratch_stays` |

三點修正初稿：

- **exp238 的 8 個是刻意的。** 它的 `mutants.txt` 開頭寫明：14 個突變曾跑過一次、全部被拒，因為每個都要跑完整份證明（約兩分鐘），
  所以只留 8 個在檢查裡。初稿漏看了這段。這次的 15 個也照這個做法：跑過一次（一次兩個，平均每個約 1.9 分鐘），以註解形式記在
  `mutants.txt`，拿掉 `#` 就能放回檢查。全部常駐的話，`check.sh` 每次會多跑約半小時。四個同時跑時有 10 個因記憶體不足而沒有結論，
  這也是 exp238 的 `check.sh` 一次只跑兩個的原因。
- **exp240 那一列初稿寫錯了。** `code_and_data_swapped` 與既有的 `entries_swapped` 是同一個修改（兩個條目的位址對調）；沒有對應突變的
  是 `data_tried_before_code`（位址與權限一起對調）。
- **`counters_released_one_early` 是替身。** exp238 的 `counters_released_early` 與 `extra_instruction_counted` 都會多出一個字組，
  所以改用「`csrwi mcountinhibit, 0` 與前一條指令對調」，計數器同樣多算一條。

**寫不成等長突變的三個**，這次沒有補：

- exp239 的 `scratch_one_word_long`：結束位址要多 4，需要多一條 `addi`。另一端多清一個字的 `scratch_starts_early` 已補上，既有的宣稱突變
  `claim_scratch_one_word_more` 也涵蓋同一件事。
- exp239 的 `halt_with_zero_skips_scratch`：要多插一條 `beqz`。
- exp240 的 `mret_stays_in_m_mode`：要讓 MPP 成為 M-mode 需要兩個字組。既有的 `mstatus_kept` 已涵蓋：開機不完整寫入 `mstatus` 時，
  MPP 可能是上一回合留下的 M-mode。

---

## 四、對第二步的影響

### 第二步的範圍，依這份稽核

1. **埠的寫入改成事件序列**：列印埠與結束碼埠的每一次寫入都記錄下來，而不是覆寫記憶體。這一項同時關掉 G1、G2、G7，
   也是第四步等價定理的「可觀測事件」。
2. **服務埠的讀取改成參數**（建議 1）：比照 kernel 路線的 `env.sig`。這一項關掉 G6 在模型裡的那一半。
3. ~~**陷阱寫入 `mtval`**：讓模型與模擬器一致。~~ **（2026-10-24 更正）** 這條建議是錯的：Hazard3 把 `mtval` 固定為 0，
   要改的是模擬器。見上方進度表的 G3。這份稽核當時沒有先查晶片的原始碼，就把模擬器的讀法當成了基準——正是
   AGENTS.md「先查既有紀錄再下假設」要防的事，而 exp202 的 README 早就寫著答案。
4. **沒有記憶體的位址**（建議 2）：在 exp236–240 的盒子裡沒有造成可見的缺口，因為 PMP 允許的位址都有 RAM。它可以
   排在同一批，但不是這份稽核找到的缺口推出來的。

G4（`PrivMachine` 與模擬器的差分）與 G5（kernel 與 monitor 的接縫）不在第二步：G4 是新的工具，G5 是第四步。

這三項都改 `lean/Rv32/Priv.lean` 的讀寫語意。依賴它的有 `PrivRun`、`Refinement`、`Sandbox`、`WxBox` 四個函式庫檔，以及
exp235、exp236、exp238、exp239、exp240 的證明。

### 決定（2026-10-23）

1. **G6 修在 monitor 一側**：exp238 在讀回答案後檢查 `a0 ∈ {0, 1}`，不是就 fault；exp228 的 kernel 不動。
   **但它必須和第二步「服務埠的讀取改成參數」一起做**，初稿沒有點出這個相依。在現行模型裡，讀回的永遠是剛寫入的請求碼 3，
   所以單獨加上這個檢查，模型裡的 CHECKSIG 會每一次都 fault，定理只能照實寫成「CHECKSIG 永遠失敗」。
2. **README 已改**：exp239、exp240 定理表的 "the report made" 改成「回報的寫入有執行，寫了什麼沒有陳述」，exp236–exp240 四個 README 的
   *What is not proved* 都加了 "The reports are not proved"，指向這份稽核的 G1、G2。第二步把回報納入定理之後再改回來。
3. **突變已補**：見第三節。
