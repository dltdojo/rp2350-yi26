# `exp245-the-bytes-the-proof-blesses` 詳細實驗設計計畫

<!-- SPDX-License-Identifier: Apache-2.0 -->

* **文件日期**：2026-10-21，2026-10-22 依審查改以 exp240 為基底重寫
* **實驗編號與名稱**：`exp245-the-bytes-the-proof-blesses`
* **實驗狀態**：已實作（2026-10-24），實作與本設計的差異見第七節
* **Needs 等級**：`0 · none`（RISC-V 組譯器、Lean 4、`tools/monitor/emulator.py` 與 Python 測試套件）
* **基底**：[`exp240-the-code-the-box-forbids-writing`](../exp240-the-code-the-box-forbids-writing/)——三個 PMP 條目的
  W^X 盒子、只服務 HALT、以及回合模型（`monitor_reentry`、`ready_of_host`、`monitor_rounds`）。
* **其他引用**：
  * [`exp235`](../exp235-the-boundary-the-proof-bridges/)：`lean/Rv32/Priv.lean` 的 `PrivMachine` 與 PMP 語意
  * [`exp236`](../exp236-the-wall-the-monitor-holds/)：最初的 monitor 與 23 個惡意 payload
  * [`exp238`](../exp238-the-call-the-monitor-checks/)：服務埠與「模型讀回自己剛寫的請求」（見 WHY 第四節，這次不實作）
  * [`exp239`](../exp239-the-scratch-the-monitor-scrubs/)：退場清零迴圈，以及它的 frame 定理形狀

本文件裡的字組數是**組譯本文件中的片段**（`llvm-mc -triple=riscv32 -mattr=+zicsr`）量出來的；步數一律不寫，等
`capture.txt` 有了再填。兩者都不是 capture。

---

## 一、命題

在 exp240 的 monitor 裡加入**三組「御守位元組」**。每一組都滿足：

1. **它真的被執行**：在每一回合的開機或退場路徑上，計入步數。
2. **它有自己的定理**（下稱「御守定理」），只依賴 Lean 的標準公理，並受 `proof/mutants.txt` 保護：改掉其中任何一條
   指令或常數，Lean 就拒絕。
3. **它也有一條「揭穿定理」**，同樣在 Lean 裡證明：從 reset 出發的每一回合裡，這組位元組對 payload 能做到的事
   沒有任何影響。

第 3 點是本實驗相對於「寫一個沒用的檢查再拿模擬器打穿它」的差別：**沒用這件事本身也由 Lean 證明**，而不只是
「沒有測試失敗」。模擬器套件（第五節）是同一個主張的第二種讀法，並且多做一件 Lean 做不到的事：在模型之外注入
寫入者，看御守在那時候做了什麼（Act 1b）。

所有「毫無作用」都是相對於 **exp240 的模型與其威脅模型**：一顆核心、U-mode payload、回合之間的 host 寫入。
模型外的寫入者（DMA、另一顆核心、故障注入）不在其中；那正是 Act 1b 要量的東西。

---

## 二、記憶體佈局

exp240 的佈局不變，御守只占用其中未使用的位址：

```text
0x80000000 ..            monitor.bin：exp240 的 151 字組 + 御守 27 字組（估計 178 字組，以組譯結果為準）
0x80008000 .. 0x80008007  M-mode trap stack：trap entry 存 U-mode 的 t0、t1（exp240 的 InStack 涵蓋到 0x8000800f）
0x80008010 .. 0x80008017  [Charm 1] 神龕：0x4D414D4F、0x4941554B —— 以 little-endian 讀出的位元組正好是 "OMAMKUAI"

0x80010000 .. 0x80010080  entry 0  code   R-X  pmpaddr0 0x2000400f  cfg 0x1d
0x80010000 .. 0x80011000  entry 1  data   RW-  pmpaddr1 0x200041ff  cfg 0x1b（code 被 entry 0 先挖走）
  0x80010100 .. 0x80010200  [Charm 2] seed 視窗：entry 3 R--（pmpaddr3 0x2000405f，cfg 0x19），被 entry 1 遮蔽
  0x80010200 .. 0x80010600  exp225 kernel 的 history（exp240 的正常負載）
  0x80010e00 .. 0x80010e20  [Charm 3] 神聖金鑰槽（32 bytes），退場時清零
0x80011000 .. 0x8001f000  守衛區：沒有條目，U-mode 一律被拒
0x8001f000 .. 0x80020000  entry 2  stack  RW-  pmpaddr2 0x20007dff  cfg 0x1b；sp 從 0x80020000 往下長
  0x8001ffc0 .. 0x8001ffe0  Act 3 的 payload 實際放私鑰的地方

0xc0000004 / 0xc0000008   testbench print / exit（模型把它們當記憶體，同 exp240）
```

