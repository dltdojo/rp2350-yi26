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

## 索引

S4 的索引表，做完一個填一列。Needs 照 [experiments/README.md](../../../experiments/README.md#which-of-these-can-i-do-right-now) 的等級；USB 四欄照[那裡的同名表](../../../experiments/README.md#which-layer-of-usb-is-this)。

| 實驗 | Needs | USB 介面 | 傳什麼 | 主機端 | 跑誰的韌體 | 一句話 |
| --- | --- | --- | --- | --- | --- | --- |
| [vk26-alice-1](./vk26-alice-1-the-run-across-the-seam/) | 2 | CDC | log | WebUSB（[seam.html](./vk26-alice-1-the-run-across-the-seam/seam.html)） | 自己的 | 四個視窗的 SP 800-90B 健康測試，RCT 跨窗連續計數，第一個失敗的視窗之後一個位元組都不寫；Lean 證明對每個輸入成立（`Seam.from_boot`），指令數由停止窗號決定。Pico 2 上板一次，紀錄 7 條完整樣本流全對（[board/round1.txt](./vk26-alice-1-the-run-across-the-seam/board/round1.txt)） |
| [vk26-alice-2](./vk26-alice-2-the-hash-tested-first/) | 2 | CDC | log | WebUSB（[trust.html](./vk26-alice-2-the-hash-tested-first/trust.html)） | 自己的 | 讀樣本之前先以已知答案測試（KAT）考 `HASH`（晶片上是 SHA-256 硬體區塊），答錯就在 43 條指令後以 2 停下、一個樣本都不讀；再做 SP 800-90B 的啟動測試並丟棄那 1024 個樣本，下一窗通過才輸出 `HASH`；Lean 證明對任何 `HASH` 成立（`Trust.trusts_after_kat`）。shell 每輪故意弄壞一次答案，kernel 都擋下。Pico 2 上板一次，紀錄 18 條完整樣本流全對，弄壞的答案 4 次都被擋下（[board/round1.txt](./vk26-alice-2-the-hash-tested-first/board/round1.txt)） |
| [vk26-alice-3](./vk26-alice-3-the-count-the-estimate-rests-on/) | 2 | CDC | log | WebUSB（[count.html](./vk26-alice-3-the-count-the-estimate-rests-on/count.html)） | 自己的 | SP 800-90B §6.3.1 最常見值估計所依賴的那個數字：4096 個位元組樣本、256 格的次數與最大值；Lean 證明對每個輸入成立，恰好 6,294,284 條指令（`Count.from_boot`），且執行軌跡不受樣本影響（`Count.count_constant_time`，直接索引的直方圖被拒絕）。開根號與對數的公式不在證明裡。TRNG 每輪取兩種：測試開著的、旁路平衡器的原始位元。Pico 2 上板一次，紀錄 13 條完整樣本流的次數全對；「每條流週期數相同」的預測沒有成立（三個數字，同樣的固定樣本在不同輪也不同，所以不是樣本造成的）；原始位元是 1 的比例約 48.3%（[board/round1.txt](./vk26-alice-3-the-count-the-estimate-rests-on/board/round1.txt)）。revision 2 每條流連跑兩次：14 次第二次全是同一個週期數（預測成立），變慢的第一次只出現在 shell 從 flash 複製的資料掃過 trap 入口所在快取組之後（[board/round2.txt](./vk26-alice-3-the-count-the-estimate-rests-on/board/round2.txt)）。revision 3 在第一次執行前故意設定快取：第 3 條流第一次變慢（3 輪中 2 輪），但把 trap 那一行讀回快取沒能讓第 2、4 條不慢（6 次中 3 次），預測只部分成立（[board/round3.txt](./vk26-alice-3-the-count-the-estimate-rests-on/board/round3.txt)）。revision 4 一次燒錄跑完 34 種條件的探測，找到答案：暖的時候進出 kernel 的週期數和 RTL 相同；第一次變慢，是因為 harness 的 0x10000130、0x10000138 兩行被擠出 XIP 快取，每次約多 110 個週期；樣本從未影響週期數（[board/round4.txt](./vk26-alice-3-the-count-the-estimate-rests-on/board/round4.txt)） |
| [vk26-alice-4](./vk26-alice-4-the-state-the-generator-keeps/) | 2 | CDC | log | WebUSB（[drbg.html](./vk26-alice-4-the-state-the-generator-keeps/drbg.html)） | 自己的 | SP 800-90A Hash_DRBG（SHA-256，seedlen 55 位元組）的 Generate：Hashgen 與 V = V + H + C + counter mod 2^440，四次 55 位元組大端序加法共用一個副程式；Lean 證明對每個狀態、任何雜湊函數都成立，恰好 2030 + 566m 條指令（`Drbg.from_boot`），counter 超過上限時 7 條指令後以 1 停下、什麼都不寫（`Drbg.reseed_boot`），在第一次留下的記憶體上再跑一次也成立（`Drbg.generate_twice`）。NIST CAVP 的 120 組 SHA-256 向量：Python、Lean 模型、RTL 全對；shell 每組連跑三次（第三次必須拒絕），RTL 上 120 組全過。HASHB 在晶片上由 SHA-256 硬體區塊回答，任意長度的補位是新寫的。Pico 2 上板一次：兩輪 178 組沒有 FAIL，紀錄中 165 組完整、全對，第二次 Generate 都等於 NIST 的答案（補位正確），指令數都和 RTL 相同；第二次 Generate 全是 15,078 個週期，第一次有 40 組較慢、多半是同一批案例（[board/round1.txt](./vk26-alice-4-the-state-the-generator-keeps/board/round1.txt)） |
| [vk26-alice-5](./vk26-alice-5-the-seed-the-tests-passed/) | 2 | CDC | log | WebUSB（[seed.html](./vk26-alice-5-the-seed-the-tests-passed/seed.html)） | 自己的 | SP 800-90A 的 Instantiate（Hash_df：兩次 SHA-256 接起來取 440 位元）寫成 61 條指令的 kernel；Lean 證明對任何雜湊函數，恰好 241 條指令後以 0 停下，V、C 是種子材料的 Hash_df，記憶體擺成 vk26-alice-4 的 Generate 要的樣子（`Seed.inst_run`）。組合定理 `Seed.chain`：vk26-alice-2 的 kernel 以 0 停下，若且唯若 KAT 相符且兩個視窗都通過；只有這時 shell 換上 Instantiate、再換上 Generate（兩次都只把程式碼放到區域開頭），第 j 塊輸出是 Hash(V + j)，V = Hash_df(摘要 ‖ nonce)。每輪先跑 NIST 的 120 組（Instantiate 加兩次 Generate），再用真 TRNG 跑整條鏈兩次，第二次故意弄壞 KAT 的回答、鏈必須停在第一個 kernel；Python、Lean 模型、RTL 全對。找到 vk26-alice-1、2 多數一條指令的原因：停下的 `ecall` 後面那個字是合法指令時，RTL 的 minstret 多 1（同一個 kernel 單獨跑 260、在鏈裡 261）。網頁從原始樣本一路重算到亂數。Pico 2 上板一次：紀錄中 202 組 NIST 案例與一輪的兩條鏈完整、全對，沒有 FAIL；晶片的 SHA-256 區塊在 Hash_df 的 53、61、85 位元組輸入上都是 SHA-256；TRNG 的鏈產生的亂數網頁重算相同，弄壞 KAT 的那條以 2 停下；晶片上同一個 Instantiate 單獨 260、在鏈裡 261，和 RTL 一樣。第一次執行較慢的案例每隔 16 組成群（約 4 KiB 的案例表）（[board/round1.txt](./vk26-alice-5-the-seed-the-tests-passed/board/round1.txt)） |

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
  - 一個 `front` 的變體區塊，起始的 `run`、`last` 由上一窗帶入。不修改主線 `lean/`，放在 `alice/lean/Alice/Window.lean`（見第四節的討論 2）。
  - 主要定理 `from_boot`（規劃時叫 `latch`，鎖存的內容就在它的結論裡）：對每個輸入，在確定的指令數後停止，輸出區恰為前 k 個視窗的 `env.hash`，其餘記憶體不變。指令數依停下的視窗而定，可寫成停止窗號的函數。
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
  - USB 名稱與序號都是實驗的識別碼，例如 `vk26-alice-1`。
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
   - **結果**（vk26-alice-4）：取得到，從 csrc.nist.gov 下載。SHA-256、不帶 additional input 的 120 組連同來源與 zip 的雜湊值放進 repo，之後不需要網路。
5. **順序與節奏**：照 1 → 5 實作，每做完一個就停下來檢討設定，再做下一個。vk26-alice-4 的大端序進位與 vk26-alice-5 的組合證明最重；若時間不夠，可以先把 vk26-alice-3（MCV 計數）提前。

## 五、預期會測到的徵集設定問題

規劃時已經找到、實作時要確認的。最後一欄是做完 vk26-alice-1 到 5 時的狀態：

| 項目 | 現況 | 可能的影響 | 做完之後 |
| --- | --- | --- | --- |
| `experiments/duplication.sh` | 只掃 `experiments/*` 的 `.rs`、`.py`、`.sh` | `alice/` 內的重複不會被抓到；README 第 4 節「第二份就抽出」沒有機器檢查 | **已修**（獨立 commit）：會讀 `calls/<徵求>/<帳號>/<徵求>-<帳號>-<n>-<slug>/`。它以函式名稱計數，alice-1 有四個函式和主線撞名（不是複製），已改成具體的名稱；徵集 README 提醒提案者。alice-5 的新程式又撞名兩次（`rounds`、`chain`），同樣改名；它也抓到 alice-4 的 fixtures 自己寫了一份狀態列，改用 `alice/tools/lines.py` |
| J3 的 PRIOR WORK | 只取 `experiments/README.md` exp201 起的索引列 | vk26-alice-2 到 5 的 J3 看不到 alice 自己的 vk26-alice-1 等，可能把延續自 vk26-alice-1 的部分判為「新」 | alice-2 確認會發生（它沿用 alice-1 的跨窗計數），**已修**（獨立 commit）：提案自己編號較小的索引列也進 J3 切片，標「(this proposal)」；徵集 README 提醒索引表的一句話是 J3 的材料 |
| 網頁不在 bundle | `judge-bundle.sh` 不收 `.html`、`.mjs` | 網頁相關的宣稱在 J1 無證據（見第四節第 1 點） | **已修**（獨立 commit）：README 或 WHY.zh-TW.md 連結到的 `.html`、`.mjs`，以及頁面用 `<script src>` 從旁邊載入的腳本，進入 J1 切片；selftest 有對應案例 |
| 提案者 Lake 套件 | `lean.sh` 已支援 `calls/<徵求>/<帳號>/lean/`，但從未被真正的提案用過 | 第一次實際使用：路徑、`once_key`、mutant 限制（不能改主線函式庫） | 套件可用。`lean.sh exec` 用錯函式庫，**已修**。mutant 改不到套件，**已修**（獨立 commit）：最後一欄可寫 `calls/vk26/<帳號>/lean/<檔案>.lean`；alice-1 加了兩個改 `Alice/Window.lean` 的 mutant（規格每窗歸零、參考值不取 bit 0），都被拒絕。alice-5 讓 alice-2 的 `Trust.lean`、alice-4 的 `Drbg.lean` 整個搬進套件（兩者的 `kernel.bin` 不變），實驗裡的 `proof/*.lean` 只剩 `import`：J1 的資料包因此看不到證明，G1.5 失敗。**已修**（獨立 commit）：`judge-bundle.sh` 順著 `import Alice.X` 把套件裡的檔案收進去，selftest 有對應案例 |
| Lean 的戰術 | 沒有 Mathlib；`lean.sh check` 連警告都算失敗 | 提案者習慣的 `split_ifs`、`set` 不能用；未用到的 simp 參數也會讓檢查失敗 | **已寫進徵集 README** 第 4 節「Lean 的寫法限制」：沒有的戰術、會變成失敗的警告、各自的替代。alice-3 再加三列（獨立 commit）：`lean.sh check` 只顯示錯誤第一行；Ct 檢查器知道 `lui` 的值、不知道位移的；在 `List.range 256` 上歸納會逾時。alice-4：Ct 檢查器的 `ecall` 只認得 HASH 和 HALT，不認得 HASHB，也不接受 `jal`/`jalr`，所以用 HASHB 或副程式的 kernel 問不了固定時間；檢查器在 `lean/`，只記錄、不改 |
| 路徑深度 | 實驗在 `calls/vk26/alice/vk26-alice-N-<slug>/`，比 `experiments/expNNN/` 深兩層 | `source ../../../../experiments/lib.sh`、`tools/hazard3/shell/` 的相對路徑、`run.sh` 的開跑前檢查 | 確認可行：`TOOLS=../../../../tools`；`shell.sh`、`pagecheck.sh`、`headless.mjs` 都不假設深度 |
| `check.sh` | 不能呼叫 `presence_check`、`usb_check`（README 第 3 節） | Needs 與 USB 資訊只在 alice 的索引表，沒有機器檢查 | 確認：資訊寫在上面的索引表，沒有機器檢查 |
| S2 | PR 只能動 `alice/` | 試跑中對徵集設定的修正要另開 PR，不能混進 alice 的提交，才能如實測到 S2 | 兩個設定修正都是獨立 commit，只動 `tools/lean/lean.sh` 或 `calls/vk26/` 的設定檔。alice-3 需要旁路 TRNG 測試的驅動程式，共用的 `trng.h` 沒有這個選項、S2 又不讓提案改 `tools/`：放在 alice 自己的 `shell/trng_raw.h`，重用 `trng.h` 的函式而不複製。alice-4 的 HASHB 是任意長度，共用的 `sha_hw.h` 只收 64 位元組整數倍且對齊的輸入（HASH 的規則）：補位寫在 alice-4 自己的 `board_chip.c`，有第二個使用者時應搬到 `sha_hw.h` 旁邊。alice-5 是第二個使用者：補位搬到 alice 的 `shell/hashb_chip.h`（alice-4 的 UF2 一位元組不差），因為 S2 仍不能放到 `sha_hw.h` 旁邊；同時搬到 alice 共用目錄的還有 Python 的 Hash_DRBG 與 alice-2 參考實作（`alice/tools/`）、網頁的 Generate（`alice/pages/drbg.js`） |
| 裁判用量 | 7 次判定 × 2 個 session | 依第 4 輪，約 $4–5；`audit-proposal.sh` 第一次對真提案執行 | 未到（五個做完才跑） |
| G7 | 需要人、板子、手機 | 每個實驗需要一次手機上板；五個實驗共 5 次 | alice-1 上板一次。紀錄經聊天貼回時被截斷（網頁看到 11 條，貼回 7 條）。**已修**：alice 的網頁加了 Save（存檔，狀態列寫出字元數與行數）；徵集 README 與 ACCEPTANCE 改成紀錄一律以檔案傳回。alice-2 上板一次，紀錄以 Save 存的檔案傳回、原樣放進 `board/`，網頁看到的 18 條樣本流全在檔案裡，沒有截斷：改用檔案之後確實解決了。alice-3 上板四次（revision 1 到 4），同樣以檔案傳回，樣本流都完整。revision 2 和 3 的紀錄格式相同，紀錄本身說不出板子跑的是哪一版；revision 4 起每輪送出 `REVISION` 行。前三趟每趟只測一個猜測，第四趟讓板子自己跑 34 種條件，一次就找到答案。alice-4 上板一次，紀錄以檔案傳回；但有一段整行遺失（10 組），遺失前最後一行狀態列 `dropped=0`、之後沒有狀態列，紀錄本身分不出是板子丟的還是手機丟的。遺失的案例網頁都標為不完整、不做判斷。alice-5 上板一次，紀錄以檔案傳回，`dropped=0`，沒有遺失的行 |

## 六、這份規劃參考過的既有工作

exp114（`crates/entropy-health`）、exp208、exp222–exp224、exp226、exp227、exp228（`HASHB`）、
exp229（`Limbs.lean`）、exp233、`lean/Rv32/Health.lean`、`lean/Rv32/Sha.lean`、
`lean/Rv32/Machine.lean`（`ecall` 表）、`tools/hazard3/shell/`（`speak.h`、`sources.h`）、
`calls/vk26/README.md` 第 3、4 節、`calls/vk26/judge-bundle.sh`、`experiments/duplication.sh`。

## 七、五個實驗做完之後：徵集設定的檢討（2026-10-15）

第五節的表是邊做邊記的。五個都做完後，把每個實驗 README 的「What the trial found in the call's settings」與這張表重新過一次，再對 alice 跑一次不呼叫模型的驗收（`DRY_RUN=1`），又找到四個試跑中沒發現的問題。修正都在 `calls/vk26/` 的設定檔，一個獨立的 commit（4c212f0），不碰 `alice/`：

| 問題 | 怎麼發現 | 修正 |
| --- | --- | --- |
| 驗收腳本只跑 G1.5：S2、S3、G2、G6 與各實驗的 `check.sh` 都靠人，S4 是人讀表格 | 讀 `audit-proposal.sh` | 新增 [`gates.sh`](../gates.sh)：提案層級 S1–S4（S2 對 `BASE` 比較），每個實驗 G1.5、G2、G6 與 `check.sh`（從 lean.sh、shell.sh 自己印的行判 G1、G3、G5）。`audit-proposal.sh` 先跑它，有一項不過就不呼叫裁判；新跑的 `check.sh` 輸出成為 bundle 的 GATES |
| 沒有東西檢查 `capture.txt` 是否還是最新的 | 用 `gates.sh` 檢查 alice：五個 capture 都比它依賴的檔案舊（alice-1 到 4 之後搬了共用程式，alice-5 之後加了上板紀錄） | G6 拒絕比它依賴的東西還舊的 capture（實驗本身、提案者共用的 `lean/`、`tools/`、`pages/`、`shell/`；`.md` 與其他實驗除外）。上板紀錄在 capture 之後加入也算：README 引用的板子數字要靠 `--board` 檢查的輸出進 capture，J1 讀到的紀錄本身只有開頭幾行與網頁的摘要行 |
| bundle 把提案者整個 Lean 套件放進每個切片，J3 也有 | `DRY_RUN=1` 的 bundle 有 200–263 KB，比校準用的大兩三倍；alice-3 一個套件模組都沒 import，卻帶了 60 KB | 只收證明檔 import 到的模組（以及它們 import 的），只進讀 Lean 的切片。J3 切片從最多 119 KB 降到 31–57 KB |
| `capture.txt` 截在 200 行 | 同上：alice-3、4、5 的 capture 最後的網頁測試、錯的 shell、上板檢查都被截掉，J1 看不到它們的證據 | 600 行內全收；超過才把 20 行以上形狀相同的一段截成頭尾各三行。注入掃描也改成掃 bundle 送出的每一個檔案（原本漏了套件與網頁的腳本） |

校準的七個 bundle 在修改前後逐位元組相同（`commit:` 行除外），第 4 輪的校準照舊有效（[calibration/README.md](../calibration/README.md) 最後一節）。另外兩處文件的修正：ACCEPTANCE 的 G1 與徵集 README 第 2 節原本寫「以 0 停止」，但 alice-2 的 kernel 依輸入以 0 到 3 停止，JUDGE.md 也只要求「規格所說的結果」，改成「以規格所說的停止碼停止」；vk26-alice-5 找到的 RTL minstret 規則、上板紀錄要能說出是哪一版韌體，寫進徵集 README。

**記錄、未修改**（都在 `lean/` 或 `tools/`，屬於任務方的主線，不是徵集設定）：

- `lean/Rv32/Ct.lean` 的常數時間檢查器不認得 HASHB、不接受 `jal`/`jalr`（vk26-alice-4）。
- `tools/hazard3/harness` 進出 kernel 的兩行在 flash，週期數受 XIP 快取影響（vk26-alice-3；vk26-alice-4、5 的板上週期數也看到同樣的現象）。
- 任意長度的 SHA-256 補位（`alice/shell/hashb_chip.h`）與旁路測試的 TRNG（`alice/shell/trng_raw.h`）：第二份提案也需要時，搬到 `tools/hazard3/shell/`。
