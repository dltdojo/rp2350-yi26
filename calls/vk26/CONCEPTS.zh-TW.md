# 被證明的核心：從組合語言到矽晶片的概念導讀

<!-- SPDX-License-Identifier: Apache-2.0 -->

這份文件寫給第一次接觸本 repo「被證明的核心（verified kernel）」的學生。它把
[README.md](./README.md) 第 6 節那些實驗背後的概念串起來：機器碼和組合語言差在哪、
ISA 是什麼、Lean 怎麼描述一條指令、定理到底證明了什麼，以及**定理沒有證明什麼**。
最後一點最容易被說錯，請一定讀到第七節。

文中每個說法都指向 repo 裡可以打開來看的檔案。看到不懂的名詞，先打開那個檔案。

---

## 一、機器碼與組合語言

| | 存在的形式 | 給誰讀 | 在本 repo 裡 |
| --- | --- | --- | --- |
| **組合語言**（assembly） | 文字，例如 `auipc t1, 0` | 人，以及組譯器（GNU `as`、LLVM） | 人讀的助記符。本 repo 的 kernel **不是**從組合語言組譯出來的 |
| **機器碼**（machine code） | 位元組，例如 `17 03 00 00` | CPU 的解碼電路 | 每個實驗的 `kernel.bin`：晶片實際執行的就是這些位元組 |

上表的例子是真的：[exp225](../../experiments/exp225-the-life-every-beat-proved/) 的
`kernel.bin` 共 76 個位元組，前 4 個是 `17 03 00 00`，也就是 `auipc x6, 0`
（`x6` 的 ABI 名稱是 `t1`）。

### 為什麼證明要針對位元組，而不是組合語言？

1. **組譯器不在信任範圍內，但信任並沒有消失，而是移到了別處。**
   傳統流程是「人寫組合語言 → 組譯器產生位元組」，組譯器若有錯，證明組合語言也沒用。
   本 repo 的位元組由 Lean 裡的 `encode` 函式算出來，所以要問的變成：**`encode` 本身
   符合 RISC-V 標準嗎？** 這一點不是靠證明，而是靠比對：
   [exp201](../../experiments/exp201-one-word-one-reading/) 把 `encode` 和 LLVM（一個
   本 repo 沒寫過的組譯器）在 3,450 條指令、5,572 個字上雙向比對。exp201 還示範了
   **兩個寫錯的編碼器，兩個方向的定理都成立，卻被 LLVM 抓到**。這正是第四節要說的重點。

2. **定理直接講位元組。** 以 exp225 的 `from_boot` 為例
   （[`proof/Life.lean`](../../experiments/exp225-the-life-every-beat-proved/proof/Life.lean)）：

   > 任何一個前 76 個位元組和 `kernel.bin` 相同的映像 `img`，放到符合 `Placed`
   > 條件的區域、從開機狀態 `boot` 開始，跑 3078 條指令時還在執行，第 3079 條時以
   > 停止碼 0 停下，而且記憶體恰好是規格 `lived` 所說的內容：從映像裡 `0x100`
   > 那個種子算出的 256 代 Rule 30。

   證明的方法**不是**對位元組做數學歸納，而是逐條指令的符號執行，迴圈的部分用不變量
   （`Inv`）和對迴圈次數的歸納（`iter`、`loop`）處理。

3. **位元組怎麼到晶片上。** UF2 寫進 Flash；開機後，C 寫的 shell 把 kernel 的映像
   逐位元組寫進 SRAM 裡的一塊區域（[`tools/hazard3/shell/region.h`](../../tools/hazard3/shell/region.h)
   的 `put`），設好 PMP，再用 `mret` 以 User mode 進入 kernel
   （[`tools/hazard3/harness/harness.S`](../../tools/hazard3/harness/harness.S) 寫了這個開機狀態）。
   Lean 裡的 `boot`（[`lean/Rv32/Load.lean`](../../lean/Rv32/Load.lean)）描述的就是這個狀態：
   `pc` 在區域起點，`sp`（`x2`）在區域終點，其餘暫存器為 0。

---

## 二、ISA 與晶片

### 1. ISA 是規格，CPU 是實作

**ISA（Instruction Set Architecture，指令集架構）是硬體與軟體之間的契約。** 它規定：

- 有哪些指令、每條指令做什麼；
- 有哪些暫存器（RV32 是 `x0`–`x31`，每個 32 位元，`x0` 永遠是 0）；
- 記憶體怎麼定址、位元組序（RISC-V 是 little-endian）；
- 每條指令怎麼編成位元（opcode、funct3、暫存器編號、立即值各佔哪幾位）。

RISC-V 的 RV32I（整數）、M（乘除）等是公開標準；**Hazard3 是依這份標準做出來的一顆 CPU 核心**。

