# 通過測試的那顆種子

<!-- SPDX-License-Identifier: Apache-2.0 -->

這份文件寫給學生，說明 vk26-alice-5 想回答的問題、為什麼往這個方向走，以及這樣做的好處與代價。實驗本身的細節在 [README.md](./README.md)（英文）。

## 1. 四段路，接成一條

前面四個實驗各自證明了一段：

- **vk26-alice-1**：SP 800-90B 的健康測試，連續相同的計數跨窗帶過去；
- **vk26-alice-2**：讀樣本之前先用已知答案（KAT）考雜湊，再做啟動測試、丟掉那 1024 個樣本，下一窗通過才把它濃縮成 32 位元組的**摘要**；
- **vk26-alice-3**：最常見值估計所依賴的次數；
- **vk26-alice-4**：Hash_DRBG 的 Generate，從狀態 (V, C, counter) 算出亂數。

中間缺了一段：**摘要怎麼變成 V 和 C**。這是 SP 800-90A 的 Instantiate（§10.1.1.2）：

- seed_material = 摘要 ‖ nonce（‖ 個人化字串，這裡沒有）；
- V = Hash_df(seed_material)；
- C = Hash_df(0x00 ‖ V)；
- counter = 1。

Hash_df 要 440 位元，SHA-256 一次只給 256 位元，所以算兩次：Hash(0x01 ‖ 00 00 01 b8 ‖ 輸入) 和 Hash(0x02 ‖ 00 00 01 b8 ‖ 輸入)，接起來取前 55 位元組。中間那四個位元組 `00 00 01 b8` 就是「440」。

這個實驗把 Instantiate 寫成一個新的 kernel，證明它，再把三個 kernel 接起來：alice-2 的 → Instantiate → alice-4 的 Generate。

## 2. 為什麼不寫成一個大 kernel

規劃稿原本想把四個區塊合成一個 kernel。討論時改成：**三個已經證明的 kernel 依序跑，shell 在它們之間只做一件事：把下一個 kernel 的程式碼放到記憶體區域的開頭**，其他位元組一個都不動。

這樣做的理由：

- alice-2 和 alice-4 的 kernel 已經證明過、也上過板子，`kernel.bin` 的雜湊都記錄在 repo 裡。重寫成一個大 kernel，就得從頭再證一次；
- 每個 kernel 只讀「上一個留下的東西」：alice-2 把摘要寫在 0x2400，Instantiate 就從 0x2400 讀；Instantiate 把 V、C 擺在 alice-4 要的位置，Generate 就從那裡讀。**銜接的地方本身就是規格**；
- shell 每次放程式碼之前，都先比對它的 SHA-256 和 `kernel.sha256`（檢查 1）。

在 Lean 裡，shell 這一步寫成 `restart`：pc 回到 base，記憶體開頭換成下一個 kernel 的位元組，其他照舊。

## 3. 證明了什麼

Instantiate kernel 有 61 條 RV32IM 指令。它的兩個定理：

- `inst_run`：記憶體區域裡放好種子材料的長度 S（最多 128）、m 和上限。那麼 kernel 會在**恰好 241 條指令**後以 0 停下，記憶體恰好是 alice-4 的 Generate 要的樣子：V 和 C 是 Hash_df 的結果、0x03 在 V 前面、H 和計數器欄位的前導零、數字 1、m、上限、counter = 1；其他位元組（除了它算 Hash_df 時寫下的前綴）都沒變。
- `inst_boot`：同一件事，從映像檔開機開始說。

然後是組合定理 `chain`，白話是：

> 映像檔裡放好 alice-2 的 kernel、KAT 與 2048 個樣本、nonce。alice-2 的 kernel 以某個碼停下；**這個碼是 0，若且唯若雜湊通過了 KAT、而且兩個視窗都通過健康測試**。只有這時 shell 才繼續：放進 Instantiate，它在 241 條指令後以 0 停下；再放進 Generate，它在 2030 + 566m 條指令後以 0 停下。這時 0x600 起的第 j 塊，就是 Hash(V + j)，其中 V = Hash_df(摘要 ‖ nonce)。

這對**任何**雜湊函數都成立，和 alice-2、alice-4 一樣。

11 個故意寫錯的版本 Lean 全部拒絕，例如：Hash_df 說成 432 位元、C 的第二次雜湊計數器又用 1、少清一個字的零、counter 從 2 開始、V 前面放 0x02；還有錯的宣稱：少一條指令、C 漏掉前面的 0x00、nonce 只取 15 位元組、啟動窗失敗時 chain 也繼續。

## 4. 每一輪板子做什麼

