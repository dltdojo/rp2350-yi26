# vk26：被證明的核心徵求 2026

<!-- SPDX-License-Identifier: Apache-2.0 -->

**Verified Kernel Call 2026。** 本 repo 已經有三十多個實驗，在樹莓派 RP2350 的
RV32 核心（Hazard3）上執行「被 Lean 證明的程式」：證明說的是**晶片實際執行的
那些位元組**，從開機起剛好跑幾條指令、停下來、算出規格所說的結果。我們徵求在這個
基礎上延伸的新實驗。

| | |
| --- | --- |
| 徵求期間 | 即日起，不設截止，持續受理 |
| 交付 | 一位提案者、一個目錄、**五個**驗證過的實驗、一個 PR |
| 驗收 | [ACCEPTANCE.md](./ACCEPTANCE.md)：機器關卡 G1–G7，加上 LLM 裁判的四個是非題 |
| LLM 裁判 | [JUDGE.md](./JUDGE.md) 與 [judge-bundle.sh](./judge-bundle.sh)；**校準尚未完成**，第 2 輪因用量額度耗盡中止，見 [calibration/README.md](./calibration/README.md) |
| 現場測試地點與頻率 | 依後續公告指定的大學 |
| 獎勵與其他條款 | 依後續公告 |

## 1. 資格

接任務者須同時符合：

1. **會使用 GitHub**：fork、branch、pull request、issue。
2. **具備 Claude Pro 訂閱**，可使用 Opus 5.5 模型。本 repo 的開發方式就是人與 AI
   一起做，[AGENTS.md](../../AGENTS.md) 是給 AI 的規則，提案者的 AI 也要遵守。
3. **能用手機的 USB 複製燒錄 RP2350 韌體**：按住 BOOTSEL 接上板子，把 `.uf2`
   複製進 `RP2350` 磁碟（手機的檔案管理員即可）。
4. **能到指定的大學當面測試**：由任務方提供 RP2350 開發板，現場燒錄、收紀錄、確認
   （驗收關卡 G7）。

## 2. 徵求什麼

每個實驗都必須**與形式化驗證和被證明的 RV32 kernel 有關**。最低要求是：

> 一段 RV32 kernel 的位元組，以及一個 Lean 定理，說這些位元組從開機執行，剛好 N 條
> 指令後以 0 停止，並在記憶體裡留下規格所說的結果，其他位元組一個不動——也就是本 repo
> 的 `from_boot` 這一種定理。

可以是（只是例子，不限於此）：

- **新的運算**：CRC32、ChaCha20 的一輪、排序網路、base64、Keccak-f 的一輪、多項式
  乘法、整數平方根、某個細胞自動機……
- **新的性質**：在新的 kernel 上證明常數時間（[`lean/Rv32/Ct.lean`](../../lean/Rv32/Ct.lean)）、
  在某個輸入範圍內絕不 fault、兩個 kernel 共用一個區域而互不干擾……
- **從定理推出可以在板子上檢驗的預測**，像 exp234 從 M7 推出 12.715% 的失敗率，再讓
  板子的試驗去碰它。
- **新的指令**：例如加入 Zbb。必須比照 exp201 與 LLVM 雙向比對、比照 exp202 跑
  riscv-tests——但這需要改 `lean/Rv32/Isa.lean`，不在提案者目錄內，請先開 issue 討論
  （見第 5 節）。

五個實驗必須**彼此不同**：同一個 kernel 換參數不算五個。

## 3. 目錄與編號

fork 本 repo 後，所有東西都放在任務方**指派給你的目錄**之下，目錄名稱就是你的
GitHub 帳號：

```
calls/vk26/alice/
  README.md                      五個實驗的索引表，一個實驗一列（Needs 等級、USB、一句話）
  lean/                          （選用）你自己五個實驗共用的 Lean 模組，見第 4 節
    lakefile.toml
    Alice.lean
    Alice/Common.lean
  exp101-<slug>/                 實驗編號固定是 101 到 105
    README.md  WHY.zh-TW.md
    check.sh  run.sh  capture.txt
    proof/<Name>.lean  proof/mutants.txt
    kernel.bin  kernel.sha256
    <參考實作>.py  differential/
    shell/  build.sh  gen.py  <name>.uf2.sha256  build-toolchain.txt
    board/round1.txt
  exp102-<slug>/
  exp103-<slug>/
  exp104-<slug>/
  exp105-<slug>/
```

- 實驗編號 **101–105 只在你的目錄裡有意義**，和 `experiments/exp101-board-bringup`
  無關。因為每個人的目錄不同，編號不會衝突。