### 2. RP2350 上的兩種核心

RP2350 晶片上同時有 Arm Cortex-M33 與 RISC-V Hazard3 兩種核心，開機時選用其中一種。
本 repo 的 verified-kernel 實驗全部跑在 **Hazard3** 上。Hazard3 的 RTL 是公開的，
[`tools/hazard3/setup.sh`](../../tools/hazard3/setup.sh) 會取得固定版本，再用 Verilator 模擬。

注意範圍：Hazard3 支援的指令比本 repo 的 Lean 模型多。**模型只涵蓋 kernel 可能用到的
46 種 RV32IM 指令形式**（exp201），不包括 CSR 指令、`fence`、`ebreak`，也不包括 16 位元的
壓縮指令。kernel 只能用這 46 種。

### 3. 三種常見架構，對照看

| | 設計 | 指令長度 | 存取記憶體 | 規格的取得 |
| --- | --- | --- | --- | --- |
| **x86-64** | CISC | 不固定，1–15 位元組 | 算術指令可以直接讀寫記憶體 | Intel、AMD 自有，不對外授權給一般廠商實作 |
| **Arm** | RISC | AArch64 固定 32 位元；Cortex-M（如 RP2350 的 M33）用 Thumb-2，16 與 32 位元混合 | load/store：只有 `LDR`/`STR` 存取記憶體 | 向 Arm 公司取得授權 |
| **RISC-V** | RISC | 基本指令 32 位元；C 擴展加入 16 位元壓縮指令 | load/store：只有 `lw`/`sw` 等存取記憶體 | **規格公開、免權利金**；實作可以開源（如 Hazard3），也可以不開源 |

「規格公開」對本 repo 很重要：Lean 模型可以直接照著公開的規格寫，再和 LLVM、
riscv-tests、Hazard3 RTL 比對，每一步都不需要誰的授權。

---

## 三、Lean 裡的一條指令：不是文字，是資料結構

[`lean/Rv32/Isa.lean`](../../lean/Rv32/Isa.lean) 用 `inductive` 定義指令，完整內容如下，
一共 **11 個建構子**：

```lean
inductive Instr
  | lui   (rd : Reg) (imm : BitVec 20)
  | auipc (rd : Reg) (imm : BitVec 20)
  | jal   (rd : Reg) (off : BitVec 20)
  | jalr  (rd rs1 : Reg) (imm : BitVec 12)
  | br    (op : BrOp) (rs1 rs2 : Reg) (off : BitVec 12)
  | ld    (op : LdOp) (rd rs1 : Reg) (imm : BitVec 12)
  | st    (op : StOp) (rs1 rs2 : Reg) (imm : BitVec 12)
  | opi   (op : IOp) (rd rs1 : Reg) (imm : BitVec 12)
  | sh    (op : ShOp) (rd rs1 : Reg) (shamt : BitVec 5)
  | op    (op : ROp) (rd rs1 rs2 : Reg)
  | ecall
```

其中 `Reg` 是 `BitVec 5`（0–31）。`op` 的 `ROp` 同時包含 RV32I 的 `add`、`sub` 等，以及
M 擴展的 `mul`、`div`、`rem` 等。11 個建構子再乘上各自的 `BrOp`、`LdOp` 等子選項，就是
那 46 種形式。

### 為什麼不用文字字串？

1. **字串可以寫出不存在的指令**，例如 `"auipc 999, foo"`。用字串做證明，得先證明剖析器
   （parser）是對的。
2. **可以逐一分情況。** 寫 `cases i` 時，Lean 會要求 11 個建構子每一個都處理到，漏掉一個
   證明就不會通過。
3. **建得出來就合法。** `imm : BitVec 20` 規定立即值剛好 20 位元，超出範圍的指令根本建構不出來。

所以 `Instr` 可以看成「組合語言的抽象語法樹（AST）」。寫 kernel 時，可以直接寫
`.auipc 6 0`；有些模組替常用暫存器取了名字，例如
[`lean/Rv32/Health.lean`](../../lean/Rv32/Health.lean) 的 `T1 : Reg := 6`。反方向，
[`lean/Rv32/Asm.lean`](../../lean/Rv32/Asm.lean) 的 `Instr.toAsm` 把指令印成 `llvm-mc` 接受的文字。
也就是說，組合語言文字在這裡是**輸出**，用來和 LLVM 比對，不是輸入。

---

## 四、從資料結構到位元組：四層，以及每一層的保證從哪來

```text
[1] 組合語言文字      auipc t1, 0              ← Instr.toAsm 印出來，給人看、給 LLVM 比對
         ▲
[2] Lean 的 Instr     .auipc 6 0               ← kernel 實際寫成這樣
         │ encode
         ▼
[3] 32 位元的字       0x00000317
         │ little-endian 拆成 4 個位元組
         ▼
[4] kernel.bin        17 03 00 00
```