`pmpcfg0` 從 exp240 的 `0x001b1b1d` 變成 `0x191b1b1d`。上面四個 NAPOT 值和 entry 3 的範圍都已經用
`decodeNapotRange` 的算法核對過（`0x2000405f` → `[0x80010100, 0x80010200)`）。

---

## 三、三組御守

### Charm 1：神龕封印（The Shrine Seal）

**位元組（18 字組）**：開機在設定 `mscratch` 之後寫入神龕（8 字組）；`handle_halt` 在回報 HALT 之前逐字檢查，
不符就跳 `handle_fault`（10 字組）。

```asm
    // _reset：安座
    li    t0, 0x80008010
    li    t1, 0x4d414d4f        // 記憶體讀作 "OMAM"
    sw    t1, 0(t0)
    li    t1, 0x4941554b        // 記憶體讀作 "KUAI"
    sw    t1, 4(t0)

    // handle_halt 開頭：驗印
    li    t2, 0x80008010
    lw    t0, 0(t2)
    li    t1, 0x4d414d4f
    bne   t0, t1, handle_fault
    lw    t0, 4(t2)
    li    t1, 0x4941554b
    bne   t0, t1, handle_fault
```

用 `t2` 沒有問題：退場尾段本來就把 `a0` 以外的暫存器全部清零。

**御守定理**：

* `shrine_set_at_boot`：exp240 的 `monitor_boot` 加一個結論——開機結束時，`0x80008010` 與 `0x80008014` 兩個字組是
  上面兩個常數；`monitor_boot` 原本的「memory untouched」改成「除了神龕之外 untouched」。
* `halt_requires_shrine`：從 trap vector 出發、**任意**機器狀態、`ecall` 且 `t0 = 1` 時：兩字組都相符，就以 HALT
  停機，`a0` 是 payload 的；任一不符，就走 `handle_fault`，`a0 = 1`。

**揭穿定理**：`shrine_always_intact`——從 reset 起的任何回合，在 payload 的第一個 trap 時，神龕仍是兩個常數。證明
只需要 exp240 已有的兩件事：神龕在資料與堆疊條目之外，所以是 `WxFrozen` 的一部分（`wx_run` 保證不變）；而
`shrine_set_at_boot` 在每一回合開機時重寫它（回合之間 `HostWrite` 可以改神龕，但下一次開機會蓋回去）。合起來：
**從 reset 可達的狀態裡，`bne` 永遠不跳**，`halt_requires_shrine` 裡「不符」的那一半只對不可達的狀態成立。

**這一組和 WHY 第三節第 4 點的關係**：`shrine_check_skipped` 這個突變會被 Lean 拒絕，**只因為**
`halt_requires_shrine` 是從任意狀態出發寫的。把同一個突變拿去對照 `shrine_always_intact` 與 exp240 形狀的
`monitor_end_to_end`，結論不會變。突變測試抓不到沒用的位元組，是因為突變只對著御守自己的局部定理跑。

---

### Charm 2：被遮蔽的 PMP 條目（The Shadowed Entry）

**位元組（淨增 2 字組）**：把 exp240 開機時的 `csrw pmpaddr3, zero` 換成寫入 seed 視窗的位址，並把 `pmpcfg0`
的 entry 3 設成 NAPOT、只讀。`pmpaddr3` 要在 `pmpcfg0` 之前寫：

