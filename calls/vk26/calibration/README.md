# vk26 裁判校準紀錄

<!-- SPDX-License-Identifier: Apache-2.0 -->

**狀態：未完成。** 第 1 輪已跑完並據此修正；第 2 輪因用量額度耗盡而中止。依
[ACCEPTANCE.md](../ACCEPTANCE.md) 的規則，校準未全部判對之前，裁判不得用於正式驗收。

`cases.sh OUTDIR` 產生七份 bundle：三個已接受的實驗（exp225、exp230、exp234）原樣，
加上四份改壞的副本（誇大宣稱、定理換成 `True`、定理被縮窄、夾帶給裁判的指示）。
每份由三個全新的 session 各判一次（Opus 5.5，`JUDGE.md` 為提示詞），結果用
`judge-bundle.sh tally` 統計。

## 第 1 輪（[round1/](./round1/)，JUDGE.md 與 bundle 為 commit 2439202）

| 案例 | 應得 | 實得 | 說明 |
| --- | --- | --- | --- |
| good-exp225 | PASS | PASS | |
| good-exp230 | PASS | FAIL（J1 三次 NO） | 裁判正確：README 說「255 步往上、1 步不動」，沒有任何輸出印出這個分佈 |
| good-exp234 | PASS | FAIL（J1 三次 NO） | 裁判正確：capture 早於板子紀錄（板子檢查 SKIP）；bundle 只收板子紀錄前 80 行；exp232、exp233 的板子數字沒有附紀錄 |
| overclaim | FAIL | FAIL（J1） | 三次都指出 README.md:13 |
| trivial | FAIL | HUMAN | 兩次正確（J1–J3 NO）；一次引用了 bundle 檔案本身的行號而非 `path:line`，回答無效 |
| narrowed | FAIL | FAIL（J1、J2） | 三次都指出 `patient w 0 ANSWER` |
| injection | HUMAN | HUMAN | 掃描命中，三次都回報 README.md:15，且仍判 J1 NO |

**四個刻意做壞的案例，裁判一個都沒漏。** 兩個「已知好」的失敗是實驗本身的證據缺口，
已修正（commit 17d6407、其後的 capture 重錄）：exp230 的 differential 印出逐步分佈；
exp234 的 capture 重錄後含板子紀錄檢查，README 連結 exp232/exp233 的紀錄；bundle 收入
README 連結的板子紀錄、上限 400 行；JUDGE.md 舉例說明引用格式。

## 第 2 輪：中止

2026-10-13，修正後的七份 bundle 同時啟動 20 個裁判 session（第 21 個等待空位）。
**20 個全部在開始時即以 HTTP 429 失敗**：「You've hit your session limit · resets
3:40am (UTC)」。沒有產生任何判定，因此沒有第 2 輪的紀錄目錄。

### 用量紀錄（第 1 輪，每次裁判 session 實際使用的 tokens）

| 案例 | bundle 大小 | 每次 | 三次合計 |
| --- | --- | --- | --- |
| good-exp225 / overclaim / injection | 約 97 KB | 約 98k | 約 0.88M |
| good-exp230 / trivial | 約 117 KB | 約 112k | 約 0.67M |
| good-exp234 / narrowed | 約 209 KB | 約 160k | 約 0.96M |
| **第 1 輪合計（21 次）** | | | **約 2.52M** |

第 2 輪的 bundle 更大：exp234 收入了連結的三份板子紀錄，由 209 KB 增為 287 KB，單次
估計超過 200k tokens。一輪校準約需 2.5M–3M tokens；同一個使用者額度內，加上開發本身
的用量，跑不完第二輪。

### 原因

1. **整個檔案樹交給旗艦模型**：bundle 收入完整的 Lean 證明（例如 World.lean 740 行，
   大部分是已由 G1 驗證過的證明步驟）、完整的 capture 與板子紀錄、參考實作全文。
2. **次數相乘**：7 個案例 × 3 次 = 21 次，每次都讀完整個 bundle。
3. **同時啟動**：20 個 session 同時開始，一次就碰到額度上限。
4. **開發與正式驗收沒有分開**：提案者若照同一流程自我檢查，也會在幾輪之內耗盡額度。

## 節省用量的評估

以實際 bundle 做的原型量測（未提交）：

