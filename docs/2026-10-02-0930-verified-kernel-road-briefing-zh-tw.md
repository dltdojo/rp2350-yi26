# 機器碼驗證簽章之路：質詢、雲端完成的三個實驗、與板子上的計畫

**快照時間：2026-10-02 09:30 UTC** · 基準 `main` 於 `09743c0` · 本輪工作在 `claude/great-hypatia-ao0oca`

這一份是〈RP2350 機器碼驗證簽章實驗設計〉（2026-10-02，@JOYE LIN）的落地計畫，照
[每個新實驗都從質詢開始](../experiments/README.md#every-new-experiment-starts-with-an-interrogation)
的順序寫成：先確立事實、再查前例、點名矛盾、分開已決定與待決定的事。和以往的簡報不同的是，
它同時也是一輪工作的結算——**不需要晶片、能在雲端驗證的部分，先做完了三個實驗**，
其餘照「雲端先、板子後」排好。

---

## 一句話

**設計文件的「階段 0」在雲端走完了：一份 60 位元組的 RV32IM 機器碼，在 Lean 中證明會拷貝
64 位元組並在第 105 條指令停機（對任意基底位址、任意輸入、任意暫存器），Lean 模型跑出 105，
Hazard3 RTL 退休 108——差的 3 屬於殼層，量得出來、恆定，而且花在規格書說不該計數的地方：
Hazard3 會計 `ecall`、把 `mret` 算兩次，還會因為 `mret` 後面記憶體裡擺了什麼而算出不同的數。**
設計文件裡「實機 `minstret` 等於 Lean 證明的指令數」這個完成條件，因此必須改寫成
「證明數 + 為這份殼層實測的常數」。

---

## 一、確立的事實

全部在雲端 session 裡做，每一項都是跑出來的，不是推測的。

### 工具

| | 結果 |
| --- | --- |
| Lean 4.34.0（repo 既有的 `tools/lean`） | 夠用。**不需要 Mathlib**：暫存器用核心的 `BitVec 32`，編碼在 `Nat` 上算，`omega` 認得所有欄位的上界 |
| `bv_decide`、`native_decide` | 不用：兩者都帶進 `Lean.ofReduceBool`，等於信任編譯器。`tools/lean/lean.sh check` 現在會拒絕它 |
| Hazard3 RTL | `github.com/Wren6991/Hazard3` 固定在 `8af99293`，Verilator 5.020 + clang++ **14 秒**建好，10 MB |
| RISC-V 工具鏈 | Ubuntu 的 `clang` 18 + `lld` + `llvm-objcopy` 就能產生 RV32IM 裸機映像；`llvm-mc`／`llvm-objdump` 用來當獨立的組譯器 |
| 自我檢查的測試集 | Hazard3 自己釘住的 `riscv-tests`（`49a24d7`），rv32ui + rv32um 共 48 個可用 |

### 量到的、文件裡沒有的

- **Ubuntu 的 Verilator + g++ 會被預編譯標頭絆倒**（verilator issue 4730），而且一邊失敗一邊寫出
  **9 GB 的日誌**，把這個 session 的磁碟配額寫滿。改用 clang++、加 `-latomic` 就好。
  已寫進 `tools/hazard3/setup.sh` 的註解。
- **Lean 的 `omega` 不完備**：它不實作 dark shadow，同一個數的多個除法並存時會失敗；
  遇到「和式乘上大的 2 的冪」會撞上無法被 `first` 攔下的遞迴上限。對策（`field`、先分配乘法）
  寫在 exp201 的 README。
- **一次 `simp` 把 Lean 推到 14 GB 被 OOM 殺掉**：幾條指令之後的機器狀態是很大的項。
  對策是每一步用 `obtain` 命名新狀態、只留下小規格。寫在 `Copy64.lean` 的開頭。
- **RP2350 上的 Hazard3 是 v1.0-rc1**（Hazard3 文件給的 `mimpid` 是 `86fc4e3f`），
  模擬的是 2026 年 v1.1 系列的 commit。差異要在板子上才量得到。
- **`yi26` 只收 `rp2350-arm-s` 家族的 UF2**：它認得 `rp2350-riscv`（`0xE48BFF5A`）
  但會拒絕。燒錄 RISC-V 映像前得先改它。

---

## 二、查前例

- **exp198、exp199** 已經建立了這裡用 Lean 的方式：`proof/` 目錄、`cited.txt`、`mutants.txt`、
  `#print axioms`、`tools/lean/lean.sh`。這條路沿用，只多了一件事——證明的對象從
  「轉寫的 Rust」變成「機器碼本身」，所以有了共用函式庫 `lean/Rv32/`。
- **exp195–exp200 的模型路線**證明了「先在模型裡找，再回到真的程式碼」這個迴圈在這裡是便宜的。
  這條路是同一個想法往下推一層：模型是 RISC-V 的語意，程式碼是位元組。
- **這個 repo 至今沒有任何 RISC-V 韌體**。一百個實驗全部是 Arm（`thumbv8m.main-none-eabihf`）
  加 Embassy；頂層 README 也寫著「Start on Arm」。板子上的殼層是第一份 RISC-V 韌體，
  `crates/` 裡依賴 embassy 的部分（7 個）能不能用，要先編譯看看。

---

## 三、矛盾

設計文件寫得很完整；下面是照字面做會出錯的地方。

1. **「實機 `minstret` 等於 Lean 證明的指令數」做不到相等。** 殼層進入核心的 `mret`、
   以及 trap 進來後關掉計數的那條指令，一定會被算到。量下來還更糟：Hazard3 會計 `ecall`
   （規格書：「not considered to retire, and should not increment the `minstret` CSR」），
   `mret` 計 2，同樣四條指令會因為 `mret` 後面的記憶體內容不同而算成 5 或 4。
   → **改為**：證明數 + 殼層常數，常數為每份殼層程式碼實測；每條普通指令恰好計 1 由掃描驗證。
2. **riscv-arch-test 需要 Sail 產生的參考簽章。** 那是比這裡任何東西都大的信任對象和安裝。
   → **改為**：自我檢查的 riscv-tests（不需要參考模型），再用 Hazard3 RTL 比對整塊記憶體補強。
3. **模擬器與晶片的 SRAM 位址不同**（測試平台 `0x80010000`，晶片 `0x20070000`）。
   照文件「殼層以固定位址載入」，核心就會是兩份不同的 binary，雜湊對不上。
   → **改為**：核心用 `auipc` 找自己的位置；定理對**任意**基底成立。
4. **「riscv-arch-test 通過」不代表模型對。** exp202 用 14 個錯誤模型去測，
   套件放過了 4 個：`jalr` 清最低位元、未對齊存取、區域外的寫入與取指令——
   正好是核心證明最倚賴的行為。→ 每個盲點補一支探針程式。
5. **Lean + Mathlib**：實測不需要 Mathlib。→ 只用核心 Lean，少一個 2 GB 的信任對象。
6. **獨立 repo 結構**（`rp2350-verified-sig/lean/…`）：這裡已有 `tools/lean`、
   `experiments/` 的慣例、`docs-check.sh` 的棘輪。→ 實驗照常放 `experiments/exp2NN-*`，
   共用的 Lean 放 `lean/`（Rust 放 `crates/`、Python/shell 放 `tools/`，Lean 放 `lean/`），
   RTL 工具放 `tools/hazard3/`。
7. **「HASH 輸入長度為 64 的倍數」與 Lamport 的 32 位元組原像不合。** 需要在 exp204 定一個
   填充規則，並且兩邊（Lean 的 HASH 抽象、殼層的 handler）照同一份規則。

---

## 四、分開已決定與待決定

**已決定**（理由見上）：雲端先做；用 riscv-tests 不用 riscv-arch-test；不用 Mathlib；
位置無關核心；`lean/` 為共用 Lean 函式庫；計數比對改為「證明數 + 實測常數」；
模型刻意比晶片嚴格（`fence`、`ebreak`、CSR、跳到 2 mod 4 的位址一律視為錯誤）。

**待決定**（不同答案代表實質不同的工作，列在第八節）。

---

## 五、已完成（雲端，Needs 0）

| 實驗 | 主張 | 狀態 |
| --- | --- | --- |
| [exp201](../experiments/exp201-one-word-one-reading/) | Lean 的 RV32IM 編碼器／解碼器雙向一致：每條指令往返不變，且不是編碼的字組一律不解碼——**一個字組只有一種讀法**。LLVM 同意 3,450 條指令與 5,572 個字組；兩個「兩邊一起錯」的版本 Lean 證明擋不住，LLVM 立刻擋下 | 已提交、已錄製 |
| [exp202](../experiments/exp202-the-tests-the-chip-passes/) | Lean 語意模型通過 48 個 riscv-tests；Hazard3 RTL 用同樣的位元組也通過；53 支程式之後兩者 64 KiB 記憶體逐位元組相同。14 個錯誤模型全被擋下，其中 4 個只有自寫的探針擋得住 | 已提交、已錄製 |
| [exp203](../experiments/exp203-the-count-the-proof-promised/) | 60 位元組的拷貝核心，證明正確且恰好 105 條指令；`kernel.bin` 與 SHA-256 已提交；RTL 退休 108，差的 3 逐條拆解 | 已提交、已錄製 |
| [exp204](../experiments/exp204-the-signature-the-kernel-checks/) | 352 位元組的 Lamport verify 核心：對**任何** HASH 函數，簽章全對回 0、任一錯回 1，無論結果都恰好 16663 條指令，只寫 96 位元組暫存區。模型、RTL、Python 在 10 個案例上判決一致、記憶體逐位元組相同。每次 HASH 在 RTL 上多計 4；最後一個 `ecall` 後面那個不會執行的字組也會讓計數差 1 | 已提交、已錄製 |
| [exp206](../experiments/exp206-the-root-the-path-climbs/) | 752 位元組的 MSS（WOTS + 樹高 4 的 Merkle）verify 核心：對**任何** HASH 證明判決正確，恰好 `3295 + 3·S` 條指令，只寫兩塊工作區；完整性證明到 binary——參考實作簽出的任一葉簽章，核心一定回 0。前 69 條指令就是 exp205 的，證明移入 `lean/Rv32/Wots.lean`，exp205 改用它而 `kernel.bin` 一位元組不變。模型、RTL、Python 在 29 個案例上一致 | 已提交、已錄製 |
| [exp205](../experiments/exp205-the-chain-the-checksum-closes/) | 432 位元組的 WOTS（w = 16）verify 核心：67 條雜湊鏈（後 3 條是 checksum 的），對**任何** HASH 函數證明判決正確，且恰好 `4142 + 3·S` 條指令（S 是 HASH 呼叫次數）——第一個指令數隨輸入而變的核心，所以定理把它寫成公式。模型、RTL、Python 在 11 個案例（S 從 45 到 990）上一致，RTL 多出的正好是 `3 + 4·S` | 已提交、已錄製 |

**板子上跑過的**：[exp209](../experiments/exp209-the-count-the-led-blinks/)——Pico 2 的 RISC-V 殼層（組語＋C，全在 flash 第 0 磁區），直接沿用 RTL 的 `harness.S` 跑 exp203 的核心，六項自我檢查，用 LED 閃出 `minstret`。RTL 上同一個殼層六項全過、計數 108；UF2 用 `absolute` 家族，不必先改 `yi26`。板子第一次執行閃出「2 次長閃，1-0-8」：核心停機，晶片計數 **108，與 RTL 相同**；但 PMP entry 0 讀回值與寫入不同（RTL 上沒有這個現象）。第二版試圖閃出四個數字，人眼無法可靠判讀（使用者原話已記錄）；第三版改成晶片上自行比對、LED 只給一個位元——**板子回報「慢閃」：全部吻合**。證明過的核心在晶片上停機、結果 0、拷貝正確、64 KiB 記憶體與 Lean 模型逐位元組相同、`minstret` = 108 與 RTL 相同。

[exp210](../experiments/exp210-the-hash-the-chip-computes/)：exp204（Lamport）與 exp205（WOTS）的核心在 Pico 2 上執行，HASH 交給 RP2350 的 SHA-256 加速器；21 個案例放在同一個 UF2，殼層移到 `tools/hazard3/shell/` 共用（exp209 的 UF2 仍逐位元組相同）。**板子回報「慢閃」：全部吻合**——加速器回答的 8,155 次 HASH 與模型的 SHA-256 一致，21 個區域與 Lean 模型逐位元組相同，每個案例的 `minstret` 都等於 RTL 的 `count + 3 + 4·S`，連進出殼層的 trap 也一樣計數。三方（Lean、RTL、晶片）一致。

新增的共用部分：`lean/Rv32/`（`Isa`、`Machine`、`Load`、`Asm`、`Proof`、`Place`、`Kernel`、`Blocks`）、`lean/Run.lean`
（模型編譯成 `rv32run`，記憶體改用陣列）、`lean/Sha256.lean`（只供執行）、`tools/hazard3/`（`setup.sh`、`sim.sh`、harness）、
`tools/lean/lean.sh` 能檢查引用函式庫的證明、能讓 mutant 改函式庫本身。

---

## 六、接下來：雲端還能做的（Needs 0）

照設計文件的階段 1–4。每一個都是「Lean 證明 + Lean 模型執行 + RTL 執行 + Python 獨立參考」，
缺的只有晶片。

| 編號（暫定） | 內容 | 新增的證明重點 | 雲端完成條件 |
| --- | --- | --- | --- |
| exp206 | **MSS（WOTS + Merkle，樹高 4）verify**——**已完成**：752 位元組的核心，證明對任何輸入、任何 HASH 判決正確、恰好 `3295 + 3·S` 條指令；完整性在參考實作層證明並傳到 verify 的 binary（任一葉的簽章都被接受）。前 69 條指令與 exp205 相同，證明移到 `lean/Rv32/Wots.lean` 兩邊共用 | 驗證路徑、葉節點索引；**完整性** | 已完成：16 個葉全部驗證成功，另 13 個案例，模型／RTL／Python 一致 |
| exp213 | **MSS keygen／sign 核心**（由 exp206 拆出，使用者決定）——**已完成**：keygen 432 位元組，對任何種子恰好 76456 條指令寫出整棵樹；sign 620 位元組，恰好 `2284 + 3·Σdᵢ` 條指令，把簽章、路徑、根寫在 exp206 verify 讀的位置；一條定理 `three_binaries` 把三個 binary 串起來：verify 停在 0。exp206 的證明移進 `lean/Rv32/Mss.lean` 讓這條定理接得到 | 簽章與金鑰產生也是 binary：keygen → sign → verify 三個 binary 串起來一定接受；秘密金鑰由種子以 HASH 推導（使用者決定） | 已完成：兩個核心各自的案例模型／RTL／Python 一致；三個 binary 依序執行，在模型與 RTL 上都被接受 |
| exp207 | **常數時間** | sign 與 keygen 的「兩次執行」關係型證明：公開輸入相同、秘密不同 → PC 序列與存取位址序列相同 | 證明通過；RTL 上不同秘密金鑰的 `mcycle` 完全相同（exp203 已看到 113 個週期與資料無關，但那是觀察，不是定理） |
| exp208 | **（選做）RV32IM 的 SHA-256 壓縮函數**，證明符合 Lean 寫的 SHA-256 規格 | 取代加速器後，HASH 不再是抽象 | 前面的證明換上具體雜湊後仍成立 |

---

## 七、需要晶片的（照 Needs 排序）

| 編號（暫定） | 內容 | Needs | 雲端能先做的半邊 |
| --- | --- | --- | --- |
| exp209 | **晶片上的殼層**：RP2350 以 RISC-V 模式開機；Rust 殼層（`rp235x-hal`，`riscv32imac-unknown-none-elf`）把 `kernel.bin` 複製到 `0x20070000`，用 SHA-256 加速器算雜湊並與 `kernel.sha256` 比對，設 PMP、`mret` 進 User、處理 `ecall`，USB 回報 `minstret`／`mcycle`。跑 exp203 的核心：**晶片上的計數是不是也是 108？** | 1（若殼層實作 1200 baud 重開機）／2（否則每次燒錄要按 BOOTSEL） | 殼層編譯、UF2 家族 `rp2350-riscv`、`yi26` 接受 RISC-V UF2、harness 的行為在 RTL 上先對過 |
| exp210 | **三方一致**：exp204／205 的核心在晶片上用加速器當 HASH；Lean、RTL、晶片三方記憶體逐位元組相同；每次 HASH 呼叫的計數成本在晶片上重量。一個 UF2 跑 21 個案例，晶片上逐案比對模型的判決與整塊區域、RTL 的 `minstret`，LED 只給一個位元。沒有 USB，所以 Needs 是 3 而不是原訂的 1。**板子回報「慢閃」：21 個案例全部吻合** | 3 | 已完成 |
| exp211 | **不能倒退的計數器**：MSS 計數器存在 flash，由殼層管理；斷電、重燒韌體後觀察是否倒退；第 17 次簽章必須被殼層拒絕 | 2（要有人拔電） | 計數器的 flash 配置與原子寫入可以先用模型（像 exp197 的 P4）檢查 |
| exp212 | **晶片上的時間**：不同秘密金鑰下 `mcycle` 的分佈；GPIO 翻轉 + 邏輯分析儀 | `mcycle` 半邊 1；邏輯分析儀半邊 3，而且**多一項硬體需求**，與 repo「一塊板子一條線」的前提不同，要先決定 | 無 |

設計文件的「延伸（故障注入）」不排入：不在主線、需要額外硬體，而且 RP2350 有硬體 glitch 偵測器，
要觀察就得刻意繞過它，這超出這個 repo 的範圍。

---

## 八、問題（請決定）

1. **exp204 的 HASH 填充規則。**（已採 (a)，exp204） Lamport 的原像是 32 位元組，介面要求 64 的倍數。
   - (a) **推薦**：原像補 32 個零到 64 位元組再雜湊——規則最簡單，Lean、C、Python 三邊都好寫；
   - (b) 放寬介面為「任意長度」，由 handler 做 SHA-256 標準填充——貼近加速器，但 Lean 的 HASH 抽象要多帶長度。
2. **板子上的殼層要不要第一版就做 1200 baud 重開機？** 做了 exp209 是 Needs 1（沒人也能燒錄），
   但殼層變大，信任基礎多一塊 USB 堆疊；不做是 Needs 2，殼層保持最小。**推薦**：先不做，
   USB 只用來回報；重開機留到 exp210 再加，並在那時量它對 `minstret` 常數的影響。
   **（exp210 決定：不加。）** 讀 LED 一定要有人在場，加了 USB 也省不掉人；而 C 寫的殼層若加 USB 堆疊，
   信任基礎會大好幾倍。exp210 和 exp209 一樣只用 LED，Needs 3。
3. **exp212 的邏輯分析儀**：要不要把「多一項硬體」納入？**推薦**：只做 `mcycle` 半邊，
   邏輯分析儀列為選做。
4. **雲端的 exp204–208 要不要一路做下去**，還是先停在這裡、等板子把 exp209 的計數問題回答了再說？
   **推薦**：先做 exp204（第一個 HASH 呼叫，也是第一次量 HASH 的計數成本），
   exp205 之後的證明工作量最大，可以等 exp209 確認晶片與 RTL 的計數一致再投入。

---

## 九、設計文件「待確認事項」的現況

| 待確認 | 現況 |
| --- | --- |
| RP2350 上 Hazard3 的 PMP 區域數與比對模式 | RTL 的預設組態（依 Hazard3 README 即 RP2350 的組態，另加 Zbc）有 4 個區域、TOR 與 NAPOT 都支援；harness 用 NAPOT 一個區域。**晶片上（exp209）**：entry 0 讀回值與寫入不同，但核心仍在 User mode 受限執行並停機；原因未查 |
| `minstret`、`mcycle` 的存取與 `mcountinhibit` | RTL 上已回答：寫 `mcountinhibit` 的指令，開始計數那條不算、停止計數那條算；`mret` 計 2；`ecall` 會計；結果與記憶體位置有關（exp203）。**晶片上（exp209）**：同一份殼層下 `minstret` = 108，與 RTL 相同（v1.0-rc1） |
| SHA-256 加速器的暫存器介面，trap handler 中同步使用的限制 | exp210 依 rp-pac 寫好驅動（`START`、`BSWAP`、逐字等 `WDATA_RDY`、補位由軟體做一整個區塊、等 `SUM_VLD`），在 trap handler 裡同步使用、不用 DMA；雲端對照依資料手冊寫的假周邊測試；**晶片上已執行（exp210 慢閃）**，驅動對加速器的理解正確 |
| `rp235x-hal` 在 RISC-V 模式下的中斷支援 | 核心不需要中斷；殼層進核心前關掉。殼層自己是否需要中斷（USB）在 exp209 建置時確認 |
| Embassy 是否支援 RP2350 的 RISC-V 模式 | 未處理；exp209 的第一步就是在雲端編譯看看 |
| 可借用的 Lean RISC-V 語意 | 沒有借：自己寫的 `lean/Rv32`（語意 `Machine.lean` 264 行、編碼 `Isa.lean` 的定義部分約 250 行，皆含註解），以 LLVM（exp201）、riscv-tests 與 RTL（exp202）檢驗。借 Sail 的 Lean 輸出會帶進一個比整個實驗還大的信任對象 |