- **只能新增或修改自己的目錄**。PR 裡只要有一個檔案在 `calls/vk26/<你的帳號>/` 之外，
  就不會被合併（ACCEPTANCE.md 的 S2）。
- 韌體的 USB 名稱與序號要能和別人、和 `experiments/` 區分：`SPEAK_NAME` 用
  `alice-exp101`，`SPEAK_SERIAL` 用 `alice-101`。本 repo 的工具（`yi26 port`）靠序號
  認出板子上跑的是誰的韌體。
- `check.sh` 照 `experiments/` 的寫法，`source ../../../../experiments/lib.sh` 以使用
  `pass`、`fail`、`require_supported_platform`、`capture_header`、`capture_tee`。
  `presence_check` 與 `usb_check` 讀的是 `experiments/README.md` 的表格，**不要**呼叫；
  同樣的資訊寫在你自己的 `README.md` 索引表裡。

## 4. 共用程式的議題：複製、指定版本，還是直接引用

五個實驗一定會用到既有的 Lean 函式庫（`lean/Rv32/`，一萬兩千行），也一定會有彼此
共用的部分。不能改別人的目錄，那麼共用的東西放哪裡？三種做法的評估：

| 做法 | 好處 | 代價 |
| --- | --- | --- |
| **A. 複製** `lean/` 需要的部分到自己目錄 | 完全隔離，主線怎麼改都不影響 | 同一個事實出現兩份，之後各自修改就會分歧；被證明的是複製品，不是主線的模型；違反本 repo「一個事實只有一份」的原則（[docs/what-belongs-to-an-experiment.md](../../docs/what-belongs-to-an-experiment.md)）。exp174 帶著 exp173 的 USB 序號上板、exp160 與 exp162 因同一個複製來的佇列兩次丟失報告，都是複製的代價 |
| **B. 指定版本**：用 Lake 的 `require … from git @ <commit>` 引用某個 commit 的 `lean/` | 版本凍結得很明確 | 建置時要上網抓第二份函式庫，整份一萬兩千行重新編譯；同一個建置裡出現兩個 `Rv32`；主線之後修好的錯誤或新增的引理永遠進不來；而提案本來就在同一個 repo 裡，這一層間接是多餘的 |
| **C. 直接引用 repo 內的 `lean/`**，自己的共用模組放在自己目錄的 Lake 套件 | 一份事實；不必重新編譯（直接用主線已編好的結果）；不用網路；PR 的 base commit 就是版本 | 主線之後修改 `lean/` 時，有可能讓你的證明不再通過 |

**採用 C。** 理由：

1. **版本其實已經指定了**：你 fork 的那個 commit（PR 的 merge base）就是你依賴的版本，
   驗收時 G1–G6 在你的 PR head 上執行，看的就是那個組合。
2. **C 的代價由主線承擔，不由你承擔**：本 repo 對 `experiments/` 一向的規則是，修改
   `lean/` 的人必須讓**每一個**用到它的證明繼續通過（例如 exp234 把 `Tissue.lean`
   抽出來時，exp232 的 `kernel.bin` 一個位元組都沒變）。合併之後，`calls/vk26/*/` 也
   受同一條規則保護。
3. **A 和 B 都違反「一個事實一份」**，而那正是被證明的程式最需要的：證明說的是「這個
   模型」，模型有兩份，就不知道說的是哪一份。

做法：

- 證明檔直接 `import Rv32` 或 `import Rv32.Ring` 等，**不要複製**任何 `lean/` 的檔案。
- 你五個實驗共用的模組，放在 `calls/vk26/<你的帳號>/lean/`，成為一個以路徑引用主線
  的 Lake 套件：

  ```toml
  # calls/vk26/alice/lean/lakefile.toml
  name = "alice"
  defaultTargets = ["Alice"]

  [[require]]
  name = "yi26"
  path = "../../../../lean"

  [[lean_lib]]
  name = "Alice"
  ```

  證明檔寫 `import Alice.Common` 即可。`tools/lean/lean.sh check|mutants|run|exec`
  看到檔案位在 `calls/<徵求>/<帳號>/` 底下、且該處有 `lean/lakefile.toml`，就會改用
  這個套件檢查；它直接沿用 `lean/` 已編好的結果，不會重新編譯。
- 套件裡的模組，命名空間用你的帳號（`Alice.…`），以免和主線或別人撞名。
- **第二次用到就抽出來**（本 repo 的規則）：同一段 Lean、Python、C 或 shell 在你的
  兩個實驗裡出現，就搬進你自己的 `lean/` 或一個 `calls/vk26/<帳號>/tools/`。