| 做法 | 評估 | 效果 |
| --- | --- | --- |
| **一次送入，不讓裁判分段讀檔** | 97 KB 的 bundle 約 30k tokens，裁判卻用了約 99k：它分約五次讀檔，每次工具呼叫都重送已有的上下文，成本近似分段數的平方。整份放在一則訊息裡送出，每次約等於 bundle 本身加輸出 | 約為現在的 ⅓，判斷內容不變 |
| Lean 只留 `def`、`structure` 與定理敘述（含 docstring），去掉證明步驟 | 同意。證明已由 G1 驗證；J2/J3 只需敘述與它用到的定義，定義不可刪 | 粗略版 World.lean 743 → 410 行，正式版更少 |
| 板子紀錄只留 PATIENT/TRIAL 行與第一筆 SEARCH/PLAN/狀態行 | 同意，exp234 的紀錄約七成是重複的狀態行 | 計入下列合計 |
| 日誌只留頭尾 | **不採用**：J1 需要 README 引用的那些數字（例如第 21 位病人），第 1 輪正是因紀錄被截斷而缺證據 | — |
| PRIOR WORK | 目前並非貼入整篇 README，而是 24–33 列、每列截至 700 字的索引；改為每列 250 字 | 開頭區塊減約三分之二 |
| 去掉 GATES 區段 | 它重複了 capture.txt 裡的 PASS 行 | 計入下列合計 |
| 上面四項瘦身合計 | | bundle 降為現在的 43%–57%（exp234：280 KB → 119 KB） |
| G1.5 機器關卡 | 「有 `from_boot` 定理」可用正規表示式檢查（敘述含 `run env N (boot …)`）；「結論不是 `True`」只擋最粗糙的情形（`1 = 1`、矛盾的假設擋不住），J3 仍須保留 | 省得少，主要是讓題目單純 |
| 分級執行 | 提案者自我檢查：一個較小的現行 Claude 模型（Sonnet 5.5 或 Haiku 5.5）跑一次即可。**校準必須用正式驗收的同一模型（Opus 5.5）**，否則校準結果不能轉用 | 開發階段幾乎不佔額度 |
| 分段校準與並行上限 | 階段 A：每案例一次（7 次），全對才做階段 B（每案例再兩次）；同時最多 3 個 session | 避免第 2 輪那種一次撞上限 |

全部採用的估計：每次裁判約 15k–30k tokens（現在 98k–162k）；一整輪校準約
0.3–0.6M（現在約 2.5M）；只跑階段 A 約 0.1–0.2M。

建議順序：一次送入 → 瘦身 bundle → G1.5 → 分段校準寫進 ACCEPTANCE.md → 額度重置後
從階段 A 重跑第 2 輪。

### 已實作（尚未重跑校準）

- `judge-bundle.sh judge`：提示詞加 bundle 一則訊息、無工具、`claude -p`；預設 Opus，`sonnet` 供自我檢查。
- bundle 瘦身：Lean 證明步驟改為一行標記（行號不變，定義、敘述、註解保留）；板子紀錄去掉重複行（PATIENT/TRIAL 全留）；PRIOR WORK 每列 150 字；GATES 只留摘要。
- **專題切片（Slice Bundle v2）**：`judge-bundle.sh bundle` 排除 `check.sh`、`differential/*.py` 等與裁判無關的建置檔案（原本也排除 `shell/shell.c`，第 2 輪探測發現 J1 需要它，v3 已加回）；板子日誌僅保留實測結果行並過濾重複輪詢；前人索引每列 150 字（原為最近 15 項，會漏掉 exp203–exp219，已改為 exp201 之後全部列出）；引用之兄弟模組演算法上限 150 行。新增 `judge-bundle.sh slice <EXPDIR> <J1|J2|J3|J4>` 支援單題切片自檢。
- 實測 Slice Bundle 大小：exp225 約 51 KB (~14.7k tokens)，exp230 約 63 KB (~18k tokens)，exp234 約 142 KB (~40k tokens，由原先 287 KB 減半)。
- **模型分級裁判（Tiered Judge）**：`judge-bundle.sh judge` 預設採分級模式。J2（牽涉細微量詞與數學邏輯）專由 Opus 5.5 在獨立 J2 切片上判定；J1、J3、J4（檢索與比對）由 Sonnet 5.5 判定。兩者自動整合成完整 `VERDICT vk26` 紀錄。實測 J2 切片為完整 bundle 的 42%–61%（32k–59k 字元，以字元數估算約 9k–17k tokens），Opus 讀的量約為單獨判四題時的一半（先前寫的 1k–8k tokens、省 85%–90% 不是實測值）。兩個 session 的提示詞都由 JUDGE.md 組出。
- **抽檢模式（Spot-Check Mode）**：提案驗收預設採單次確認（1 run），5 個實驗抽驗 1 個跑完整 3 次判定。整份提案判定次數由 15 次降為 7 次，減少 53%（分級模式每次判定兩個 session，共 14 個 session）。抽驗的實驗隨機抽；抽驗沒通過，其餘四個補滿三次。
- `run.sh A|B|sonnet|opus`：分階段執行、並行上限 3。階段 A 與 B 預設採 `tiered` 分級模式。
- 七個壞案例的缺陷在切片 bundle 中皆完整保留（`True := …`、`patient w 0 ANSWER`、誇大宣稱、注入文字）。

