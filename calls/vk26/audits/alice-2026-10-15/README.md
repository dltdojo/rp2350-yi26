# vk26 驗收試跑：alice（2026-10-15）

<!-- SPDX-License-Identifier: Apache-2.0 -->

[ACCEPTANCE.md](../../ACCEPTANCE.md) 的流程第一次對真的提案從頭跑到尾：`audit-proposal.sh calls/vk26/alice`，機器關卡（[gates.sh](../../gates.sh)）全過才呼叫裁判；抽檢模式，抽中的實驗判三次，沒通過就其餘四個補滿三次。目的是找出**驗收流程與程式**的問題，不是讓 alice 通過。G7（任務方現場上板）不在這次範圍。

每一輪的目錄留下抽中的實驗、每次判定（`*-N.txt`）、每個 session 的用量（`*.usage`）、機器關卡的結果（`gates/`）與整份輸出（`audit.log`）。bundle 每份 170–280 KB，不放進 repo，可由當時的 commit 以 `judge-bundle.sh bundle` 重新產生。

## 結果

| | 第 1 輪（[round1/](./round1/)） | 第 2 輪（[round2/](./round2/)） | 第 3 輪（[round3/](./round3/)） |
| --- | --- | --- | --- |
| 抽中 | vk26-alice-1 | vk26-alice-3 | vk26-alice-5 |
| 機器關卡 S1–S4、G1.5、G2、G6、check.sh | 五個全過（S2 未跑：這個 branch 也有設定的 commit，另行檢查，見下） | 五個全過 | 五個全過 |
| alice-1 | J1 NO NO NO → FAIL | 四題 YES ×3；一次回報注入 → HUMAN | J1 NO YES NO → HUMAN |
| alice-2 | J1 NO ×3、J2 分歧；注入掃描 2 個命中 → HUMAN | J1 YES YES NO → HUMAN | **四題 YES ×3 → PASS** |
| alice-3 | J1 NO ×3 → FAIL | J1 NO ×3 → FAIL | J1 YES NO NO → HUMAN |
| alice-4 | J1 NO ×3 → FAIL | J1 無效 NO NO → HUMAN | **四題 YES ×3 → PASS** |
| alice-5 | J1 NO ×3、J2 分歧 → FAIL | J1 分歧、J2 分歧；一次回報注入 → HUMAN | J1 YES NO YES → HUMAN（J2 三次 YES） |
| J3、J4 | 每一次都 YES | 每一次都 YES | 每一次都 YES |
| session | 36（3 個因帳號用量上限失敗） | 35（3 個失敗） | 30（無失敗） |
| 用量 | 2,389,479 + 81,363 tokens，$6.49 | 2,475,221 + 129,886 tokens，$7.26 | 2,414,127 + 105,443 tokens，$6.92 |

三輪的抽驗實驗都沒通過，所以其餘四個都補滿三次：每輪是 15 次判定、30 個 session，不是抽檢模式省下來的 7 次。

S2 另行檢查：從 alice 第一個 commit 起的 81 個 commit，69 個只動 `alice/`，11 個只動設定，1 個兩者都動（89931d7：把實驗識別碼改成 `vk26-alice-N` 時，設定與 alice 的目錄一起改名）。真正的流程裡，那是任務方先改設定、提案者再跟著改名，兩個 PR。

## 流程與程式的問題，以及修正

第 1 輪找到的（修正在 162d2ac、a1ae250）：

1. **上板紀錄只留 exp232 的行種**（`PATIENT`、`TRIAL`、`SEARCH`、`PLAN`）：alice-1 的 7 行 `STREAM`、17 行 `DIGEST` 從沒送到裁判，三次都判它的板子表格沒有根據。改成任何大寫行種少於 20 行的都留下。
2. **改過的 bundle 沿用舊的判定**：重跑驗收會拿舊判定去對新 bundle。改成 bundle 變了，那個實驗的判定就移到一旁重判。
3. **執行中修改 `audit-proposal.sh` 會讓它中斷**（exit 127）：改成整份讀完才執行。
4. **xargs 收到 255 立刻結束**：還在跑的那一次判定被當成「沒寫出判定」，之後才寫出檔案。改成以旗標停止排隊，已經開始的跑完才檢查。
5. **機器關卡的結果以 commit 為鍵**：改了驗收腳本本身就要再跑五次 check.sh（35 分鐘）。改成以關卡實際讀的 git tree 為鍵。
6. **注入掃描把「這頁 judges 每一條樣本流」當成對裁判說話**，tally 只說「2 個命中」。改成印出命中的位置；徵集 README 寫明哪些字會觸發。

第 2 輪找到的（修正在 0201c51）：