每一層之間的保證，**來源不一樣**：

| 哪兩層之間 | 保證什麼 | 怎麼保證 |
| --- | --- | --- |
| [2] ⇄ [3] | 編碼、解碼互為反函數：`decode (encode i) = some i`，以及 `decode w = some i → encode i = w` | **證明**：`Isa.lean` 的 `decode_encode`、`encode_decode`（exp201） |
| [2] → [3] 符合 RISC-V 標準 | `encode` 算出來的字，就是標準規定的那個字 | **比對**，不是證明：exp201 與 LLVM 比對 |
| [3] → [4] | `kernel.bin` 的位元組，每 4 個依 little-endian 組起來，就是每條指令的 `encode` | **證明**：各實驗的 `bytes_words`（例如 exp225 的 `Life.lean`），由 `decide` 逐一算過 |
| [4] 與 commit 的檔案相同 | 證明講的位元組，就是 repo 裡那份 `kernel.bin` | **機器關卡 G2**：`lean.sh exec` 寫出的檔案與 `kernel.bin` 逐位元組相同 |

第二列最值得記住：**「兩個方向互為反函數」不等於「符合標準」**。如果 `encode` 把某個欄位
放錯位置，`decode` 也照同樣的錯誤讀回來，兩個定理照樣成立。exp201 的兩個錯誤版本就是這樣，
只有拿一個獨立寫成的組譯器來比，才抓得到。

---

## 五、Lean 裡的「機器」：狀態、一步、跑 n 步

[`lean/Rv32/Machine.lean`](../../lean/Rv32/Machine.lean) 把 CPU 寫成純函數：

- **`Machine`**（狀態）：`pc`、`regs : Reg → Word`、`mem : Word → Byte`。
- **`Env`**（環境）：kernel 可以使用的記憶體區域 `region`，以及兩個「外部函數」`hash`、`sig`。
- **`step env s : Outcome`**：執行一條指令。結果有三種：`running s'`（繼續）、
  `halted code s'`（以 `ecall` 停下）、`fault f s'`（例如未對齊、超出區域、不認得的指令）。
- **`run env n s`**：最多跑 `n` 步，遇到停止或錯誤就提早結束。

`ecall` 是 kernel 唯一的出口：`t0 = 1` 是停止（`HALT`），`t0 = 0` 是請環境算雜湊（`HASH`），
exp228 另加了 `2`、`3`。**`env.hash` 和 `env.sig` 是參數，證明不看它們的內部**：定理說的是
「不論給一個怎樣的雜湊函數，kernel 都會……」，至於晶片上的 SHA-256 硬體是不是那個函數，
是量測出來的，不是證明的。

### 測試與證明的差別

- **測試**：給一個輸入，跑一次，看結果對不對。沒試到的輸入，可能還藏著錯誤。
- **證明**：定理裡有 `∀` 的變數，對**所有**值都成立。

但「所有」指的是**定理量化的那些東西**，要讀定理才知道。exp225 的 `from_boot` 量化的是
「所有以這 76 個位元組開頭的映像」與放置的位置；種子就放在映像的 `0x100`，所以它對**每一個
種子**都成立，而 differential 只跑了其中 20 個。exp228 量化的是「限制範圍內的每一個輸入腳本」。
同時也要看定理**沒有**量化什麼：kernel 的 76 個位元組是固定的，改一個位元組，定理就不再適用。
讀定理時，先找 `∀` 和假設（`h… :` 那些），再讀結論。這也是 vk26 裁判 J2 題在問的事。

---

## 六、三個世界，怎麼互相對照

證明、模擬、晶片並**不是**一條「證明傳到模擬、再傳到晶片」的鏈。比較準確的圖是：

```text
   【Lean 模型】 ─────────── 證明 ───────────▶ 定理：模型上跑 kernel.bin，剛好 N 條後停下，結果如規格
        │
        │  比對，不是證明（exp202：riscv-tests 48 個 RV32I/M 測試與 5 個探針，
        │  模型與 RTL 結束方式相同、整個 64 KiB 區域相同；G4：每個實驗 ≥ 10 個輸入，
        │  模型、RTL、獨立參考實作三方的停止碼、指令數、64 KiB 區域都相同）
        ▼
   【Hazard3 RTL，Verilator 模擬】
        │
        │  同一份 kernel.bin；C shell 在晶片上每次檢查：kernel 雜湊、停止碼、
        │  minstret（實際執行的指令數），結果用 LED 或 USB 日誌回報（G5、G7）
        ▼
   【RP2350 實體晶片】  ← 在有限次的執行上觀察到與預測一致
```

---

## 七、證明保證了什麼，沒保證什麼

這是最容易說過頭的地方。**錯誤的說法**是：「定理證明的性質，分毫不差地在實體晶片上兌現。」