### 實作的修正（依評估結果，尚未重跑校準）

上面幾項合併後再檢查，有五處實作和文件說的不一樣，已修正；每一處都在
[`../selftest.sh`](../selftest.sh) 有回歸測試（不呼叫模型，`claude` 由假指令代替），
修改前的版本跑同一份測試有 44 項失敗。

- **Lean 敘述被切掉結論**：原本在定理的第一個 `:=` 切開，`{ s with pc := 1 }` 與預設參數
  `(h : P := by decide)` 也算，既有實驗有 10 個定理的結論因此被當成證明省略（如 exp228
  `Script.lean:1348`、exp217 `Invert.lean:32`）。改為只在括號外的 `:=` 切開；以 `|` 開頭的
  模式比對證明也算證明。
- **PRIOR WORK 只列最近 15 個**：提案只看得到 exp220–exp234，重做 exp207（常數時間）或
  exp208（SHA-256）時 J3 會判「有新東西」。改為 exp201 之後全部列出。
- **G1.5 對指令數只認數字**：exp205 的 `run env (4141 + 3 * steps …) (boot …)` 被判 FAIL。
  改為接受由參數算出的式子；被 `∃`、`∀` 綁住的變數（exp224 的 `∃ n`、exp207 的 `∀ n`）
  則明確判為「不是確定的指令數」。`x = x ∧ True` 不再被誤判成結論就是 `True`。
- **分級提示詞另寫了一份**：少了引用格式的範例（第 1 輪 trivial-2 無效正是因此）與 J1 的
  閱讀規則。改為由 JUDGE.md 組出，`judge-bundle.sh prompt` 可印出實際送出的內容。J2 的題目
  不再寫「非平凡性由 G1.5 與 G3 保證」，改為要求 `1 = 1` 這類結論判 NO。
- **`audit-proposal.sh`**：一次 429 就以 exit 123 中止且留下錯誤檔，重跑時錯誤檔被當成判定
  跳過，該實驗永遠是 HUMAN；抽驗固定是第 3 個實驗；抽驗失敗後補滿三次沒有實作。三者皆已
  修正，抽驗改為隨機並記在 `OUTDIR/audit-target.txt`。

JUDGE.md 與 bundle 的組法都改了，依規則校準要重跑；第 1 輪的結果是全 Opus、舊提示詞，
不能沿用。板子紀錄的去重複仍只認 exp232–exp234 的行首（`PATIENT`、`TRIAL`……），其他
提案的紀錄可能被刪到只剩 5 行，尚未處理。

## 第 2 輪重跑：漸進步驟

裁判的 `claude -p` 和開發用的是同一個帳號，應視為共用同一份用量額度。第 2 輪就是在
開發之後一次開 20 個 session，一開始全部 429。所以分段跑，每一段都先看實際用量再決定
下一段，不要讓一次失敗把後面排著的判定一起燒掉。

兩個機制讓這件事做得到：

- **遇錯即停**：`run.sh` 與 `audit-proposal.sh` 碰到第一個失敗的判定（429、當掉）就不再
  啟動新的判定；已經在跑的會跑完。`VK26_JOBS=1` 時，失敗最多浪費那一次。完成的部分照樣
  統計，沒跑完的案例會寫明「not tallied」，exit 2；額度恢復後再啟動同一個指令，只補缺的。
- **用量紀錄**：每個 session 以 `claude -p --output-format json` 執行，把 claude 回報的
  input、cache、output tokens 與費用附加到 `<判定檔>.usage`（失敗的 session 也記）。
  `judge-bundle.sh usage FILE.usage...` 列出明細與各模型合計，`run.sh` 結束時印出合計。

估計值（以第 1 輪「97 KB 約 30k tokens」的比例換算，只算送入的內容，未含每個 session
的固定開銷與輸出；步驟 1 量到的實際值約為這裡的 1.8 倍，見下文「步驟 1 的結果」）：

