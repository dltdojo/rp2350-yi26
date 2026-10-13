# vk26 驗收條件

<!-- SPDX-License-Identifier: Apache-2.0 -->

一份提案 = `calls/vk26/<帳號>/` 底下的五個實驗 `exp101`–`exp105`，一個 PR。

驗收分三層，順序固定，前一層不通過就不進下一層：

1. **機器關卡 G1–G6**：每個實驗都要通過。只有通過或不通過，由 Lean、腳本與比對工具判斷。
2. **LLM 裁判 J1–J4**：每個實驗都要通過。只回答機器無法判斷的四個是非題。
3. **現場上板 G7**：每個實驗都要通過，在指定的大學由任務方執行。

另外有**提案層級 S1–S4**，對整份提案判斷一次。

原則：**能讓機器判斷的，不交給 LLM；LLM 判斷的，必須引用證據。** 抽驗的實驗、申訴、以及抽驗失敗後的其餘實驗，要三次一致；其他實驗單次確認（見「判定規則」）。

## 提案層級

| | 條件 | 怎麼判斷 |
| --- | --- | --- |
| **S1** | 剛好五個實驗目錄，`exp101-<slug>` 到 `exp105-<slug>` | `ls` |
| **S2** | PR 只新增或修改 `calls/vk26/<帳號>/` 之下的檔案 | `git diff --name-only <merge-base>...<head>`，每一行都以 `calls/vk26/<帳號>/` 開頭 |
| **S3** | 五個實驗的主要 kernel 彼此不同：不是同一段程式換參數 | 五個 `kernel.sha256` 互不相同，且 J3 對每個實驗都回答「是」 |
| **S4** | `calls/vk26/<帳號>/README.md` 有五列索引表：實驗、Needs 等級（0–3）、USB 介面、一句話 | 人工確認 |

## 機器關卡（每個實驗）

| | 條件 | 怎麼判斷 |
| --- | --- | --- |
| **G1.5 預檢** | `proof/*.lean` 至少一個定理的敘述含 `run env N (boot …)`，且 N 是確定的指令數：數字，或由參數算出的式子（如 exp205 的 `(4141 + 3 * steps …)`）；被 `∃`、`∀` 綁住的變數（如 `∃ n, run env n (boot …)`）不算。另外，沒有任何定理的結論就是 `True` | `judge-bundle.sh gates <實驗>`。`1 = 1` 這類結論、互相矛盾的假設，正規表示式擋不住，由 J2 判斷（主要定理和 README 對不上就是 NO）；G3 只檢查提案者自己寫的 mutant，不能代替這一步 |
| **G1 證明** | 證明檔通過 `tools/lean/lean.sh check`：沒有錯誤、沒有警告、沒有 `sorry`；每個 `#print axioms` 只列 `propext`、`Classical.choice`、`Quot.sound` 之中的公理；不用 `native_decide`、`bv_decide`；不 import Mathlib。至少一個定理是 `from_boot` 形式：從開機執行 `kernel.bin` 的位元組，剛好 N 條指令後以 0 停止，留下規格所說的結果 | `lean.sh check`；`from_boot` 形式由 J2 確認 |
| **G2 位元組** | `lean.sh exec proof/<Name>.lean <out>` 寫出的檔案與 commit 進來的 `kernel.bin` 逐位元組相同，`kernel.sha256` 是它的雜湊 | `cmp`、`sha256sum` |
| **G3 定理有牙齒** | `proof/mutants.txt` 至少 **4** 個錯誤版本，至少一個改 kernel 的指令、至少一個改宣稱；Lean 全部拒絕 | `lean.sh mutants` 全部 PASS |
| **G4 三方一致** | 至少 **10** 個輸入上，Lean 模型（`rv32run`）、Hazard3 RTL、與一份**獨立撰寫**的參考實作結果完全相同：停止碼、指令數、整個 64 KiB 區域 | 實驗的 differential，照 exp225 或 exp234 的寫法；獨立性由 J4 確認 |
| **G5 韌體** | UF2 建得出來，`uf2check.py` 通過；`build-toolchain.txt` 記錄工具鏈，相同工具鏈下建出的 UF2 雜湊等於 commit 進來的；shell 在 RTL 上的輸出等於參考實作的預期；至少 **3** 個故意寫錯的 shell 被各自的檢查抓到 | `check.sh` |
| **G6 文件與紀錄** | 有 `README.md`（英文）、`WHY.zh-TW.md`（台灣繁體中文，給學生看的白話說明）；README 的 Expected output 是 `capture.txt` 原文貼上，`capture.txt` 由 `run.sh` 從乾淨的 commit 錄製；`check.sh` exit 0；沒有在提案目錄裡複製 `lean/`、`tools/` 的檔案；同一段程式在兩個實驗中出現，已抽到提案者自己的 `lean/` 或 `tools/` | 腳本加上 `judge-bundle.sh`（J1 會讀到 capture 與 README 是否一致） |