```asm
    li    t0, 0x2000405f        // [Charm 2] entry 3：seed 視窗 [0x80010100, 0x80010200)，256 bytes
    csrw  pmpaddr3, t0
    li    t0, 0x191b1b1d        // entry 0 = 0x1d (R-X)；1、2 = 0x1b (RW-)；3 = 0x19 (R--)
    csrw  pmpcfg0, t0
```

聽起來像保護：exp225 的 kernel 只**讀** `+0x100` 的 seed，seed 是 host 在回合之間寫進來的，payload 不該改它。

**御守定理**：

* `seed_entry_configured`：開機後 `decodePmpCfgByte s.csrs.pmpcfg0 3` 是 NAPOT、`r = true`、`w = false`、
  `x = false`，且 `decodeNapotRange s.csrs.pmpaddr3 = (0x80010100, 0x80010200)`。
* `entry3_forbids_seed_store`：對任何 `0x80010100 ≤ addr` 且 `addr + w ≤ 0x80010200`，

  ```lean
  ∃ cfg, matchPmpEntry s.csrs 3 addr w = .FullMatch cfg ∧ hasPermission cfg .U .Store = false
  ```

  （`Priv.lean` 只有 `matchPmpEntry`、`hasPermission`、`decodePmpCfgByte`、`pmpCheck` 這幾個名字；先前草稿的
  `pmpEntryCheck`、`pmpEntryMatch`、`pmpEntryCfg` 都不存在。）

**揭穿定理**：`pmpCheck_shadowed`，**放在 `lean/Rv32/WxBox.lean`**，因為它和這個 monitor 無關：條目 0–2 如
`WXBoxed`，且 entry 3 的 NAPOT 範圍整個落在 entry 1 之內，那麼對任何 mode、位址、寬度、存取類型，`pmpCheck` 與
「entry 3 關閉」時相同。理由在 `pmpCheckEntries` 的定義裡：任何碰到 entry 3 範圍的存取都碰到 entry 1，而 entry 1
（`FullMatch` 或 `PartialMatch`）先做決定；沒碰到 entry 1 的存取也碰不到 entry 3。

由此 exp240 的整套 `wx_*` 定理原封不動適用，`wx_store_allowed_data` 直接給出：**對 seed 視窗的寫入被允許**。

`WXBoxed` 目前有 `cfg3 : (decodePmpCfgByte s.csrs.pmpcfg0 3).mode = .OFF` 這個欄位，所以實作時要擇一：放寬成
「entry 3 關閉或被遮蔽」，或另外寫一條從遮蔽狀態轉到 `WXBoxed` 的引理。這是本實驗唯一需要動到 `lean/` 的地方。

**前作**：條目順序決定一切，這件事 exp240 已經證過也測過——`mutants.txt` 的 `entries_swapped`、README 的
`pmp_entries_tried_backwards`、`suite/broken_monitors.py` 的「two entries in the wrong order」。本實驗的新東西只有
兩點：條目自己的局部定理**可以**證出來，以及遮蔽本身也是一條可以證明的定理。

**模擬器上的預期（尚未執行）**：exp240 的 `entry_three_on` 只有靠模擬器分辨「PMP 擋下」與「匯流排上沒有記憶體」
才抓得到（exp240 README，"The emulator" 一條）。一個整個落在 entry 1 內的 entry 3，連這個區分都沒有可以抓的；
預期 exp240 的套件分辨不出這份 monitor 與 exp240 的差別。這就是揭穿定理在模擬器上的樣子。

---

### Charm 3：擦錯神桌的清零迴圈（The Ceremonial Scrub）

**位元組（7 字組）**：在 `scrub_exit` 清暫存器之前，以 exp239 的三字組迴圈清零神聖金鑰槽。HALT 與 fault 共用
`scrub_exit`，所以每一種退場都會執行：

```asm
    li    t0, 0x80010e00        // SLOT_LO
    li    t1, 0x80010e20        // SLOT_HI（32 bytes）
scrub_slot:
    sw    zero, 0(t0)
    addi  t0, t0, 4
    bne   t0, t1, scrub_slot
```