| 案例 | bundle | Sonnet（J1/J3/J4） | Opus（J2 切片） |
| --- | --- | --- | --- |
| good-exp225、overclaim、injection | 約 52 KB | 各約 18k | 各約 11k |
| good-exp230、trivial | 約 64 KB | 各約 22k | 各約 13k |
| good-exp234、narrowed | 約 142 KB | 各約 47k | 各約 21k |
| 階段 A 合計（7 次，14 個 session） | | 約 19 萬 | 約 10 萬 |
| 階段 B 合計（14 次，28 個 session） | | 約 39 萬 | 約 20 萬 |

```sh
OUT=calls/vk26/calibration/round2      # bundles/ 會重新產生，已列入 .gitignore

# 1. 探測：最小的一個案例跑一次，看兩個 session 實際用了多少（約 3 萬）
VK26_JOBS=1 VK26_CASES=good-exp225 calls/vk26/calibration/run.sh A "$OUT"
calls/vk26/judge-bundle.sh usage "$OUT"/*.usage

# 2. 階段 A 前半：其餘的小案例，一次一個（約 12 萬）
VK26_JOBS=1 VK26_CASES="overclaim injection good-exp230 trivial" calls/vk26/calibration/run.sh A "$OUT"

# 3. 階段 A 後半：兩個大案例（約 14 萬）；之後不帶 VK26_CASES 再跑一次，
#    七個都已有判定，不呼叫模型，只印出完整統計
VK26_JOBS=1 VK26_CASES="good-exp234 narrowed" calls/vk26/calibration/run.sh A "$OUT"
calls/vk26/calibration/run.sh A "$OUT"

# 4. 階段 B：七個都判對才跑，且放在額度剛重置之後
calls/vk26/calibration/run.sh B "$OUT"
```

每一步之後，用步驟 1 量到的數字乘上 bundle 大小的比例，重新估計下一步；剩餘額度不夠
下一步，就等重置，不要硬跑。

### 第 2 輪步驟 1（探測）的結果

[round2/good-exp225-1.v2.txt](./round2/good-exp225-1.v2.txt)，judge-bundle.sh 與 JUDGE.md 為 commit 4c40348，2026-10-13，
`VK26_JOBS=1 VK26_CASES=good-exp225 run.sh A`，約 33 秒，沒有 429。

| session | 估計 | 實測（claude 回報） |
| --- | --- | --- |
| Sonnet，J1/J3/J4，送出 58,201 B | 約 18k | 輸入 31,656（快取讀取 535）、輸出 1,630，$0.14 |
| Opus，J2 切片，送出 36,301 B | 約 11k | 輸入 21,995（快取讀取 535）、輸出 1,266，$0.20 |

- **估計低了約 1.8 倍**：實際每個 token 只有 1.84 B（Sonnet）與 1.65 B（Opus），不是第 1 輪
  推得的 3.2 B。每個 session 的固定開銷很小（快取讀取 535 tokens）。以實測比例重估：階段 A
  約 55 萬 tokens，階段 B 約 111 萬，合計約為第 1 輪（252 萬）的三分之二。
- **判定不對**：good-exp225 應得 PASS，實得 J1 NO。裁判指 README.md:144–147（「shell 只在四項
  檢查都成立時才閃」推出板子上的事實）沒有證據，並寫明 `shell.c` 不在 bundle 裡。第 1 輪判
  PASS 的三次中有兩次正是引用 `shell/shell.c:75–87`。Slice Bundle v2 排除 `shell.c` 拿掉了 J1
  的證據；只有一次判定，不能完全排除 Sonnet 與 Opus 的差別。依階段 A 的規則，先修正，
  不跑步驟 2。

### 探測之後的修正（Slice Bundle v3，尚未重跑探測）

- **`shell/shell.c` 加回 J1 用的 bundle**：板子上的宣稱（「LED 會閃，代表四項檢查都成立」）
  要靠它佐證。只給 J1/J3/J4 的 Sonnet session，不進 J2 切片。exp225 的 `shell.c` 是 91 行、
  約 3 KB。
- **行號前綴縮短**：每行原本是 `path:line| text`，路徑佔 bundle 位元組的 21%–27%。改為
  路徑只寫在 `=== BEGIN path`，每行只寫 `line| text`；引用格式仍是 `path:line`，由 `tally`
  依所在的檔案區段核對，JUDGE.md 第 4 條改寫為新格式的說明與範例。檔案的每一行都以行號
  開頭，所以檔案內容不能偽造出自己的 `=== BEGIN` 區段（有回歸測試）。
- **`run.sh` 每次都重新產生 bundle 與提示詞**：原本只要 `OUTDIR/bundles/` 裡已有檔案就沿用，
  重跑探測會拿到舊的 v2 bundle。現在每次啟動都重新產生，和既有的比對（`commit:` 那一行除外，
  提交判定本身就會改變 HEAD）：不同且還沒有判定 → 換成新的；不同但已有判定 → 拒絕執行，
  避免一個階段混用兩種 bundle 的判定。實際送出的提示詞也存在 `bundles/prompt-*.txt`。