一個實驗如果沒有韌體（Needs 等級 0，例如純粹的證明或函式庫），G5 與 G7 不適用；但五個
實驗中**至少三個**要有韌體並通過 G7。

## LLM 裁判（每個實驗）

由 [judge-bundle.sh](./judge-bundle.sh) 把實驗整理成一份固定格式的文字檔，交給
[JUDGE.md](./JUDGE.md) 所定義的裁判。題目固定為四題，只能回答 YES 或 NO：

| | 問題 | 回答 YES 的條件 |
| --- | --- | --- |
| **J1 宣稱有根據** | README 與 WHY 的每一個宣稱，是否都能對應到 bundle 中的一個定理、一段 capture 或一份板子紀錄？ | 沒有任何一句超出實際證明或實際執行過的內容 |
| **J2 定理即是所說** | 主要定理的 Lean 敘述，是否就是 README 說的那件事，且至少一個是 `from_boot` 形式（關於 kernel 的位元組、精確的指令數）？ | README 說「任何輸入」，定理就對任何輸入成立；README 說「任何位置」，定理就沒有把位置固定 |
| **J3 有新東西** | 和 bundle 列出的既有實驗相比，是否至少有一項新東西：新的 kernel、新的性質、新的推論、或新的可檢驗預測？ | 能指出那一項，並引用它 |
| **J4 參考實作獨立** | 參考實作（Python 等）是否獨立於 Lean 規格寫成，而不是逐行翻譯？ | 寫法不同（例如逐格寫 vs. 位元運算），或 README 明說兩者的差異 |

（原 J3「定理不平凡」已併入 J2：G1.5 擋下結論就是 `True` 的定理；`1 = 1`、矛盾的假設這類 G1.5 擋不住的，J2 的題目要求判 NO。G3 的 mutant 由提案者自己挑，可以完全不碰主要定理，所以不能單靠它保證不平凡。）

### 判定規則

1. **抽檢驗收模式（Spot-Check Mode）**：
   一份提案包含 5 個實驗（`exp101`–`exp105`）。為避免 LLM 額度枯竭並降低驗收負擔，裁判採**抽檢模式**：
   - **一般實驗預設單次確認（1 run）**：五個實驗中，四個實驗預設各跑**一次**判定。若四題皆有效且為 YES，即為通過（PASS）；若任一題為 NO 則直接 FAIL。
   - **抽驗實驗採完整三次判定（3 runs）**：任務方自五個實驗中**隨機**抽檢 **1 個實驗**（`audit-proposal.sh` 預設隨機抽，提案者事先無從得知；只有重新驗收時才指定），進行完整的 3 次獨立判定。抽驗實驗必須三次皆有效且一致為 YES 才能 PASS。
   - **抽檢失敗的連帶效果**：若抽驗實驗未達 PASS（出現 SPLIT 或 FAIL），則該提案撤銷單次確認資格，其餘 4 個實驗全數升級必須補滿 3 次判定。
   - **總次數與額度節省**：整份提案的判定次數由 $5 \times 3 = 15$ 次降為 $4 \times 1 + 1 \times 3 = 7$ 次，**減少 53%**。分級模式下每次判定是兩個 session（Sonnet 一個、Opus 一個），所以是 14 個 session。抽驗失敗時其餘四個補滿，回到 15 次。