**御守定理**：`slot_zeroed_on_exit`——從 `scrub_exit` 出發，不論 `a0`，機器停在 park loop 時：槽內 32 bytes 全為
零，而且**除了 monitor 的堆疊字組、回報字組與槽之外的每一個 byte，都和 payload 離開時一樣**。後半句是 exp240
`monitor_halt` 與 exp239 `monitor_scrub` 原本就有的 frame 形狀。

**揭穿定理**：`stack_reaches_next_round`——把上面的 frame 與 exp240 的 `monitor_reentry`（"memory does [reach the
next round] … and the next payload reads it"）接起來：第 *n* 回合 trap 時堆疊 `[0x8001ffc0, 0x8001ffe0)` 的內容，
就是第 *n+1* 回合 payload 第一條指令看到的內容，前提是回合之間的 host 沒寫那裡。

**誠實的前作關係**：這組御守批評的是 **exp239 自己的定理形狀**。exp239 清的是 exp223 kernel 實際用的 scratch，
它的 frame 同樣說「其他 byte 原樣保留」，而 kernel 不往別處寫秘密，這點是在模擬器上檢查的，沒有證明。exp236 的
`monitor.S` 註解也早就寫明 "memory the payload wrote stays where it is"。所以 exp239 不是這組的修法，它跟這組
有同樣的缺口，只是剛好擦對了地方。

**真正的修法（不在本實驗）**：讓清零範圍涵蓋 U-mode 能寫的所有位址。exp240 讓這個集合可以逐一列出：
`wx_store_ok` 說一次寫入只能整個落在 code 之外、data 或 stack 之內，也就是 `[0x80010080, 0x80011000)` 與
`[0x8001f000, 0x80020000)`。「每一個 U-mode 能寫的 byte 在停機時為零」是一條能寫成定理的陳述，留作後續實驗的題目。

---

## 四、檔案結構

```text
experiments/exp245-the-bytes-the-proof-blesses/
├── README.md               # 英文說明、定理表、Expected output（貼 capture，不預測）
├── WHY.zh-TW.md            # 概念討論
├── DESIGN.zh-TW.md         # 本文件
├── check.sh / run.sh
├── monitor.S               # exp240 的 monitor.S 加三組御守，每組以 [Charm n] 註解標出
├── monitor.bin / monitor.sha256
├── monitor.py              # 用 tools/monitor/asm.py 組譯並核對字組
├── proof/
│   ├── gen.py              # 用 tools/monitor/chunks.py 產生 Bless.lean
│   ├── defs.lean / tail.lean
│   ├── Bless.lean          # 產生的證明；check.sh 若與產生器輸出不同就失敗
│   └── mutants.txt
└── suite/
    └── charms_audit.py     # 第五節的四幕
```

除了 `pmpCheck_shadowed` 進 `lean/Rv32/WxBox.lean` 之外，沒有新的共用程式碼。Act 4 要拿 exp240 的套件來跑，
這需要它們能接受另一份 `monitor.bin`；若做不到，抽到 `tools/monitor/` 的時機就是這一次，不是複製一份
（`experiments/duplication.sh --check`）。

### 突變（`proof/mutants.txt`，Lean 必須全部拒絕）

boot、handler 與條目 0–2 的突變沿用 exp240 的寫法（位址會隨御守字組移動）。以下是御守自己的部分，共 13 個：