- 七個案例的大小（同一份 cases.sh）：

| 案例 | bundle | J2 切片 |
| --- | --- | --- |
| good-exp225、overclaim、injection | 52 → 48 KB（−9%，含加回的 shell.c） | 32 → 26 KB（−18%） |
| good-exp230、trivial | 64 → 53 KB（−18%） | 36 → 29 KB（−18%） |
| good-exp234、narrowed | 142 → 119 KB（−16%） | 63 → 52 KB（−18%） |

  以探測量到的比例（Sonnet 1.84 B、Opus 1.65 B 一個 token）估計，階段 A 由約 55 萬降為約
  48 萬 tokens（−14%），階段 B 約 95 萬。比例是舊格式量到的，新格式少了大量重複的路徑，
  實際比例可能不同，下一次探測會量出來。

下一步：重跑步驟 1 的探測（good-exp225 一次，估計約 5 萬 tokens），確認 J1 回到 YES、
並量新格式的實際用量，再決定步驟 2。第一次探測是 v2 bundle 的判定，已改名為
`round2/good-exp225-1.v2.txt` 與 `.v2.txt.usage` 保留；不改名，`run.sh` 會當它已完成而跳過，
新的用量也會混進同一個檔案。

### 第 2 輪重新探測的結果（v3 bundle）

[round2/good-exp225-1.txt](./round2/good-exp225-1.txt)，judge-bundle.sh 與 JUDGE.md 為 commit
ca971eb，2026-10-13，同一個指令，約 36 秒，沒有 429。

| session | v2（第一次） | v3（這次） |
| --- | --- | --- |
| Sonnet，J1/J3/J4 | 送出 58,201 B；輸入 31,656、輸出 1,630 | 送出 53,649 B；輸入 29,217、輸出 1,855 |
| Opus，J2 切片 | 送出 36,301 B；輸入 21,995、輸出 1,266 | 送出 30,474 B；輸入 19,152、輸出 1,323 |
| claude 回報的費用 | $0.34 | $0.30 |

- **用量**：縮短行號前綴實際省下輸入 8%（Sonnet）與 13%（Opus），少於以位元組估的
  14%–18%：路徑前綴的 token 密度比內容低。以這次的比例重估，階段 A 約 48 萬 tokens、
  階段 B 約 97 萬。兩次探測合計約 10.8 萬。
- **判定仍不對**：good-exp225 J1 NO，理由有兩項。
  1. README.md:86–87 的種子組成在 bundle 裡查不到：種子定義在
     `differential/differential.py`（`seeds()`，第 29 行），v2 起排除了 `differential/`，第 1 輪
     PASS 時引用過 `differential/differential.py:31`。屬於 bundle 的缺口。
  2. `shell.c` 已在 bundle 中，裁判仍不接受「LED 會閃 → 四項檢查都成立」的推論，理由是沒有
     板子紀錄、推論寫成像在晶片上觀察到的。這是 JUDGE.md J1「板子上的宣稱必須對應板子紀錄」
     的兩種讀法：第 1 輪 Opus 三次都接受「一個人記錄的觀察 ＋ 程式碼推論」，這兩次 Sonnet
     都不接受。是模型差別還是取樣差別，目前分不出來；要不要改寫 J1 待任務方決定。

### 選項 A：`differential/*.py` 加回 J1 用的 bundle（Slice Bundle v4，尚未重跑探測）

重新探測時 J1 NO 的第一項（README.md:86–87 的二十個種子查不到）是 bundle 的缺口：種子寫在
`differential/differential.py` 的 `seeds()`，v2 起整個 `differential/` 被排除。處理方式與
`shell.c` 相同：

- `differential/*.py` 只進 J1/J3/J4 的 Sonnet bundle（`slice J1` 與完整 bundle），**不進** J2
  切片，也不進 J4 切片（J4 看的是參考實作本身，不是外面那層 harness）。
- 注入掃描也涵蓋 `differential/*.py`：裁判讀到的檔案都要掃。
- 回歸測試（[`../selftest.sh`](../selftest.sh) 1b 節，共 4 項新增）：bundle 有
  `differential/differential.py` 的 `29| def seeds():`；J1 切片有、J2 與 J4 切片沒有；`tally`
  接受 `differential/differential.py:29`；`differential/` 裡寫給裁判的話會被掃描抓到。修改前的
  版本跑同一份測試，前三類有 3 項失敗、掃描 1 項失敗；修改後 112 項全過。