- 你覺得某個引理該進主線 `lean/`：在 PR 說明裡寫出來，合併後由任務方另開 PR 搬移，
  並負責讓所有使用者繼續通過。
- 限制：`mutants.txt` 裡以 `|lean/…` 結尾、改主線函式庫的 mutant，對提案者套件不
  支援（`lean.sh` 會判為 FAIL「inconclusive」）。mutant 請改你自己的證明檔。

同樣的原則適用於 `tools/`（例如 `tools/hazard3/shell/` 的 `speak.h`、`trng.h`、
`ring.h`、`trial_chip.h`）與 `crates/`：直接引用，不要複製；需要改它們時先開 issue。

## 5. 流程

1. **報名**：開一個 issue，標題 `vk26: <GitHub 帳號>`，寫五個實驗各一句話。
2. **指派**：任務方在 issue 中回覆，確認你的目錄 `calls/vk26/<帳號>/`。
3. **開發**：fork、開 branch，照第 3、4 節放檔案。開始每個實驗前，照
   [experiments/README.md 的「How this repository is developed」](../../experiments/README.md#how-this-repository-is-developed)
   先讀既有的實驗與文件，不要重新推導已經回答過的問題。
4. **自我檢查**：五個 `check.sh` 都 exit 0；`run.sh` 從乾淨的 commit 錄 `capture.txt`
   並貼進 README 的 Expected output；用自己的板子跑一輪，存成 `board/round1.txt`。也可以
   用 [JUDGE.md](./JUDGE.md) 對自己的實驗先跑一次 LLM 裁判（第 7 節）。
5. **PR**：一個 PR，包含五個實驗。標題 `vk26/<帳號>: <五個主題>`。
6. **機器關卡與 LLM 裁判**：任務方在 PR head 上執行 G1–G6 與 J1–J4，結果貼在 PR。
   不通過的項目會寫明原因與證據位置，修正後重跑。
7. **現場測試（G7）**：在指定的大學，由任務方的人員、任務方的板子、任務方的手機進行。
8. **合併**：全部通過後合併。

## 6. 依賴的既有實驗：先讀這些

### 第 1 層：每一份提案都依賴的地基

| 實驗或模組 | 提供什麼 |
| --- | --- |
| [exp201](../../experiments/exp201-one-word-one-reading/) · `lean/Rv32/Isa.lean` | 46 種 RV32IM 形式的 `encode`、`decode`，兩個方向都證明，並與 LLVM 雙向比對 |
| [exp202](../../experiments/exp202-the-tests-the-chip-passes/) · `lean/Rv32/Machine.lean` | 每條指令做什麼；與 riscv-tests、Hazard3 RTL 比對整個 64 KiB 區域 |
| [exp203](../../experiments/exp203-the-count-the-proof-promised/) · `Proof.lean`、`Place.lean`、`Load.lean` | 第一個 kernel：`CodeAt`、`from_boot`、剛好幾條指令 |
| [`tools/lean/lean.sh`](../../tools/lean/lean.sh) | `check`（只允許 Lean 自己的公理）、`mutants`、`table`、`exec`、`exe rv32run` |
| [`lean/README.md`](../../lean/README.md) | 每個模組放了什麼、由誰檢查 |

### 第 2 層：證明的寫法，由淺入深

| 實驗 | 學什麼 |
| --- | --- |
| [exp225](../../experiments/exp225-the-life-every-beat-proved/) Rule 30 | **最好的起點**：`run_line`、`loadStep`、`storeStep`、`Inv`、`iter`、`loop`、`from_boot` 的骨架 |
| [exp230](../../experiments/exp230-the-motion-the-fly-sees/) 蒼蠅 | `Ring.lean`：popcount、旋轉；把一個猜想證成定理 |
| [exp232](../../experiments/exp232-the-cure-the-proof-predicts/) / [exp234](../../experiments/exp234-the-rate-the-proof-predicts/) | `Tissue.lean`；用旋轉不變性取代逐一窮舉；把亂數變成輸入；從定理推出一個比例 |
| [exp208](../../experiments/exp208-the-hash-the-kernel-computes/) SHA-256 | 為證明而寫的規格；多區塊迴圈 |
| [exp228](../../experiments/exp228-the-script-the-kernel-runs/) / [exp229](../../experiments/exp229-the-remainder-the-kernel-keeps/) | `Flow.lean`（分支與跳躍）、`Limbs.lean`（多字整數）、[`tools/lean/kasm.py`](../../tools/lean/kasm.py)（用標籤寫 kernel） |
| [exp207](../../experiments/exp207-the-trace-the-seed-cannot-move/) | `Ct.lean`：常數時間的檢查器 |
| [exp222](../../experiments/exp222-the-bits-the-kernel-withholds/) / [exp223](../../experiments/exp223-the-digest-the-kernel-withholds/) / [exp224](../../experiments/exp224-the-checks-the-kernel-makes/) | `Health.lean`、`Within.lean`：128 KiB 區域、兩個 kernel 合成一個 |
| [exp204](../../experiments/exp204-the-signature-the-kernel-checks/)–[exp206](../../experiments/exp206-the-root-the-path-climbs/)、[exp213](../../experiments/exp213-the-signer-the-verifier-accepts/) | 簽章：`Blocks.lean`、`Wots.lean`、`Walk.lean`、`Mss*.lean` |

### 第 3 層：上板

| 實驗 | 提供什麼 |
| --- | --- |
| [exp209](../../experiments/exp209-the-count-the-led-blinks/) / [exp210](../../experiments/exp210-the-hash-the-chip-computes/) | C shell：User mode 加 PMP，每次執行都檢查 kernel 雜湊、停止碼、minstret |
| [exp226](../../experiments/exp226-the-shell-that-speaks/) / [exp227](../../experiments/exp227-the-life-on-the-phone/) | C shell 的 USB 輸出（`speak.h`）；網頁逐行重算 |
| [exp231](../../experiments/exp231-the-fly-on-the-phone/) | 兩個 kernel 共用一個區域，加上手機網頁 |
| [exp232](../../experiments/exp232-the-cure-the-proof-predicts/) / [exp233](../../experiments/exp233-the-trial-on-the-phone/) / [exp234](../../experiments/exp234-the-rate-the-proof-predicts/) | TRNG 抽樣、`ring.h`、`trial_chip.h`、手機的 Copy 回傳、`board/*.txt` 由參考實作核對 |

### 第 4 層：規則，動手之前讀

- [AGENTS.md](../../AGENTS.md)：給 AI 的規則（讀紀錄用 `yi26 log --json`，不要截圖瀏覽器；沒有板子時先搜尋既有文件；LED 就是除錯管道）。
- [docs/what-belongs-to-an-experiment.md](../../docs/what-belongs-to-an-experiment.md)：一個實驗的 `src` 只放它要問的東西。
- [experiments/README.md](../../experiments/README.md)：How this repository is developed、Captures are pasted, never predicted、Platform、Which layer of USB is this。
- [docs/debugging-without-a-board.md](../../docs/debugging-without-a-board.md)、[docs/the-board-is-the-loop.md](../../docs/the-board-is-the-loop.md)：沒有板子時怎麼工作。

## 7. 驗收與 LLM 裁判（摘要）

全文在 [ACCEPTANCE.md](./ACCEPTANCE.md)。原則：**能用機器判斷的，就不交給 LLM。**

- **機器關卡 G1–G7**（每個實驗）：Lean 檢查與公理、`kernel.bin` 逐位元組、mutant
  全被拒絕、Lean 模型 × Hazard3 RTL × 獨立參考實作三方一致、UF2 可重現、文件與
  capture、現場上板。只有通過或不通過。
- **提案層級 S1–S4**：五個實驗、只動自己目錄、彼此不同、索引表齊全。
- **LLM 裁判 J1–J4**（每個實驗，四個是非題）：宣稱是否都有根據、定理是否就是 README
  說的那件事、相對既有實驗有沒有新東西、參考實作是否獨立（原 J3 定理不平凡已由 G1.5 與 G3 機器關卡把關）。每個回答都
  必須引用 `檔案:行號`；同一份資料由三個全新 session 各判一次；三次一致才算數，否則
  轉人工。LLM 不能推翻機器關卡的結果。

自己先跑裁判：

```sh
calls/vk26/judge-bundle.sh bundle calls/vk26/alice/exp101-foo > /tmp/b.txt
# 把 JUDGE.md 與 /tmp/b.txt 交給一個全新的 Claude（Opus 5.5）session，得到 verdict
calls/vk26/judge-bundle.sh tally /tmp/b.txt v1.txt v2.txt v3.txt
```

## 8. 尚待公告

- 現場測試的大學、時段與頻率。
- 獎勵與其他條款（智慧財產、授權以外的權利義務等）。

本目錄的程式與文件以 Apache-2.0 授權，提案者的貢獻也以同一授權合併。