| # | label | 改了什麼 | 預期拒絕於 |
| :--- | :--- | :--- | :--- |
| 1 | `shrine_word0_typo` | 開機寫入 `0x4d414d4e` | `shrine_set_at_boot` |
| 2 | `shrine_kuai_yellow` | 驗印時第二個常數改成別的字 | `halt_requires_shrine` |
| 3 | `shrine_check_skipped` | 第一個 `bne` 換成 `nop` | `halt_requires_shrine`（見 Charm 1 末段） |
| 4 | `shrine_branch_inverted` | `bne` 換成 `beq` | `halt_requires_shrine` |
| 5 | `entry3_writable` | entry 3 的 cfg 從 `0x19` 改成 `0x1b` | `entry3_forbids_seed_store` |
| 6 | `entry3_off` | entry 3 的 cfg 改成 `0x00` | `seed_entry_configured` |
| 7 | `entry3_window_escapes` | `pmpaddr3` 指到守衛區 `0x80011000` | `pmpCheck_shadowed` 的前提不成立：entry 3 不再被遮蔽，而是把守衛區打開讓 U-mode 讀 |
| 8 | `slot_one_word_short` | `SLOT_HI` 改成 `0x80010e1c` | `slot_zeroed_on_exit` |
| 9 | `slot_stores_pointer` | `sw t0, 0(t0)` 取代 `sw zero, 0(t0)` | `slot_zeroed_on_exit` |
| 10 | `slot_skipped` | 進入 `scrub_exit` 就跳過迴圈 | `slot_zeroed_on_exit` |
| 11 | `claim_stack_scrubbed` | 定理宣稱停機時堆疊也是零 | 該宣稱本身：Lean 拒絕替這組御守說出它沒做到的事 |
| 12 | `claim_entry3_decides` | 定理宣稱 `pmpCheck` 拒絕寫入 seed 視窗 | 該宣稱本身 |
| 13 | `claim_shrine_reachable` | 定理宣稱某個從 reset 可達的回合會走進驗印失敗的分支 | 該宣稱本身（`shrine_always_intact` 的反面） |

第 11–13 個是「宣稱」的突變：它們說明 Lean 不只死守著這些位元組，也拒絕讓任何人替它們多宣稱一句。

---

## 五、模擬器四幕（`suite/charms_audit.py`）

每一幕同時報兩件事：定理的結論在這次執行裡成立，以及安全上的實際結果。

| 幕 | payload / 操作 | 定理的結論 | 實際結果 | 真正的修法 |
| :--- | :--- | :--- | :--- | :--- |
| **1a** Charm 1 | 改寫自己的整個 data 輸出，然後 HALT 0 | 成立：神龕是 `"OMAMKUAI"`，HALT 照常回報 | **不是攻擊**：payload 改自己的資料本來就是被允許的，也沒有人宣稱過保護它。這一幕展示的是名稱暗示的範圍和實際範圍的差距：「資訊安全封印完好」說的只是 M-mode 的 8 bytes | 若要宣稱輸出可信，定理要直接講輸出跟輸入的關係（如 exp225 的 kernel 定理），不是講不相干的常數 |
| **1b** Charm 1，模型外 | 回合進行中，由套件扮演模型以外的寫入者（DMA、另一顆核心）改掉 `0x80008014` | 不適用：這個寫入者不在模型裡 | **御守有作用**：HALT 變成 FAULT、`a0 = 1`。在晶片上，這 18 個字組是一個 canary | 這是「0% 防禦只在模型內成立」的實證；晶片上有沒有這種寫入者，是威脅模型的問題，不是證明的問題 |
| **2** Charm 2 | 對 `0x80010100` 存一個字組，讀回來，以讀到的值 HALT | 成立：`entry3_forbids_seed_store` 為真 | **寫入成功**：entry 1 先命中並放行；`traps` 裡沒有任何 PMP 拒絕 | 把 seed 條目排在 data 條目**之前**，即 exp240 挖出 code 的同一招；不在本實驗實作 |
| **3** Charm 3 | 第 1 回合：把 32-byte 私鑰推上 `0x8001ffc0` 後 HALT。回合之間 host 只在 data 裡寫一個「模式」byte。第 2 回合：同一份 payload 依模式把 `0x8001ffc0..` 抄到 data 輸出區 | 成立：兩個回合停機時槽都是零 | **私鑰外洩**：第 2 回合的輸出就是第 1 回合的私鑰（code 在回合之間不能被改，`HostWrite` 不允許，所以兩回合是同一份 payload） | 清零範圍 ⊇ U-mode 可寫範圍（見 Charm 3）；不在本實驗實作 |
| **4** 拔除對照 | 從 `monitor.S` 移除三組御守 | 移除後的映像**必須與 exp240 的 `monitor.bin` 逐位元組相同**（`monitor.sha256` 相等），所以 exp240 已證明的定理原封不動適用 | 對兩份映像跑 exp240 的 `wx_attacks.py`、`rounds.py` 與上面的 1a、2、3：結果必須相同。另外也逐一只拔一組，跑同樣的比較 | — |