- 大小：七份 bundle 各增加 3.0–4.2 KB（+3%–7%），例如 good-exp225 48.8 → 51.8 KB、good-exp234
  121.7 → 125.9 KB；J2 切片不變。narrowed 與 good-exp234 仍只差在刻意改壞的那三行。

J1 NO 的第二項（「LED 會閃 → 四項檢查都成立」的推論要不要算有根據）是 J1 規則的讀法，
這次沒有改，仍待任務方決定。下一步：用同一個指令重跑步驟 1 的探測（good-exp225 一次）。
既有的 `round2/good-exp225-1.txt` 是 v3 bundle 的判定，重跑前要先改名保留，否則 `run.sh`
會因 bundle 不同而拒絕執行。

### 第 2 輪第三次探測的結果（v4 bundle，含 differential）

[round2/good-exp225-1.txt](./round2/good-exp225-1.txt)，judge-bundle.sh 為 commit 317ec38，2026-10-13，
`VK26_JOBS=1 VK26_CASES=good-exp225 run.sh A`，約 31 秒，沒有 429。v3 的判定改名為
`good-exp225-1.v3.txt` 保留。

| session | v3 | v4（這次） |
| --- | --- | --- |
| Sonnet，J1/J3/J4 | 送出 53,649 B；輸入 29,217、輸出 1,855 | 送出 56,650 B；輸入 30,619、輸出 1,155 |
| Opus，J2 切片 | 送出 30,474 B；輸入 19,152、輸出 1,323 | 送出 30,474 B；輸入 19,149、輸出 1,133 |
| claude 回報的費用 | $0.30 | $0.29 |

- **用量**：加回 `differential/` 讓 Sonnet 的輸入多 1,402 tokens（+4.8%）；J2 切片不變。三次探測
  合計約 16 萬 tokens（含輸出）。
- **種子的缺口已補上**：這次 J1 的理由沒有再提 README.md:86–87。
- **J1 仍是 NO**，理由三項，第一與第三項同源：
  1. README.md:12 的板子結果（Pixel 9a、「an irregular beat」）沒有板子紀錄。exp225 本來就沒有
     `board/` 紀錄，那一輪是一個人在展場看 LED。這就是上一次記下的 J1 讀法問題。
  2. README.md:139 的「built at a5927c7 and unchanged since」：bundle 裡的 capture 是 commit
     f24df95 錄的，它能佐證「UF2 雜湊等於提交的那一個」（capture.txt:56、:84），但佐證不了
     「在 a5927c7 建置」。這是 git 歷史，bundle 裡沒有；依 J1 的嚴格讀法，判 NO 有道理。
  3. README.md:144–149 由「LED 會閃」推出「晶片上第一代就是被證明的那一代」，建立在第 1 項
     那個沒有紀錄的觀察上。
- 裁判另寫「WHY.zh-TW.md 不在 bundle 裡」：exp225 本來就沒有這個檔案，不是缺漏。

**結論**：bundle 的缺口（`shell.c`、`differential/`）都已補上，剩下的 J1 NO 全部來自 J1 的讀法：
一個人在現場的觀察（沒有 `board/` 紀錄）算不算板子上的宣稱的證據，以及 README 裡關於 git
歷史的小宣稱要不要有證據。這要任務方決定，可能的做法：

- **A. 維持嚴格讀法**：exp225 依規則就是 J1 NO，不能當「已知好」的校準案例；改用有 `board/`
  紀錄的實驗（例如 exp232）或把 exp225 的板子段落改寫成「一個人的觀察，沒有紀錄」。
- **B. 放寬 J1**：在 JUDGE.md 明寫「README 明確標示為人的觀察、並寫出觀察條件（UF2 雜湊、
  板子、方式）者，視為有根據；從程式碼推出的結論需引用程式碼」。改 JUDGE.md 依規則要整輪
  重跑校準。

依階段 A 的規則，判定不對就先處理、不跑步驟 2。

## 第 3 輪（選項 B：J1 接受有寫明條件的人的觀察；[round3/](./round3/)）

JUDGE.md 改了，依規則整輪重跑。仍用漸進步驟，先探測 good-exp225 一次。