7. **AGENTS.md 要每個網頁帶的那段給 AI agent 的說明**（「IF YOU ARE AN AI AGENT: this page is not how you read the log…」），裁判也是 AI，15 次中有 2 次把它回報為注入，alice-1 四題全 YES 仍成了 HUMAN。這是 repo 自己的規則和裁判規則的衝突。bundle 現在把**一字不差**的這段換成一行說明、保留行號（像省略證明本體一樣）；別的寫法照樣送給裁判，注入掃描讀的是原始檔案。校準的七個 bundle 都不含這段，修改前後逐位元組相同。

第 3 輪找到的（修正在 2cc2eed）：

8. **J4 看不到提案者共用的參考實作**：alice-4 的 drbg.py 只是轉出 `../tools/hashdrbg.py`，而且用 `os.path.dirname(os.path.abspath(__file__))` 而不是 `HERE` 把目錄放上路徑；bundle 只認得後者，三次 J4 都說看不到參考實作本身（仍判 YES，靠的是 JS 參考與 NIST 向量）。現在兩種寫法都跟；selftest 有這個情形，修正前會失敗。校準的七個 bundle 逐位元組相同。
9. **每輪的 bundle 目錄沒有被忽略**：第 1、2 輪是手動刪掉的。現在 `audits/*/round*/bundles/` 跟校準的一樣在 `.gitignore` 裡。

另外，**帳號的用量上限**：一輪驗收約 35 個 session、250 萬 tokens，兩輪都在中途碰到上限。`audit-proposal.sh` 停下、保留已完成的判定、重跑只補缺的，這個設計在真實情況下有效；但任務方要預期一份提案的驗收可能要分兩段跑。

## 裁判本身

- 理由具體、可以查證，而且三次之間一致：第 1 輪 alice-1 三次都指向同一張表；第 2 輪 alice-3 三次都指向 README 448–454 行。
- 它抓到的 alice 錯誤都是真的：alice-4 寫「每次 Generate 呼叫 ADD 五次」，實際是 m + 3 次；alice-5 寫「恰好 241 條指令」，定理只說「241 步內停下」，少了第 240 步仍在執行的那一半（框架自己的 `Trust` 定理有）；README 裡由人看紀錄算出來、沒有程式印出的數字（兩輪比較、哪幾組比較慢、遺失哪幾組），其中一個範圍還寫錯了（alice-4 的 69–72，第 70 組其實不慢）。
- J1 有分歧（2 比 1）：單次確認的實驗若碰到，結果取決於那一次。三次共識把它們交給人，是設計上的保護。
- J3、J4 三輪 45 次判定全是 YES。
- 第 3 輪的 J2 對 alice-5 三次 YES：「恰好 241」加上第 240 步仍在執行之後，裁判逐一核對了 `inst_boot` 與 `chain` 兩半都寫了。
- 第 3 輪的 NO 都是單次、各自指不同的地方（見下），J1 一次只回報它先看到的那一處：分歧不代表裁判不穩，而是 J1 的範圍大，三次各抽到不同的缺口。

## 第 2 輪之後對 alice 的修正（06e4001，capture 重錄後第 3 輪）

- alice-5：`inst_run`、`inst_boot`、`chain` 寫出「恰好」的兩半；`Drbg.generate_run`、`from_boot`、`generate_twice` 也是，所以 alice-4 的 `COST m` 也是恰好。各加一個「多一條指令」的 mutant，被拒絕。其他實驗的數字都連到 capture。
- alice-4：ADD 呼叫 m + 3 次；`Ct.lean` 問不了這個 kernel 改由 `proof/Drbg.lean` 的四個定理說明。
- alice-3：`fixtures.py --board` 印出原始 TRNG 的 1 的比例與 408 次探測的總數；revision 1、2 的 `FIXED` 表拿掉。
- alice-2：exp223 的 334284 與 alice-1 的 HALT 0 位置連到來源。

## alice 尚待修正（提案者的工作，第 3 輪找到，未做）

- alice-1：README 說 `win_run` 只依賴 Lean 自己的公理，但 capture 只印了 `Seam.*` 八個定理的公理（要在 `proof/Seam.lean` 加 `#print axioms Alice.Window.win_run`）；人看到的 LED 沒寫是哪個 UF2；「`front` 逐窗套用會讓兩個窗都通過」沒有程式算過。
- alice-3：README 201–205 行「alice-1、alice-2 是 +3 +4 每次 HASH、三個實驗十個數」沒連到那些 capture；WHY.zh-TW.md 112 行仍說 revision 1、2 的建置都是這個樣子（README 已改）。
- alice-5：「alice-4 的 UF2 逐位元組相同」沒有連到 alice-4 capture 裡那一行（`the UF2 is byte for byte the committed one`）。

## 之後：加入校準

alice-2、alice-4 成為校準的已知好案例（`good-alice-2`、`good-alice-4`）。第 5 輪找到兩個統計的引用問題與一個 bundle 缺口（exp225 的 `shell/board.h`），修正後第 6 輪九個案例、每個三次全部判對：[calibration/README.md](../../calibration/README.md) 最後兩節。