**正確的說法**是：

> 定理保證的是：在 **Lean 模型**上執行這些位元組，結果如規格所說。
> 模型和晶片一致，是用比對與上板觀察一次一次檢驗出來的，沒有被證明。

| 環節 | 狀態 | 依據 |
| --- | --- | --- |
| kernel 在模型上的行為 | **證明** | 各實驗的 `from_boot` 等定理；`lean.sh check` 只允許 Lean 自己的三個公理（G1） |
| Lean 本身的核心與那三個公理 | **信任** | 不用 `native_decide`、`bv_decide`，避免連編譯器也要一起信任 |
| `encode` 符合 RISC-V 標準 | **比對** | exp201 與 LLVM |
| 模型的每條指令與 Hazard3 一致 | **比對** | exp202 的 riscv-tests 與探針；各實驗的 differential（G4） |
| C shell：搬映像、設 PMP、檢查結果、點 LED | **測試，沒有證明** | 故意寫錯的 shell 要被抓到（G5） |
| `env.hash`、`env.sig` 與晶片上的實作 | **量測** | 例如 exp210：晶片用硬體 SHA-256 跑 kernel，結果與模型、RTL 事先算好的答案逐位元組比對 |
| 晶片本身（矽、時脈、電源） | **觀察** | 上板（G7），次數有限、板子只有一塊 |

每個實驗的 README 都有一節 **What it does not say**，例如 exp225 寫明「LED 顯示的是不是
那一代，是 C 寫的，沒有證明」。讀一個實驗時，這一節和定理一樣重要。

這不是缺點，而是形式化驗證的常態：**證明把「要信任的東西」縮小到可以列成一張表，
再對表上每一項各自去檢驗**。能把這張表寫清楚，才算懂了這個實驗。

---

## 八、自我檢查

讀完後試著回答。答案都在上面，也都能在 repo 裡找到出處。

1. `decode_encode` 和 `encode_decode` 都證明了，為什麼還要和 LLVM 比對？
2. exp225 的 `from_boot` 對「所有輸入」成立嗎？它的 `∀` 量化的是什麼？
3. 晶片上的 SHA-256 硬體如果算錯，exp208 的定理還成立嗎？會在哪裡被發現？
4. `kernel.bin` 有 76 個位元組，模型卻只涵蓋 46 種指令形式。如果有人在 kernel 裡放了一條
   CSR 指令，會在哪一步被擋下？
5. LED 閃了，能推出哪些事？不能推出哪些事？

<details>
<summary>參考答案</summary>

1. 兩個方向互為反函數，只說明編碼、解碼彼此一致，不代表符合標準。同一個錯誤可以同時寫進
   兩邊（exp201 的兩個錯誤版本就是這樣），要靠一個獨立寫成的組譯器才抓得到。
2. 對每一個種子都成立：它量化「前 76 個位元組相同的所有映像」，種子就在映像的 `0x100`，
   放置的位置則要滿足 `Placed`。不在量化範圍內的是 kernel 本身：76 個位元組是固定的。
3. 定理仍然成立，因為它對任何 `env.hash` 都成立；但它說不到晶片上那個硬體區塊。這種錯誤會在
   比對中被發現：exp210 的晶片用硬體 SHA-256 跑完 kernel，整個區域與模型、RTL 事先算好的答案
   逐位元組比對，對不上就是失敗。
4. 那條指令寫不成 `Instr`，所以 `encode` 產生不出它。如果直接改 `kernel.bin`，G2 的逐位元組
   比對會失敗；在模型上 `decode` 傳回 `none`，`step` 會得到 `fault`（不認得的指令）。
5. 能推出：shell 的每一項檢查都通過了（雜湊、停止碼、minstret），前提是 shell 的程式真的
   如此寫（要讀程式碼）。不能推出：LED 的樣式就是證明裡的那個值。點 LED 的是 C，沒有被證明。

</details>

---

## 延伸閱讀

- [README.md 第 6 節](./README.md#6-依賴的既有實驗先讀這些)：依賴的實驗，由淺入深。
- [exp201](../../experiments/exp201-one-word-one-reading/)：編碼、解碼與 LLVM。
- [exp202](../../experiments/exp202-the-tests-the-chip-passes/)：模型與 RTL 的比對。
- [exp203](../../experiments/exp203-the-count-the-proof-promised/)：第一個 `from_boot`。
- [exp225](../../experiments/exp225-the-life-every-beat-proved/)：最適合當第一個讀的完整證明，含 What it does not say。
- [`lean/README.md`](../../lean/README.md)：每個 Lean 模組放了什麼、由誰檢查。
- [ACCEPTANCE.md](./ACCEPTANCE.md)：G1–G7 各自檢查哪一個環節。