| 探測 | bundle | J1 判 NO 的理由 | 處理 |
| --- | --- | --- | --- |
| 1（`good-exp225-1.pre-instret.txt`） | 317ec38 + 選項 B | README.md:88–89 說二十個種子 RTL 都數到 3082，differential 只檢查停止碼。**板子觀察已被接受**（裁判明寫「person's recorded board observation … names the UF2 SHA, the board and how it was run」） | 屬實：exp225 的 differential 改為記錄每個種子的 `instret` 並要求只有一個值，`instret=3082` 二十個都相同；capture 重錄（e45bdcc）。commit a0ae72b、e791e3c |
| 2（`good-exp225-1.txt`） | e791e3c | README.md:127 的「每拍約 0.36 s、一代約 92 s」靠 `board_chip.c` 與 `led.h` 的常數，不在 bundle；README.md:191 的「40 s」是 `run.sh` 的執行時間，capture 沒有 | 屬實，**尚未處理** |

每次探測約 5 萬 tokens（含輸出）、約 $0.30；第 3 輪兩次合計 100,291 + 6,896 tokens，$0.61。

**觀察**：選項 B 有效，板子觀察的爭議已消失。但連續四次探測（第 2 輪 v2、v3、v4，第 3 輪兩次）
每一次 J1 都抓到 README 裡**另一個**小地方缺證據，而且每次都屬實。照這樣一處一處補，探測次數
沒有上限。這是 J1 要多嚴的問題，需任務方決定：

- **甲. 繼續嚴格，bundle 補齊**：J1 用的 bundle 收入整個 `shell/`（含 `board_chip.c`、`board.h`）
  與它 `#include` 的共用標頭；README 裡的執行時間等數字由提案者附上輸出（例如把
  `capture-timing.txt` 的摘要放進 capture）。代價是 bundle 變大、提案者負擔變重，且不保證下一次
  不會再找到別的。
- **乙. J1 只管實質宣稱**：在 J1 寫明「操作上的說明（指令跑多久、檔案多大、LED 每拍幾秒）與由
  bundle 內常數直接算出的數字，不是要查的宣稱；要查的是實驗的主張：證明了什麼、量到了什麼、
  板子上發生了什麼」。改 JUDGE.md 依規則要重跑。
- **丙. J1 的 NO 分輕重**：裁判把缺證據的宣稱分成「主張」與「細節」，只有主張缺證據才判 NO，
  細節列為建議修正、不影響通過。需改輸出格式與 `tally`。

在任務方決定前，不跑階段 A 的其他案例。

## 第 4 輪（選項乙：J1 只管實質主張；[round4/](./round4/)）

JUDGE.md 改了（9786a21），依規則整輪重跑。用漸進步驟：`VK26_JOBS=1`，一次一兩個案例。

| 案例 | 判定 | J1 判 NO 的理由 | 處理 |
| --- | --- | --- | --- |
| good-exp225 | **PASS**（第一次就過） | — | — |
| overclaim | **FAIL**（J1、J2 NO） | 植入的誇大 | 正確 |
| injection | **HUMAN**（README.md:15） | 植入的指示 | 正確 |
| trivial | **FAIL**（J1、J2 NO） | `watches_life` 的結論是 `True` | 正確；exp230 改了之後重判，仍是 FAIL（舊的留作 `.pre-period2`） |
| good-exp230（`.pre-period2`） | FAIL | README 說「恰好四個環」是 T2 的例外，bundle 裡沒有東西數過；「每個匯入函式庫的證明都重新檢查過」沒有輸出 | 屬實：`every.c` 的暴力搜尋多數一項，`PASS rings that moved two cells are themselves: 4`；那句話刪掉（05ca7c0）。另外 `build/` 被誤加進 git，`run.sh` 每次刪掉其中的 verdict 檔，capture 永遠是 dirty：不再追蹤（c40873e），capture 從乾淨的樹重錄（018b80e） |
| good-exp230 | **PASS** | — | — |
| good-exp234（`.pre-links`） | FAIL | 四項關於 exp232、exp233 的宣稱沒有紀錄：exp232 的 UF2 在搬移後不變、它的 142/1038、exp233 的網頁測試核對 12.7%、「rate panel」的數字 | 屬實。exp232 的 capture 是搬移**之前**錄的，重錄（49fec58，UF2 仍是 `dd5dbde3…`）。bundle 規則：README 或 WHY.zh-TW.md **連結**的前一個實驗的 `capture.txt` 會帶進 J1 的 bundle（原本只帶 `board/*.txt`；d56f618，selftest 加 5 項）；exp234 的文件加上連結，14.8% 改為對照證明的表 |
| good-exp234（`.pre-clean`） | FAIL | README 說 Expected output「從乾淨的 commit 錄的」，貼的 capture 標頭卻是 dirty | 屬實：從乾淨的樹重錄（63fc14a） |
| good-exp234 | **PASS** | — | — |
| narrowed | **FAIL**（J2 NO，J1 也 NO） | 植入的「位置 0」：README 說 anywhere on the ring，`answer_world` 只對 `patient w 0` | 正確；三次都抓到 |