1. **NIST 的 120 組**：每組把 NIST 的熵 ‖ nonce ‖ 個人化字串當作種子材料，跑 Instantiate，再跑兩次 Generate。第二次的 1024 位元必須等於 NIST 的答案。這檢查的是 Instantiate 在**真正的 SHA-256** 上對不對：證明管步驟，向量管雜湊。
2. **真的 TRNG，接成一條鏈，兩次**：從 TRNG 取 2048 個樣本，跑 alice-2 → Instantiate → Generate，nonce 是輪數（16 位元組，小端序）。第二次故意把雜湊對 KAT 的回答弄錯一個位元，鏈必須停在第一個 kernel，以 2 停下。

晶片上沒有東西可以和 TRNG 的結果比（樣本每次都不一樣）。所以板子把每一步都送出來：樣本、KAT 的回答、摘要、V、C、亂數。網頁和 `fixtures.py` 從樣本開始，**每一步都自己重算一次**。

## 5. 網頁重算了什麼

[seed.html](./seed.html) 和 kernel、shell、Python 都不共用程式碼：

- 健康測試：`alice/pages/health.js`（alice-1、alice-2 的網頁也用）；
- KAT 和摘要：瀏覽器自己的 SHA-256（WebCrypto）；
- Hash_df 和 Instantiate：這一頁自己寫；
- Generate：`alice/pages/drbg.js`（alice-4 的網頁也用，這次第二次用到才抽出來）。

它判斷每一組 NIST 案例和每一條鏈是對、錯、還是不完整（有一行沒收到，就不下判斷）。錯的時候說錯在哪一步：V、C、第幾塊、摘要、碼、還是指令數。

**上板的結果**：Pico 2 跑了一輪多，手機存回的紀錄裡有 202 組 NIST 案例和一輪的兩條鏈，完整、全對，沒有 FAIL，也沒有遺失的行：

- 晶片的 SHA-256 硬體區塊回答了 53、61、85 位元組的 HASHB，都是 SHA-256，所以補位是對的；
- TRNG 的鏈以 0 停下，網頁從樣本重算出同樣的 1024 位元；故意弄壞 KAT 的那條以 2 停下；
- 指令數都和 RTL 相同。**同一個 Instantiate kernel 單獨跑是 260，在鏈裡是 261**：第 6 節的發現在晶片上也成立。

週期數：第二次 Generate 全是 15,088；比較慢的第一次執行，每隔 16 組案例成群出現，約是 flash 裡 4 KiB 的案例表，和 alice-3、alice-4 看到的 XIP 快取現象一致，這次沒有另外探測。

## 6. 試跑找到的一件 RTL 的事

alice-1 和 alice-2 的 README 都寫過：RTL 數到的指令數比證明「多一條」，原因不明。這次找到了：

> Hazard3 RTL 在 kernel 以 `ecall` 停下時，**如果 `ecall` 後面那個字解碼得出指令，minstret 會多算 1**；後面是 0 或 0xffffffff（解不出指令）就不會。

Instantiate kernel 單獨跑時，244 位元組後面是零，RTL 數 260；在鏈裡跑時，後面是 alice-2 留下的程式碼，RTL 數 261。同一個 kernel、同一個輸入，差一條。shell 對兩種情況分別要求（檢查 3），網頁也一樣。

## 7. 證明不到的地方

- **雜湊就是 SHA-256**：定理對任何雜湊成立；是不是 SHA-256，靠 NIST 的向量和 KAT。
- **TRNG 的樣本有多少熵**：健康測試只排除明顯壞掉的來源，不證明熵。
- **固定時間**：Ct 檢查器不認得 HASHB，問不了。
- **shell 本身**：shell 的「只放程式碼、其他不動」在 Lean 裡是 `restart` 這個定義；C 寫的 shell 是不是真的這樣做，靠 RTL 上的執行和檢查 4（區域的雜湊）。

## 8. 好處與代價

**好處**：從樣本到亂數，每一步都有證明，而且銜接處是同一份規格：前一個 kernel 的定理說它留下什麼，後一個 kernel 的定理就從那裡開始。中間沒有「應該接得起來」的空白。

**代價**：

- 三個 kernel 依序跑，比一個大 kernel 多了 shell 的步驟。這一步在證明裡是假設（`restart`），不是被證明的程式碼。
- 為了讓兩個實驗共用，alice-2 的 `Trust.lean` 和 alice-4 的 `Drbg.lean` 整個搬進 `alice/lean/Alice/`，Python 參考實作、補位程式、網頁的 Generate 也一樣搬到 alice 的共用目錄。搬完 `kernel.bin` 和 alice-4 的 UF2 都一位元組不差。

## 9. 試跑在徵集設定裡找到的問題

- **裁判資料包要跟著 `import` 走**：證明搬進 alice 的套件後，alice-2、alice-4 的 `proof/*.lean` 只剩 `import`，J1 的資料包看不到證明本身，G1.5 失敗。已修（獨立 commit）：`judge-bundle.sh` 會順著 `import Alice.X` 把套件裡的檔案也收進去。
- **「多一條指令」不是 harness 的事**：是 RTL 計數的規則，見第 6 節。
