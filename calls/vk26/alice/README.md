# vk26/alice：從健康測試到亂數產生器，五個被證明的 kernel（規劃稿）

<!-- SPDX-License-Identifier: Apache-2.0 -->

**這是任務方自己做的試跑提案**：在公告前，用一份真的提案把 vk26 從報名到驗收走一遍，
看 repo 的結構、工具與規則會在哪裡卡住。`alice` 是 [README.md 第 3 節](../README.md#3-目錄與編號)
用的示範帳號。

這份文件目前是**規劃稿**，供討論。討論定案後，依序實作 vk26-alice-1 到 vk26-alice-5。每做完一個，
就回頭檢討徵集設定（[README.md](../README.md)、[ACCEPTANCE.md](../ACCEPTANCE.md)、
`judge-bundle.sh` 等）需不需要修改，邊做邊修。實作完成後，這份 README 改寫成 S4 要求的
索引表，規劃內容移到各實驗的 README。

五個實驗的識別碼是 `vk26-alice-1` 到 `vk26-alice-5`（[README.md 第 3 節](../README.md#3-目錄與編號)），目錄名稱、USB 名稱與序號、紀錄、commit 一律用這個全名；本提案的討論中可簡稱 `alice-1`。這是試跑找到的第一個設定問題：原本規定的 `exp101`–`exp105` 和主線 `experiments/exp101` 同名，每份提案也都一樣，討論時無法分辨，已改掉。

文中所有數字（指令數、時間、位元組數）都是**預估**，不是量測結果；實作後以 capture 為準。

---

## 一、方向：把 exp222–224 沒做完的事做完

主題是 NIST SP 800-90B（熵源）與 SP 800-90A（決定性亂數產生器，DRBG），延伸自：

| 既有 | 做了什麼 | 它自己寫明「沒做」的 |
| --- | --- | --- |
| exp114 `crates/entropy-health` | Rust 寫的 RCT（連續 21 個相同即失敗）、APT（1024 個中 589 個等於第一個即失敗），失敗就停止輸出 | 熵的評估 |
| exp222 + `lean/Rv32/Health.lean` | 兩個測試成為 27 條指令的區塊 `front`，證明對每個輸入都成立；一個視窗、1024 個樣本 | 熵的評估；conditioning |
| exp223 | 測試通過才用 exp208 的 SHA-256 kernel 雜湊樣本（約 33 萬條指令） | 輸出是否有完整熵 |
| exp224 | 把 shell 的檢查搬進一個被證明的 judge kernel | 跑多久沒有確定的指令數 |
| exp208 + `lean/Rv32/Sha.lean` | SHA-256 kernel 與規格 | 規格是否就是 FIPS 180-4（以 hashlib 比對） |

讀既有程式時找到一個具體的出發點：**exp114 的 crate 裡，RCT 的連續計數會跨越視窗**
（`run` 在整個樣本流上累計），而 `Health.lean` 的 `front` 每次進入都把計數歸零（`s4 = 2`）。
exp222、exp223 只判一個視窗，所以這不是錯誤；但若把 `front` 逐窗套用在連續的樣本流上，
一段跨越視窗邊界的 21 個相同樣本（例如前一窗最後 11 個加上下一窗最前面 10 個）就會被漏掉。
SP 800-90B 的 RCT 是對整個樣本流連續計數的。vk26-alice-1 從這裡開始。

---

## 二、五個實驗

| 實驗 | 一句話 | 主要定理（預定名稱） | 網頁展示 |
| --- | --- | --- | --- |
| **vk26-alice-1** the run across the seam | 4 個視窗連續做健康測試，RCT 跨窗計數；第一個失敗的視窗之後全部停止輸出（錯誤鎖存） | `latch`：輸出恰好是「第一個失敗之前」每個視窗的雜湊，之後一個位元組都不寫 | 每窗判定、跨窗最長連續、APT 計數；網頁自己重算並用 WebCrypto 驗雜湊 |
| **vk26-alice-2** the hash tested first | 先對 `HASH`（晶片上是硬體 SHA-256）做已知答案測試（KAT），再丟棄啟動視窗、才開始 conditioning | `trusts_after_kat`：KAT 不符就停在錯誤碼、記憶體不變；符合才輸出 `env.hash(樣本)` | 顯示 KAT、啟動測試、摘要；故意壞掉的雜湊來源被擋下 |
| **vk26-alice-3** the count the estimate rests on | SP 800-90B §6.3.1 最常見值（MCV）估計所需的計數：位元組直方圖與最大次數，無分支、指令數固定 | `counts`：最大次數等於規格的最常見值次數；`Ct` 證明耗時與樣本無關 | 即時直方圖；網頁由次數算出 p_u 與 H_min，與參考實作比對 |
| **vk26-alice-4** the state the generator keeps | SP 800-90A Hash_DRBG（SHA-256，seedlen 440 位元）的 Generate：Hashgen 與狀態更新 `V = V + H + C + counter mod 2^440` | `generates`：輸出與新狀態等於規格，對任何 `env.hash` 都成立；55 位元組大端序加法的進位 | 每次 Generate 的輸出與 V；網頁用 WebCrypto 重算整個 DRBG |
| **vk26-alice-5** the seed the tests passed | 串起前四個：健康測試 → KAT → conditioning → Hash_df instantiate → Generate | `chain`：亂數輸出存在，若且唯若每個視窗都通過且 KAT 相符，且輸出等於規格串起來的結果 | 整條鏈的每一階段；網頁從原始樣本一路重算到最後的亂數 |

### vk26-alice-1 — the run across the seam

- **Kernel**：4 個視窗、每窗 1024 個樣本（每個樣本在一個字的 bit 0，同 exp222）。
  - RCT 的 `run` 與 `last` 跨窗延續。
  - APT 每窗重新取參考值。
  - 每窗通過就以 `ecall HASH` 寫出 32 位元組；第一個失敗的視窗之後不再寫任何東西，以停止碼表示「在第幾窗停下」。
- **Lean**：
  - 一個 `front` 的變體區塊，起始的 `run`、`last` 由上一窗帶入。不修改主線 `lean/`，放在 `alice/lean/Alice/Health.lean`（見第四節的討論 2）。
  - 主要定理 `latch`、`from_boot`：對每個輸入，在確定的指令數後停止，輸出區恰為前 k 個視窗的 `env.hash`，其餘記憶體不變。指令數依停下的視窗而定，可寫成停止窗號的函數。
- **新東西（J3）**：跨窗連續的 RCT（與 exp114 一致，與 `front` 不同）；多窗的錯誤鎖存。
- **mutants（≥ 4）**：
  - RCT 每窗歸零（就是 `front` 的行為）；
  - 失敗後仍寫下一窗；
  - 宣稱改成「失敗窗也寫」；
  - 停止碼差一。
- **參考實作（J4）**：Python 逐樣本的狀態機，寫法照 exp114 的 crate，不照 Lean 的暫存器。
- **來源**：TRNG、卡在 1、exp114 的「九個 1 一個 0」，再加一個新的**跨邊界來源**：前一窗結尾 11 個 1、下一窗開頭 10 個 1。這個來源 `front` 逐窗套用會漏掉，這裡必須抓到。
- **網頁**：顯示每窗的判定、跨窗最長連續、APT 計數。網頁收到樣本後自己重算兩個測試，並用 WebCrypto 的 SHA-256 驗每個雜湊。

### vk26-alice-2 — the hash tested first

- **Kernel**：
  1. 先對一則固定 64 位元組訊息呼叫 `HASH`，和映像裡的預期摘要（由 `gen.py` 以 hashlib 算出）逐位元組比對；不符就停在錯誤碼。
  2. 再對第一個視窗做啟動測試（SP 800-90B §4.3）：通過也丟棄，不輸出。
  3. 下一個視窗通過才輸出 `HASH` 的結果。
- **Lean**：`trusts_after_kat`。對**任何** `env.hash`：
  - 若 `env.hash(KAT 訊息) ≠ 預期`，停止碼為 2，記憶體不變；
  - 否則依健康測試結果，輸出 `env.hash(第二窗)` 或什麼都不寫；
  - 啟動窗的樣本不影響任何輸出位元組。

  這是 repo 裡第一個「先驗證外部函數、才信任它」的定理形式。
- **為什麼要做**：exp223 用 33 萬條指令的軟體 SHA-256，因為它不信任晶片的雜湊區塊。這裡改用快得多的硬體區塊，代價是要信任它，於是把「信任的條件」寫進定理。
- **晶片上**：shell 多一個「壞雜湊」模式，把硬體結果翻轉一個位元，kernel 必須在 KAT 停下。
- **網頁**：顯示 KAT 結果、啟動測試、輸出摘要，並用 WebCrypto 重算。

### vk26-alice-3 — the count the estimate rests on

- **Kernel**：4096 個位元組樣本（取自 TRNG 的字）。
  1. 清空 256 格直方圖。
  2. 逐一計數。
  3. 無分支地找出最大次數（`sltu` 加遮罩），寫在固定位置。
- **Lean**：
  - `counts`：停止時直方圖等於規格的計數，最大值等於規格的最常見值次數；指令數是一個固定的數字。
  - 再用 `lean/Rv32/Ct.lean`（exp207）證明執行軌跡與樣本無關。
- **沒有證明的部分，明白寫出**：§6.3.1 的公式 p_u = min(1, p̂ + 2.576·√(p̂(1−p̂)/(L−1)))、H = −log2 p_u 有平方根與對數。這一步由網頁與 Python 計算，不在定理裡。這是「被證明的計數」加上「未證明的公式」的分界，正好用來測 J1 怎麼看待這種宣稱。
- **新東西**：exp222、exp223 都寫明「熵的評估不在這裡」，這是評估裡可以被證明的那一半。
- **網頁**：即時直方圖；由板子送出的最大次數算出 H_min，並和自己從樣本算出的比對。

### vk26-alice-4 — the state the generator keeps

- **Kernel**：Hash_DRBG（SP 800-90A Rev. 1 §10.1.1，SHA-256，seedlen = 440 位元 = 55 位元組）的 Generate，不帶 additional input：
  1. Hashgen：`Hash(V)`、`Hash(V+1)`……
  2. `H = Hash(0x03 ‖ V)`。
  3. `V = (V + H + C + reseed_counter) mod 2^440`。
  4. `reseed_counter += 1`。

  雜湊用 `ecall HASHB`（t0 = 2，長度不限，exp228 加的）。
- **Lean**：`generates`：對任何 `env.hash`，輸出與新的 (V, C, counter) 等於規格。
  - 證明的重點是 **55 位元組大端序**的四項加法與進位。`lean/Rv32/Limbs.lean`（exp229）是小端序 32 位元字，大端序位元組要另寫引理，放在 `alice/lean/`。
- **參考實作**：Python 照 SP 800-90A 的文字寫。若能取得 NIST CAVP 的 Hash_DRBG 測試向量，再加一層比對；**能否取得要實作時確認**（雲端 VM 的網路可能不通）。
- **網頁**：每次 Generate 的輸出與 V；網頁以 WebCrypto 重算整個 DRBG。

### vk26-alice-5 — the seed the tests passed

- **Kernel**：vk26-alice-1 的健康測試區塊、vk26-alice-2 的 KAT 區塊、vk26-alice-4 的 Generate 區塊，加上 Hash_df 與 Instantiate：
  - `seed_material` = conditioning 後的摘要 ‖ nonce；
  - `V = Hash_df(seed_material)`、`C = Hash_df(0x00 ‖ V)`；
  - 最後做一次 Generate。
- **Lean**：`chain`。亂數輸出存在，若且唯若 KAT 相符且每個視窗都通過；且輸出等於規格把整條鏈串起來的值。這是組合定理，各段在 vk26-alice-1、2、4 已證。
- **抽出共用**：三個區塊在這裡第二次被用到，依規則搬進 `alice/lean/Alice/`，並讓 vk26-alice-1、2、4 改為引用，`kernel.bin` 不變。這同時驗證 README 第 4 節的提案者套件機制。
- **網頁**：顯示整條鏈的每一階段，從原始樣本一路重算到最後的亂數。

---

## 三、每個實驗都有的部分

照 [README.md 第 3 節](../README.md#3-目錄與編號) 的目錄配置與 [ACCEPTANCE.md](../ACCEPTANCE.md) 的 G1–G7：

- `proof/<Name>.lean`、`proof/mutants.txt`（≥ 4 個）、`kernel.bin`、`kernel.sha256`。
- Python 參考實作與 `differential/`：≥ 10 個輸入，比對 Lean 模型、Hazard3 RTL、參考實作三方的停止碼、指令數、64 KiB 區域。
- `shell/`：沿用 `tools/hazard3/shell/` 的 `speak.h`、`trng.h`、`sources.h`、`sha_hw.h`，**引用不複製**。
  - USB 名稱 `alice-exp10x`，序號 `alice-10x`。
  - ≥ 3 個故意寫錯的 shell 被抓到。
- 網頁：WebUSB 連 CDC（同 exp227、exp233 的做法），Node 測試加 fixtures，Copy 按鈕把紀錄帶回。
- `README.md`（英文）、`WHY.zh-TW.md`（給學生看的白話說明）、`capture.txt`（`run.sh` 從乾淨的 commit 錄製）。
- `board/round1.txt`：手機上板的紀錄，由參考實作核對。
- Needs：同 exp227。需要 Pico 2，按一次 BOOTSEL，再用 Android Chrome 開網頁。

---

## 四、討論的結果

以下五點都依建議定案（2026-10-13）。

1. **網頁放哪裡**（同時是徵集設定的問題）：
   - (a) 每個實驗一頁：裁判的資料包看得到。但 WebUSB 連線、CDC 解析這段程式在五頁各一份，違反「第二份就抽出」。
   - (b) 一頁五種模式，放在 `alice/pages/`：只有一份。但目前 `judge-bundle.sh` 不收 `.html`、`.mjs`，各實驗 README 對網頁的宣稱，J1 會找不到證據。
   - (c) 共用部分放 `alice/pages/`，各實驗一個薄頁，由建置步驟合成單一檔案。
   - **定案：(c)**。同時修改 `judge-bundle.sh`，讓 README 連結到的頁面與它的測試輸出進入 J1 的 bundle；這是徵集設定的修改，在 vk26-alice-1 的網頁完成前做。
2. **`front` 的變體放哪裡**：主線 `Health.lean` 不能改（S2）。vk26-alice-1 需要「計數由上一窗帶入」的版本，只能在 `alice/lean/` 另寫一個區塊。這不是複製，是不同的區塊；但合併後主線可能想把兩者統一。README 第 4 節已有「PR 說明裡寫出來，合併後由任務方搬移」的流程，這次實際走一遍。
3. **vk26-alice-1 的雜湊用 `ecall HASH` 還是被證明的軟體 SHA-256**：
   - **定案：ecall**。定理對任何雜湊函數都成立，4 窗只需幾千條指令；被證明的軟體版每窗約 33 萬條。
   - 「雜湊是否就是 SHA-256」交給 vk26-alice-2 的 KAT。
4. **Hash_DRBG 的測試向量**：NIST CAVP 向量能否在雲端取得，實作 vk26-alice-4 時先確認。取不到，就只有 Python 參考實作與網頁兩個獨立寫成的實作互相比對，README 要照實寫。
5. **順序與節奏**：照 1 → 5 實作，每做完一個就停下來檢討設定，再做下一個。vk26-alice-4 的大端序進位與 vk26-alice-5 的組合證明最重；若時間不夠，可以先把 vk26-alice-3（MCV 計數）提前。

## 五、預期會測到的徵集設定問題

規劃時已經找到、實作時要確認的：

| 項目 | 現況 | 可能的影響 |
| --- | --- | --- |
| `experiments/duplication.sh` | 只掃 `experiments/*` 的 `.rs`、`.py`、`.sh` | `alice/` 內的重複不會被抓到；README 第 4 節「第二份就抽出」沒有機器檢查 |
| J3 的 PRIOR WORK | 只取 `experiments/README.md` exp201 起的索引列 | vk26-alice-2 到 5 的 J3 看不到 alice 自己的 vk26-alice-1 等，可能把延續自 vk26-alice-1 的部分判為「新」 |
| 網頁不在 bundle | `judge-bundle.sh` 不收 `.html`、`.mjs` | 網頁相關的宣稱在 J1 無證據（見第四節第 1 點） |
| 提案者 Lake 套件 | `lean.sh` 已支援 `calls/<徵求>/<帳號>/lean/`，但從未被真正的提案用過 | 第一次實際使用：路徑、`once_key`、mutant 限制（不能改主線函式庫） |
| 路徑深度 | 實驗在 `calls/vk26/alice/exp10x/`，比 `experiments/expNNN/` 深兩層 | `source ../../../../experiments/lib.sh`、`tools/hazard3/shell/` 的相對路徑、`run.sh` 的開跑前檢查 |
| `check.sh` | 不能呼叫 `presence_check`、`usb_check`（README 第 3 節） | Needs 與 USB 資訊只在 alice 的索引表，沒有機器檢查 |
| S2 | PR 只能動 `alice/` | 試跑中對徵集設定的修正要另開 PR，不能混進 alice 的提交，才能如實測到 S2 |
| 裁判用量 | 7 次判定 × 2 個 session | 依第 4 輪，約 $4–5；`audit-proposal.sh` 第一次對真提案執行 |
| G7 | 需要人、板子、手機 | 每個實驗需要一次手機上板；五個實驗共 5 次 |

## 六、這份規劃參考過的既有工作

exp114（`crates/entropy-health`）、exp208、exp222–exp224、exp226、exp227、exp228（`HASHB`）、
exp229（`Limbs.lean`）、exp233、`lean/Rv32/Health.lean`、`lean/Rv32/Sha.lean`、
`lean/Rv32/Machine.lean`（`ecall` 表）、`tools/hazard3/shell/`（`speak.h`、`sources.h`）、
`calls/vk26/README.md` 第 3、4 節、`calls/vk26/judge-bundle.sh`、`experiments/duplication.sh`。
