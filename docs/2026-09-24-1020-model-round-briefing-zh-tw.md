# 模型先看到的 bug：可行性評估與兩個實驗的提案

**快照時間：2026-09-24 10:20 UTC** · 基準 `main` 於 `d6bfb0c`

這一份不是一輪工作的結算，是一輪工作**開始之前**的質詢——照
[每個新實驗都從質詢開始](../experiments/README.md#every-new-experiment-starts-with-an-interrogation)
的順序寫成：先確立事實、再查前例、點名矛盾、分開已決定與待決定的事。

問題是：「模型驅動的找 bug」能不能拿來除錯這裡的共用程式，並做成學生可以學的實驗？

> 1. **建模**：只挑最棘手的部分——狀態機、容易出競態的區塊——寫成 TLA+ / Lean 模型。
> 2. **找反例**：讓工具在模型裡找出違反性質的執行路徑，這些是「疑似 bug」。
> 3. **重現**：回到真正的程式碼，把它實際觸發出來。
> 4. **修正**：在程式碼裡修掉。

---

## 一句話

**可行，而且已經試過：兩個共用 crate、161 行 TLA+、每次不到一秒，得到三個在主機上
用真正程式碼重現得出來的疑似 bug——其中一個是 2026-08-30 在板子上付過代價的那一類，
模型在修正前的版本裡三步就找到，也指出那次修正沒有修到文件承諾的那一條。**

---

## 一、確立的事實

全部在雲端 session 的 scratchpad 裡做，**沒有改動 repo 的任何程式**。

### 工具

| | |
| --- | --- |
| Java | OpenJDK 21.0.10（容器內已有） |
| TLC | `tla2tools.jar`，4,493,033 bytes，sha256 `32d64fbb…aacf81` |
| 一次檢查 | 含 JVM 啟動 **0.7 秒** |

`tla2tools.jar` 是從 `releases/download/v1.8.0/` 抓的，但它自報版本是
`2026.09.23.154203`——那個網址給的是 nightly。實驗要固定的是一個正式 release 與它的
sha256，不是這一個。

### 三個疑似 bug

| | 位置 | 違反的性質（出處，逐字） | TLC | 主機重現 |
| --- | --- | --- | --- | --- |
| **H2** | `crates/ctap-hid` `Transaction::feed` | CTAP 2.1 / 2.2 §11.2.5.1、§11.2.5.3（見下） | 3 步 | 失敗的測試：A 的續傳封包被 `Ignore`，A 什麼都沒收到 |
| **H1** | `feed` + `board.rs` 的 `select` | `expire`：「Returns the channel to send `ERR_MSG_TIMEOUT` on」 | 修掉 H2 後 5 步 | 失敗的測試：逾時已判定，通知沒送出 |
| **R1** | `crates/breadcrumb` + `crates/lifeline` | `interpret`：「a fresh flash must find nothing to believe」 | 3 步 | 失敗的測試：新版第一筆是 `boot #5`、`Completed` |

**H2 —— 另一個客戶端的 INIT 讓訊息無聲消失。** A 送出一則要兩個封包的 CBOR 請求的第一個
封包；B（另一個程式，例如瀏覽器在列舉裝置）送廣播 INIT；`feed` 對任何通道的 INIT 都
`self.clear()`，A 的交易就沒了。A 接著送的續傳封包得到
`Ignore("a continuation packet with no transaction")`——**沒有錯誤、沒有回應**，A 只能等到自己逾時。

**H1 —— 逾時被判定、然後被丟掉。** `feed` 一開頭就呼叫 `expire`，但只有在過期的通道
**剛好是送這個封包的通道**時才回報。B 的封包在 A 的截止時刻之後、計時器分支被輪到之前
抵達（`select` 先輪詢讀取；前一輪卡在 `write` 上時兩者會同時就緒），A 的
`ERR_MSG_TIMEOUT` 就被算出來又丟掉，之後交易已清空，計時器也不會再為 A 觸發。

**R1 —— 同一個實驗重燒，繼承上一版的記錄。** 事實鏈，每一環都是 repo 自己量過或讀得到的：

1. `lifeline::begin` 先 `read`（消耗 token）再 `arm`（寫入 token）；`alive()` 只 `feed`，
   不收回——所以**正在執行的 lifeline 韌體，SCRATCH0 一直是自己的 token**。
2. SCRATCH0–3 撐得過 1200-baud 重燒（2026-08-30 實測，見 `ecf659e`）。
3. 同一個實驗的新版開機，`is_ours` 認得自己的 tag，於是接著舊版的開機次數與歷史往下報。

現有測試 `a_reflashed_board_does_not_inherit_the_previous_builds_death` 的前提是重燒時
`s0: 0`——正好沒有涵蓋這條路。影響 lifeline 的六個使用者：exp183、exp188、exp189、
exp190、exp193、exp194。

### TLC 的輸出（原樣）

breadcrumb，修正前（只有 MAGIC）與修正後（加 tag）：

```text
--- Breadcrumb bc_FALSE_FALSE_NeverAnotherExperimentsNote
Error: Invariant NeverAnotherExperimentsNote is violated.
State 1: <Initial predicate>
State 2: <BootselFlash("exp190a")
State 3: <Reflash1200("exp157")
12 states generated, 9 distinct states found, 6 states left on queue.
--- Breadcrumb bc_TRUE_FALSE_NeverAnotherExperimentsNote
Model checking completed. No error has been found.
136 states generated, 16 distinct states found, 0 states left on queue.
--- Breadcrumb bc_TRUE_FALSE_AFreshFlashBelievesNothing
Error: Invariant AFreshFlashBelievesNothing is violated.
State 1: <Initial predicate>
State 2: <BootselFlash("exp190a")
State 3: <Reflash1200("exp190a")
6 states generated, 6 distinct states found, 3 states left on queue.
--- Breadcrumb bc_TRUE_TRUE_AFreshFlashBelievesNothing
Model checking completed. No error has been found.
67 states generated, 8 distinct states found, 0 states left on queue.
```

最後一段的 `TRUE_TRUE` 是加上候選修正（1200-baud 重開機前收回 token）之後。

ctap-hid，兩個修正都關、只修 H2、兩個都修：

```text
--- CtapHid run_FALSE_FALSE
Error: Invariant NoSilentLoss is violated.
State 1: <Initial predicate>
State 2: <ASendInit
State 3: <BBcastInit
7 states generated, 7 distinct states found, 4 states left on queue.
--- CtapHid run_FALSE_TRUE
Error: Invariant NoSilentLoss is violated.
State 1: <Initial predicate>
State 2: <ASendInit
State 3: <Tick
State 4: <Tick
State 5: <BBcastInit
57 states generated, 46 distinct states found, 22 states left on queue.
--- CtapHid run_TRUE_TRUE
Model checking completed. No error has been found.
357 states generated, 215 distinct states found, 0 states left on queue.
```

「No error」是**在模型的範圍內窮舉**：兩個客戶端、各一則訊息、時間上限四格。它不是證明。

### 規格原文

CTAP 2.1 PS（2021-06-15）與 2.2 PS（2025-07-14）這幾段**逐字相同**：

> §11.2.5.1 — If an application tries to access the device from a different channel
> while the device is busy with a transaction, that request will immediately fail with
> a busy-error message sent to the requesting channel.

> §11.2.5.3 — If the device detects an INIT command during a transaction that has the
> **same channel id** as the active transaction, the transaction is aborted (if possible)
> and all buffered data flushed (if any).

> §11.2.9.1.3 — If sent on an allocated CID, it synchronizes **a channel**, discarding
> the current transaction, buffers and state as quickly as possible.

整份規格裡提到 busy 的規則只有第一句，**沒有「廣播 INIT 例外」**。§11.2.5.2 也沒有寫任何
逾時數字；兩版規格的全文都找不到 `750`。

---

## 二、與之前實驗的對照

這是給學生看的核心：同一個問題，用板子找與用模型找，各付了什麼。

### breadcrumb 對 exp157（`a9933bf`、`ecf659e`）

| | 用板子 | 用模型 |
| --- | --- | --- |
| 怎麼發現的 | exp157 第一次上板就報 `boot #19`、`HANG in step 92` | 修正前的版本，三步 |
| 修正驗證 | 兩次想趁重開機風暴換燒 exp158，1200-baud 都沒接上 | 「不採信別人的記錄」窮舉成立 |
| 至今的狀態 | commit 寫著「拒收別的 tag」**NOT hardware-proven** | 同上，但模型也說：文件承諾的更強性質**仍然不成立**（R1） |

最後一格是模型比板子多給的東西：**那次修正修好的，是一條比文件承諾更弱的性質。**
板子只會告訴你你問的那個問題的答案。

### exp194 的差異測試，對比性質檢查

exp194 問的是「六支韌體的答案一不一樣」。這種問法找得到分歧，**找不到大家都錯的地方**。

`busy-recovers` 案例這樣走：A 送出未完成的 PING、B 插話被拒、然後送廣播 INIT，
檢查 INIT 有沒有得到回應——**然後就停了**。A 那則訊息後來怎樣，沒有人問。H2 就在它的
下一步。

寫性質時必須挑一句規格原文，這一挑就撞上兩件事：

- `busy-recovers` 把「A 的交易還在時，廣播 INIT 要得到回應」標成 `spec`，但上面三段原文說
  的是回 busy；
- `crates/ctap-hid` 寫「750 ms is the specification's number」，但兩版規格都沒有這個數字。

兩者可能都有正當的來源（別的文件、實作慣例），但**不是 CTAP 2.1 / 2.2 的原文**，
出處要補上。

### usb-log 當負對照

用**搶佔式**排程為 usb-log 建模，會得到反例：兩個 `log!` 交錯時，遺失標記可能不落在
缺口後的第一行。但 repo 裡沒有任何韌體從 core1 或中斷呼叫 `log!`（六個 `core1_main`
都是 0 次），embassy 的執行器又是合作式的——所以第 3 步**重現不出來**。

教學重點：**反例是假設，不是 bug。**你假設的排程方式決定它存不存在；第 3 步存在的理由，
就是把用錯模型得到的假反例篩掉。

---

## 三、矛盾

1. **偏誤。** 這三個疑點是先讀程式找到、才寫模型的，TLC「再找到一次」不是獨立證據。
   緩解：breadcrumb 修正前的版本當**對照組**——那個答案早在這一輪之前就由板子給過了；
   另外加一個**盲測**目標，先把性質寫下來、提交，再跑 TLC。
2. **模型是第二份副本。** 這和
   [什麼屬於一個實驗](./what-belongs-to-an-experiment.md) 的反重複原則正面衝突：模型會
   跟程式漂開。答案：**每個反例都變成 crate 裡的 Rust 測試**，跑在真正的程式碼上，是模型
   與程式之間的橋。模型漂了，橋會斷給你看。
3. **修 H2 會碰到 exp194 已經驗證過的判定。** 照規格原文改（回 busy），`busy-recovers`
   翻盤，exp194 的 README 與 `tools/ctaphid` 的判定都要改、要重跑。
4. **`main` 需要硬體驗證。** TLC 與主機重現是 Needs 0；修正之後重跑 exp194 測試組、
   把 exp190 重燒兩次，都是 **Needs 1**——接著板子即可，夜裡跑得完。
5. **新的工具需求。** Java 11+ 與一個 4.5 MB 的 jar。早期路線只要一塊板子和一條線；
   這是第一個不需要板子、但需要 JVM 的實驗。

---

## 四、已經決定的

- **工具用 TLA+ / TLC，這一輪不用 Lean。** 這四步的核心是「找反例」，TLC 窮舉交錯執行、
  直接給路徑。Lean 強在「對所有輸入證明」，留給之後證明修正——例如 `next_cid` 永遠不回傳
  保留值、`fragment` 與 `feed` 互為反運算。
- **每條性質逐字引用出處**（文件註解或規格章節）；**每個轉移標註它翻譯的 Rust 行**。
- **模型放實驗目錄，重現測試放 crate**——模型是實驗在問的問題，測試是 crate 的行為。
- **固定 `tla2tools.jar` 的 release 與 sha256**；沒有 Java 時 `check.sh` 跳過 TLC 並說明原因，
  主機重現測試照跑。
- **H2 用寬鬆修法**：回應廣播 INIT，但不動別的通道正在進行的交易。它關掉無聲遺失、保住
  exp194 的判定；同時更正 crate 與 exp194 裡「規格要求」的說法，改成「這是穩健性的選擇」。
  照規格原文回 busy 列為開放問題，等拿一支參考認證器量過再決定。

---

## 五、兩個實驗

挑目標的標準只有一條：**事件順序會改變結果，而且錯了之後要上板才看得到的程式。**
跨重開機的狀態（breadcrumb / lifeline）、多客戶端加時間的協定狀態機（ctap-hid）
都符合；usb-log 是負對照。

### exp195 —— 模型先看到的 bug（方法，用已知答案校準）

**只證明一件事：模型在一秒內找到板子花了好幾趟才找到的 bug，也找到修正沒修到的那一條。**

| 步驟 | 內容 | Needs |
| --- | --- | --- |
| 1 建模 | `model/Breadcrumb.tla`，約 60 行：燒錄、1200-baud 重燒、BOOTSEL、死亡與看門狗 | 0 |
| 2 找反例 | 修正前：別的實驗的記錄被採信（歷史 bug）；修正後：R1 | 0 |
| 3 重現 | `crates/breadcrumb` 裡一個失敗的測試；板子上用 `yi26 flash` 把 exp190 燒兩次、讀 `yi26 log` | 0 / 1 |
| 4 修正 | 候選：1200-baud 重開機前收回 token；TLC 兩條性質都成立、測試轉綠、exp190 重跑 | 0 / 1 |

**練習**：把修正前的模型交給學生，讓他們自己從 `interpret` 的文件註解寫出性質，看 TLC 給什麼。
寫得太弱（只寫「不採信別人的」）會通過——這正是 `ecf659e` 那一次的樣子。

**盲測**：exp195 在跑 breadcrumb 之前，先提交 usb-log 的性質與預測（合作式排程：無反例；
搶佔式：有反例但重現不出來），再跑。

### exp196 —— 別的通道的 INIT（方法，用在協定上）

**只證明一件事：`crates/ctap-hid` 會讓一則訊息無聲消失，而 exp194 的案例停在它前一步。**

| 步驟 | 內容 | Needs |
| --- | --- | --- |
| 1 建模 | `model/CtapHid.tla`，約 100 行：兩個客戶端、`feed`、`expire`、計時器分支 | 0 |
| 2 找反例 | H2；修掉 H2 後 H1 | 0 |
| 3 重現 | `crates/ctap-hid/src/tests.rs` 兩個失敗的測試；`tools/ctaphid` 新案例：`busy-recovers` 之後再問 A 的訊息 | 0 / 1 |
| 4 修正 | crate 修 H2（寬鬆版）與 H1（`feed` 回報別的通道的逾時）；TLC 窮舉無反例；exp194 測試組重跑 | 0 / 1 |

---

## 六、這一輪之後才要回答的

- H2 照規格原文回 busy，還是維持寬鬆版——需要一支參考認證器的量測。
- `750 ms` 的出處。
- PIN 重試計數器遇到斷電：教學張力最大的目標（經典的「先回應再寫計數器」漏洞），
  但它散在 exp184–exp189 各自一份，照
  [第二份就是該抽的時候](./what-belongs-to-an-experiment.md)要先抽成 crate 才值得建模。

## 七、一個更正

`d6bfb0c` 合併到 `main` 時沒有硬體驗證。usb-log 那部分有 73 / 74 支韌體逐位元組相同作為證據，
但 **exp185（12 個位元組不同）與 exp187 還沒有在板子上跑過**。下次接上板子時先跑這兩支的
`check.sh`。
