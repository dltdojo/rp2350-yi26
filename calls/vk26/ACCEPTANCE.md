# vk26 驗收條件

<!-- SPDX-License-Identifier: Apache-2.0 -->

一份提案 = `calls/vk26/<帳號>/` 底下的五個實驗 `exp101`–`exp105`，一個 PR。

驗收分三層，順序固定，前一層不通過就不進下一層：

1. **機器關卡 G1–G6**：每個實驗都要通過。只有通過或不通過，由 Lean、腳本與比對工具判斷。
2. **LLM 裁判 J1–J5**：每個實驗都要通過。只回答機器無法判斷的五個是非題。
3. **現場上板 G7**：每個實驗都要通過，在指定的大學由任務方執行。

另外有**提案層級 S1–S4**，對整份提案判斷一次。

原則：**能讓機器判斷的，不交給 LLM；LLM 判斷的，必須引用證據，且三次一致。**

## 提案層級

| | 條件 | 怎麼判斷 |
| --- | --- | --- |
| **S1** | 剛好五個實驗目錄，`exp101-<slug>` 到 `exp105-<slug>` | `ls` |
| **S2** | PR 只新增或修改 `calls/vk26/<帳號>/` 之下的檔案 | `git diff --name-only <merge-base>...<head>`，每一行都以 `calls/vk26/<帳號>/` 開頭 |
| **S3** | 五個實驗的主要 kernel 彼此不同：不是同一段程式換參數 | 五個 `kernel.sha256` 互不相同，且 J4 對每個實驗都回答「是」 |
| **S4** | `calls/vk26/<帳號>/README.md` 有五列索引表：實驗、Needs 等級（0–3）、USB 介面、一句話 | 人工確認 |

## 機器關卡（每個實驗）

| | 條件 | 怎麼判斷 |
| --- | --- | --- |
| **G1.5 預檢** | `proof/*.lean` 至少一個定理的敘述含 `run env N (boot …)`（`from_boot` 形式存在），且沒有任何定理的結論就是 `True` | `judge-bundle.sh gates <實驗>`；只擋最粗糙的情形，J2、J3 仍照問 |
| **G1 證明** | 證明檔通過 `tools/lean/lean.sh check`：沒有錯誤、沒有警告、沒有 `sorry`；每個 `#print axioms` 只列 `propext`、`Classical.choice`、`Quot.sound` 之中的公理；不用 `native_decide`、`bv_decide`；不 import Mathlib。至少一個定理是 `from_boot` 形式：從開機執行 `kernel.bin` 的位元組，剛好 N 條指令後以 0 停止，留下規格所說的結果 | `lean.sh check`；`from_boot` 形式由 J2 確認 |
| **G2 位元組** | `lean.sh exec proof/<Name>.lean <out>` 寫出的檔案與 commit 進來的 `kernel.bin` 逐位元組相同，`kernel.sha256` 是它的雜湊 | `cmp`、`sha256sum` |
| **G3 定理有牙齒** | `proof/mutants.txt` 至少 **4** 個錯誤版本，至少一個改 kernel 的指令、至少一個改宣稱；Lean 全部拒絕 | `lean.sh mutants` 全部 PASS |
| **G4 三方一致** | 至少 **10** 個輸入上，Lean 模型（`rv32run`）、Hazard3 RTL、與一份**獨立撰寫**的參考實作結果完全相同：停止碼、指令數、整個 64 KiB 區域 | 實驗的 differential，照 exp225 或 exp234 的寫法；獨立性由 J5 確認 |
| **G5 韌體** | UF2 建得出來，`uf2check.py` 通過；`build-toolchain.txt` 記錄工具鏈，相同工具鏈下建出的 UF2 雜湊等於 commit 進來的；shell 在 RTL 上的輸出等於參考實作的預期；至少 **3** 個故意寫錯的 shell 被各自的檢查抓到 | `check.sh` |
| **G6 文件與紀錄** | 有 `README.md`（英文）、`WHY.zh-TW.md`（台灣繁體中文，給學生看的白話說明）；README 的 Expected output 是 `capture.txt` 原文貼上，`capture.txt` 由 `run.sh` 從乾淨的 commit 錄製；`check.sh` exit 0；沒有在提案目錄裡複製 `lean/`、`tools/` 的檔案；同一段程式在兩個實驗中出現，已抽到提案者自己的 `lean/` 或 `tools/` | 腳本加上 `judge-bundle.sh`（J1 會讀到 capture 與 README 是否一致） |

一個實驗如果沒有韌體（Needs 等級 0，例如純粹的證明或函式庫），G5 與 G7 不適用；但五個
實驗中**至少三個**要有韌體並通過 G7。

## LLM 裁判（每個實驗）

由 [judge-bundle.sh](./judge-bundle.sh) 把實驗整理成一份固定格式的文字檔，交給
[JUDGE.md](./JUDGE.md) 所定義的裁判。題目固定為五題，只能回答 YES 或 NO：

