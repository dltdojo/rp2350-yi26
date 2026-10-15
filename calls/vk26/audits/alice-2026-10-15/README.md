# vk26 驗收試跑：alice（2026-10-15）

<!-- SPDX-License-Identifier: Apache-2.0 -->

[ACCEPTANCE.md](../../ACCEPTANCE.md) 的流程第一次對真的提案從頭跑到尾：`audit-proposal.sh calls/vk26/alice`，機器關卡（[gates.sh](../../gates.sh)）全過才呼叫裁判；抽檢模式，抽中的實驗判三次，沒通過就其餘四個補滿三次。目的是找出**驗收流程與程式**的問題，不是讓 alice 通過。G7（任務方現場上板）不在這次範圍。

每一輪的目錄留下抽中的實驗、每次判定（`*-N.txt`）、每個 session 的用量（`*.usage`）、機器關卡的結果（`gates/`）與整份輸出（`audit.log`）。bundle 每份 170–280 KB，不放進 repo，可由當時的 commit 以 `judge-bundle.sh bundle` 重新產生。

## 結果

| | 第 1 輪（[round1/](./round1/)） | 第 2 輪（[round2/](./round2/)） |
| --- | --- | --- |
| 抽中 | vk26-alice-1 | vk26-alice-3 |
| 機器關卡 S1–S4、G1.5、G2、G6、check.sh | 五個全過（S2 未跑：這個 branch 也有設定的 commit，另行檢查，見下） | 五個全過 |
| alice-1 | J1 NO NO NO → FAIL | 四題 YES ×3；一次回報注入 → HUMAN |
| alice-2 | J1 NO ×3、J2 分歧；注入掃描 2 個命中 → HUMAN | J1 YES YES NO → HUMAN |
| alice-3 | J1 NO ×3 → FAIL | J1 NO ×3 → FAIL |
| alice-4 | J1 NO ×3 → FAIL | J1 無效 NO NO → HUMAN |
| alice-5 | J1 NO ×3、J2 分歧 → FAIL | J1 分歧、J2 分歧；一次回報注入 → HUMAN |
| J3、J4 | 每一次都 YES | 每一次都 YES |
| session | 36（3 個因帳號用量上限失敗） | 35（3 個失敗） |
| 用量 | 2,389,479 + 81,363 tokens，$6.49 | 2,475,221 + 129,886 tokens，$7.26 |

兩輪的抽驗實驗都沒通過，所以其餘四個都補滿三次：每輪是 15 次判定、30 個 session，不是抽檢模式省下來的 7 次。

S2 另行檢查：從 alice 第一個 commit 起的 81 個 commit，69 個只動 `alice/`，11 個只動設定，1 個兩者都動（89931d7：把實驗識別碼改成 `vk26-alice-N` 時，設定與 alice 的目錄一起改名）。真正的流程裡，那是任務方先改設定、提案者再跟著改名，兩個 PR。

## 流程與程式的問題，以及修正

第 1 輪找到的（修正在 162d2ac、a1ae250）：

1. **上板紀錄只留 exp232 的行種**（`PATIENT`、`TRIAL`、`SEARCH`、`PLAN`）：alice-1 的 7 行 `STREAM`、17 行 `DIGEST` 從沒送到裁判，三次都判它的板子表格沒有根據。改成任何大寫行種少於 20 行的都留下。
2. **改過的 bundle 沿用舊的判定**：重跑驗收會拿舊判定去對新 bundle。改成 bundle 變了，那個實驗的判定就移到一旁重判。
3. **執行中修改 `audit-proposal.sh` 會讓它中斷**（exit 127）：改成整份讀完才執行。
4. **xargs 收到 255 立刻結束**：還在跑的那一次判定被當成「沒寫出判定」，之後才寫出檔案。改成以旗標停止排隊，已經開始的跑完才檢查。
5. **機器關卡的結果以 commit 為鍵**：改了驗收腳本本身就要再跑五次 check.sh（35 分鐘）。改成以關卡實際讀的 git tree 為鍵。
6. **注入掃描把「這頁 judges 每一條樣本流」當成對裁判說話**，tally 只說「2 個命中」。改成印出命中的位置；徵集 README 寫明哪些字會觸發。

第 2 輪找到的（本次 commit）：

7. **AGENTS.md 要每個網頁帶的那段給 AI agent 的說明**（「IF YOU ARE AN AI AGENT: this page is not how you read the log…」），裁判也是 AI，15 次中有 2 次把它回報為注入，alice-1 四題全 YES 仍成了 HUMAN。這是 repo 自己的規則和裁判規則的衝突。bundle 現在把**一字不差**的這段換成一行說明、保留行號（像省略證明本體一樣）；別的寫法照樣送給裁判，注入掃描讀的是原始檔案。校準的七個 bundle 都不含這段，修改前後逐位元組相同。

另外，**帳號的用量上限**：一輪驗收約 35 個 session、250 萬 tokens，兩輪都在中途碰到上限。`audit-proposal.sh` 停下、保留已完成的判定、重跑只補缺的，這個設計在真實情況下有效；但任務方要預期一份提案的驗收可能要分兩段跑。

## 裁判本身

- 理由具體、可以查證，而且三次之間一致：第 1 輪 alice-1 三次都指向同一張表；第 2 輪 alice-3 三次都指向 README 448–454 行。
- 它抓到的 alice 錯誤都是真的：alice-4 寫「每次 Generate 呼叫 ADD 五次」，實際是 m + 3 次；alice-5 寫「恰好 241 條指令」，定理只說「241 步內停下」，少了第 240 步仍在執行的那一半（框架自己的 `Trust` 定理有）；README 裡由人看紀錄算出來、沒有程式印出的數字（兩輪比較、哪幾組比較慢、遺失哪幾組），其中一個範圍還寫錯了（alice-4 的 69–72，第 70 組其實不慢）。
- J1 有分歧（2 比 1）：單次確認的實驗若碰到，結果取決於那一次。三次共識把它們交給人，是設計上的保護。
- J3、J4 兩輪 30 次判定全是 YES。

## alice 尚待修正（提案者的工作，未做）

- alice-3：README 引用的 revision 1、2 快取組位置（`llvm-nm` 算的）、408 次探測的總數、原始 TRNG 的 1 的比例，要由 commit 進來的程式印出，或刪掉。
- alice-4：ADD 的呼叫次數；README 對 `lean/Rv32/Ct.lean` 的描述需要證據或刪掉。
- alice-5：定理加上「第 240 步仍在執行」使「恰好 241」成立，或 README 改說「241 步內」；「涵蓋五個實驗的每一個數字」需要連結其他實驗的 capture。
- alice-2：關於 exp223 的 334284 條指令、alice-1 的 HALT 0 位置，需要連結證據。