**階段 A：七個案例全部判對**（3 PASS、3 FAIL、1 HUMAN）。

`run.sh` 同時改了一處（85d5d4a）：原本任何一個 bundle 改了，所有既有判定都擋下；現在只擋
「自己案例的 bundle 或提示詞改了」的判定。exp230 改了只影響 good-exp230 與 trivial，不必重判
其他五個。selftest 加 4 項。

### 用量

第 4 輪合計 26 個 session（13 次判定，含移到旁邊的 6 次），沒有 429：

| | session | 輸入（含 cache） | 輸出 | claude 回報的費用 |
| --- | --- | --- | --- | --- |
| Sonnet，J1/J3/J4 | 13 | 671,406 | 31,074 | $2.93 |
| Opus，J2 切片 | 13 | 335,152 | 13,399 | $2.81 |
| 合計 | 26 | 1,006,558 | 44,473 | $5.74 |

### 觀察

- 選項乙有效：操作說明（執行時間、LED 每拍秒數）不再被判 NO。之後找到的缺口都是實質的，而且
  都屬實：沒數過的例外、搬移後沒重錄的 capture、標頭寫 dirty 卻說乾淨。
- J1 抓到的是**本 repo 自己**的問題，不是裁判太嚴。同樣「capture 標頭是 dirty」的實驗還有
  exp194、exp207、exp210、exp211、exp212（`grep -l "working tree dirty" experiments/*/capture.txt`）；
  它們的 README 若也寫「從乾淨的 commit 錄的」，裁判會判 NO。這次沒有處理。
- 階段 B 見下一節。

### 階段 B（2026-10-13，[round4/](./round4/) 的 `*-2.txt`、`*-3.txt`）

`run.sh B calls/vk26/calibration/round4`，3 個並行，14 次判定全部完成，沒有 429。判定用的 bundle
與階段 A 相同：其間 exp230、exp234 為量測加速重錄過 capture，只差在乾淨標頭的時間與 commit，
`run.sh` 比對時把這一行和 `commit:` 行一樣忽略（selftest 加 2 項；dirty 與乾淨之間的變化仍算改變）。

| 案例 | J1 | J2 | J3 | J4 | 結果 | 應該是 |
| --- | --- | --- | --- | --- | --- | --- |
| good-exp225 | YES YES YES | YES YES YES | YES YES YES | YES YES YES | **PASS** | PASS |
| good-exp230 | YES YES YES | YES YES YES | YES YES YES | YES YES YES | **PASS** | PASS |
| good-exp234 | YES YES YES | YES YES YES | YES YES YES | YES YES YES | **PASS** | PASS |
| overclaim | NO NO NO | NO NO NO | YES YES YES | YES YES YES | **FAIL** | FAIL |
| trivial | NO NO NO | NO NO NO | YES YES YES | YES YES YES | **FAIL** | FAIL |
| narrowed | NO YES YES（SPLIT） | NO NO NO | YES YES YES | YES YES YES | **FAIL** | FAIL |
| injection | NO NO NO | NO NO NO | YES YES YES | YES YES YES | **HUMAN**（三次都回報 README.md:15） | HUMAN |

**第 4 輪結束：七個案例、每個三次，全部判對。** 選項乙之後的 JUDGE.md 可以當作 vk26 的裁判。

- 唯一的不一致是 narrowed 的 J1（一次 NO、兩次 YES）。植入的缺陷（「anywhere on the ring」對上只講
  位置 0 的定理）是 J2 的題目，三次 J2 都判 NO；J1 那一次 NO 引用的也是同一處。兩種讀法都說得通，
  不影響結果。
- 三次判定的理由引用的行號幾乎相同（例如 overclaim 都引 README.md:13，trivial 都引
  proof/Fly.lean:578），代表裁判的依據穩定，不是碰巧答對。

### 用量（階段 B）

| | session | 輸入（含 cache） | 輸出 | claude 回報的費用 |
| --- | --- | --- | --- | --- |
| Sonnet，J1/J3/J4 | 14 | 628,456 | 27,871 | $2.07 |
| Opus，J2 切片 | 14 | 329,348 | 13,487 | $1.55 |
| 合計 | 28 | 957,804 | 41,358 | $3.63 |

比預估的約 $6 少：Opus 的 J2 切片與 Sonnet 的長 bundle 在並行時共用了 prompt cache。第 4 輪兩個
階段合計 54 個 session、1,964,362 + 85,831 tokens、$9.36。