Act 1b 是本實驗唯一一個御守「贏」的地方，而它贏在模型之外。放進來，是為了讓這份實驗不要犯它要批評的錯：
把「在這個模型和這些測試下沒有作用」說成「沒有作用」。

---

## 六、實作步驟

1. `monitor.S`：從 exp240 的 `monitor.S` 開始，加入三組御守；`monitor.py` 組譯並核對。先做 Act 4 的 SHA-256
   比對，確定拔除後回得去。
2. `lean/Rv32/WxBox.lean`：`pmpCheck_shadowed`，以及讓 `WXBoxed` 接受被遮蔽的 entry 3 的那條引理。
3. `proof/defs.lean`、`proof/tail.lean`、`proof/gen.py`：三組御守定理與三條揭穿定理，以及 exp240 形狀的
   `monitor_boot`、`monitor_halt`、`monitor_end_to_end`、`monitor_rounds`。
4. `tools/lean/lean.sh check` 與 `tools/lean/lean.sh mutants`。
5. `suite/charms_audit.py`：四幕。
6. `check.sh`、`run.sh`、`capture.txt`；README 的定理表、步數與 Expected output 都從 capture 貼上。

---

## 七、實作紀錄（2026-10-24）

做出來的東西大致照本文件，有六處不同。都不改變任何一組御守做的事：

1. **Charm 1 的兩次寫入移到開機 CSR 設定的最後**（`li sp` 之前），不在設定 `mscratch` 之後。原因在證明：同一次
   `simp` 裡「存入記憶體之後再走一步」需要多一層條件改寫，模型的 `psimpH` 一次做不到；把兩次寫入都放在一段執行的
   最後一步，開機就拆成兩段（`monitor_boot_config` 35 步、`monitor_boot_shrine` 3 步）。
2. **`pmpaddr3` 仍在 exp240 原本的位置寫入**，在 `pmpcfg0` 之後。M-mode 不受未上鎖條目限制
   （`pmpCheck_M_unlocked`），先後對 monitor 沒有差別；留在原位，拔除檢查就是一行換一行。
3. **`WXBoxed` 的 entry 3 欄位放寬成 `Entry3Silent`**（關閉，或範圍整個落在 data 條目內），採第三節 Charm 2 的
   第一個選項。exp240 的開機證明改證第一種情況，exp240 的所有 `wx_*` 定理對兩種情況都成立。
4. **`entry3_forbids_seed_store` 多一個前提 `0 < w`**：寬度 0 的存取不碰任何位元組，不是寫入，命題對它不成立。
5. **突變共 68 個**，由 `proof/gen.py` 寫入 `proof/mutants.txt`：御守 13 個（第四節的表，但 `slot_skipped`
   換成 `slot_store_dropped`：迴圈照跑、`sw` 換成 nop。把 slot 的第一個字換成跳過迴圈，Lean 在這個突變上記憶體
   用盡，單獨跑也一樣，而崩潰不算拒絕），exp240 的 46 個照原樣，另外 9 個 exp240 的突變因為字組或步數在這裡不同
   （設定字、跳躍位移、HALT 的步數），改寫成這份 monitor 的字組。
6. **共用程式碼**：exp240 的證明產生器搬到 `tools/monitor/wx.py`（exp240 的 `Wx.lean` 逐位元組不變），
   exp239 的清零迴圈模板搬到 `tools/monitor/chunks.py` 的 `zloop`，`Zeroed` 與相關引理搬進
   `lean/Rv32/PrivRun.lean`。第四節說「沒有新的共用程式碼」，實際上第二份出現時就抽取了，依 AGENTS.md。

步數是定理裡的數字（`monitor_boot`、`trapSteps`），Lean 已檢查：開機 71 步；從 trap vector 到 park loop，神龕完好的 HALT 95 步、神龕第一字錯 96 步、
第二字錯 100 步、其他 `ecall` 90 步、其他陷阱 87 步。