| | 問題 | 回答 YES 的條件 |
| --- | --- | --- |
| **J1 宣稱有根據** | README 與 WHY 的每一個宣稱，是否都能對應到 bundle 中的一個定理、一段 capture 或一份板子紀錄？ | 沒有任何一句超出實際證明或實際執行過的內容 |
| **J2 定理即是所說** | 主要定理的 Lean 敘述，是否就是 README 說的那件事，且至少一個是 `from_boot` 形式（關於 kernel 的位元組、精確的指令數）？ | README 說「任何輸入」，定理就對任何輸入成立；README 說「任何位置」，定理就沒有把位置固定 |
| **J3 不平凡** | 主要定理拿掉 kernel 之後是否仍然不成立？（結論不是 `True`，結論沒有直接寫在假設裡，量詞範圍沒有被縮到空集合） | 定理確實依賴 kernel 做了什麼 |
| **J4 有新東西** | 和 bundle 列出的既有實驗相比，是否至少有一項新東西：新的 kernel、新的性質、新的推論、或新的可檢驗預測？ | 能指出那一項，並引用它 |
| **J5 參考實作獨立** | 參考實作（Python 等）是否獨立於 Lean 規格寫成，而不是逐行翻譯？ | 寫法不同（例如逐格寫 vs. 位元運算），或 README 明說兩者的差異 |

### 判定規則

1. 同一份 bundle，由**三個全新的** session 各判一次（模型：Opus 5.5；提示詞：commit 中的 JUDGE.md）。每次由 `judge-bundle.sh judge` 把提示詞與整份 bundle 放在**一則訊息**送出、不給工具，裁判不分段讀檔。bundle 已去掉 Lean 的證明步驟（G1 已驗證），保留定義、定理敘述與註解。
2. 每個回答都必須附上 `檔案:行號` 的證據，而且該行必須真的存在於 bundle 中。缺證據或證據不存在，該回答**無效**。由 `judge-bundle.sh tally` 自動檢查。
3. 每一題：
   - 三次都有效且都是 YES → **YES**
   - 三次都有效且都是 NO → **NO**
   - 其他（不一致、有無效回答） → **SPLIT**
4. 整個實驗：
   - 五題都是 YES → **PASS**
   - 任何一題是 NO → **FAIL**，附上三次的理由與證據
   - 其他 → **HUMAN**，由任務方人工決定
5. bundle 的注入掃描有命中，或任何一次裁判回報 `INJECTION`，該實驗一律 **HUMAN**。
6. LLM 不能推翻 G1–G6：bundle 中的機器關卡結果是既定事實，裁判只回答 J1–J5。
7. **申訴**：提案者可以提交一次書面反駁，放進 bundle 後重新判定三次；仍有爭議時由任務方決定。

### 校準

正式使用前，裁判必須在已知答案的範例上全部判對，結果記錄在 [calibration/](./calibration/)：

- **已知好的**：本 repo 的 exp225、exp230、exp234 → 必須 PASS
- **已知壞的**（由 `calibration/cases.sh` 從上面三個實驗製作）：
  - 誇大宣稱 → J1 NO
  - 主要定理被換成 `True` → J2 或 J3 NO
  - 定理被縮窄（只對位置 0 成立），README 仍說「任何位置」 → J2 NO
  - 夾帶給裁判的指示加上誇大宣稱 → 注入命中、J1 NO、結果 HUMAN

JUDGE.md、bundle 的組法每改一次，就重跑一次校準。**校準一律用 Opus 5.5**（與正式驗收同一模型）。
分兩階段，由 `calibration/run.sh` 執行，同時最多 3 個 session：

- **階段 A**：每個案例一次（7 次）。有任何一個不對，就先修正，不進階段 B。
- **階段 B**：階段 A 全對，才每個案例再跑兩次，湊足三次，統計。

提案者的自我檢查可用 `calibration/run.sh sonnet`（Sonnet 5.5，一次）；它只能抓格式與引用錯誤，**不算校準**，也不能取代正式的三次 Opus。

## 現場上板（G7，每個有韌體的實驗）

在指定的大學，由任務方執行，流程固定：

1. 任務方在自己的電腦上 clone PR head，建出 UF2，確認雜湊等於 commit 進來的 `<name>.uf2.sha256`。不使用提案者帶來的檔案。
2. 任務方親手把 UF2 燒錄到**任務方的** RP2350 開發板。
3. 紀錄由任務方的裝置收集：`yi26 log --json`，或任務方手機上的網頁 Copy。
4. 紀錄存成 `board/vk26-<日期>.txt`，以提案者自己的參考實作 `--board` 檢查（照 exp232、exp234 的寫法）：每一行都要和參考實作一致，且只要改動紀錄中的一處就會被拒絕（至少示範兩種改法）。
5. 實驗 README 所寫的板子上可觀察的宣稱（LED 樣式、指令數、試驗結果等），逐項在現場確認，任務方在 PR 上留言記錄結果。

提案者自己的上板紀錄（`board/round1.txt` 等）是開發證據，**不能取代 G7**。