2. **模型分級調度（Tiered Judge）**：
   每次判定均採模型分級執行：
   - **J2（定理即是所說）**：由 **Opus 5.5** 專門判定，輸入為 J2 專題切片（README、WHY 與 Lean 的定義和定理敘述）。在 exp225、exp230、exp234 上實測為完整 bundle 的 42%–61%（32k–59k 字元，以字元數估算約 9k–17k tokens），Opus 讀的量約為單獨判四題時的一半，也不必讀日誌與 capture。
   - **J1（宣稱有根據）、J3（有新東西）、J4（參考實作獨立）**：由 **Sonnet 5.5** 判定。這三題本質為檢索與字面比對，由 Sonnet 處理即足夠精準且極低耗能。
   - 由 `judge-bundle.sh judge` 自動分級調度並整合成單一 `VERDICT vk26` 紀錄；每個 session 都以一則訊息送出、不給工具。兩個 session 的提示詞都由 [JUDGE.md](./JUDGE.md) 組出（只留該 session 要回答的題目），不另寫一份；`judge-bundle.sh prompt J2` 或 `prompt J1,J3,J4` 印出實際送出的提示詞。bundle 採用**專題切片（Slice Bundle）**，排除與裁判無關的建置檔案與冗餘日誌。開發者亦可使用 `judge-bundle.sh slice <EXPDIR> <J1|J2|J3|J4>` 抽取單題切片進行超低 token 自檢。
3. 每個回答都必須附上 `檔案:行號` 的證據，而且該行必須真的存在於 bundle 中。缺證據或證據不存在，該回答**無效**。由 `judge-bundle.sh tally` 自動檢查。
4. **判定統計（由 `judge-bundle.sh tally` 執行）**：
   - **單次確認（1 run，一般實驗）**：
     - 四題皆有效且都是 YES → **PASS**
     - 任何一題是 NO → **FAIL**
     - 其他（有無效回答、缺引用） → **HUMAN**
   - **抽檢／完整判定（3 runs，抽驗實驗或爭議覆核）**：
     - 每一題三次都有效且都是 YES → 該題 **YES**
     - 每一題三次都有效且都是 NO → 該題 **NO**
     - 其他（不一致、有無效回答） → 該題 **SPLIT**
     - 四題都是 YES → **PASS**；任一題是 NO → **FAIL**；其他 → **HUMAN**
5. bundle 的注入掃描有命中，或任何一次裁判回報 `INJECTION`，該實驗一律 **HUMAN**。
6. LLM 不能推翻 G1–G6：bundle 中的機器關卡結果是既定事實，裁判只回答 J1–J4。
7. **申訴**：提案者可以提交一次書面反駁，放進 bundle 後重新判定三次；仍有爭議時由任務方決定。

### 校準

正式使用前，裁判必須在已知答案的範例上全部判對，結果記錄在 [calibration/](./calibration/)：

- **已知好的**：本 repo 的 exp225、exp230、exp234 → 必須 PASS
- **已知壞的**（由 `calibration/cases.sh` 從上面三個實驗製作）：
  - 誇大宣稱 → J1 NO
  - 主要定理被換成 `True` → 由 G1.5 機器關卡直接擋下（若進裁判則 J2 NO）
  - 定理被縮窄（只對位置 0 成立），README 仍說「任何位置」 → J2 NO
  - 夾帶給裁判的指示加上誇大宣稱 → 注入命中、J1 NO、結果 HUMAN

JUDGE.md、bundle 的組法每改一次，就重跑一次校準。**校準採模型分級（J2 Opus + 其餘 Sonnet）**。
分兩階段，由 `calibration/run.sh` 執行，同時最多 3 個 session：

- **階段 A**：每個案例一次（7 次）。有任何一個不對，就先修正，不進階段 B。
- **階段 B**：階段 A 全對，才每個案例再跑兩次，湊足三次，統計。

提案者的自我檢查可用 `calibration/run.sh sonnet`（全 Sonnet 5.5，一次）；亦可用 `calibration/run.sh opus` 跑全 Opus 基準。

## 現場上板（G7，每個有韌體的實驗）

在指定的大學，由任務方執行，流程固定：

1. 任務方在自己的電腦上 clone PR head，建出 UF2，確認雜湊等於 commit 進來的 `<name>.uf2.sha256`。不使用提案者帶來的檔案。
2. 任務方親手把 UF2 燒錄到**任務方的** RP2350 開發板。
3. 紀錄由任務方的裝置收集：`yi26 log --json`，或任務方手機上的網頁 Copy。
4. 紀錄存成 `board/vk26-<日期>.txt`，以提案者自己的參考實作 `--board` 檢查（照 exp232、exp234 的寫法）：每一行都要和參考實作一致，且只要改動紀錄中的一處就會被拒絕（至少示範兩種改法）。
5. 實驗 README 所寫的板子上可觀察的宣稱（LED 樣式、指令數、試驗結果等），逐項在現場確認，任務方在 PR 上留言記錄結果。

提案者自己的上板紀錄（`board/round1.txt` 等）是開發證據，**不能取代 G7**。
