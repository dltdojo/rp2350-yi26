# exp189 這一輪：進度與檢討

**快照時間：2026-08-29 10:34 UTC** · 分支 `exp189-hmac-secret`，6 個提交

這份文件寫給下一個接手的人，也寫給下一次的我。上半是**這一輪做了什麼**，
下半是**這一輪犯了什麼錯、下次怎麼不再犯** —— 後者才是重點，因為錯誤的成本
不在當下，在下一次有人重蹈它。

文中每個數字都是從真實執行捕獲的，不是從程式碼推的。

---

## 一句話

**替 RP2350 的認證器加上 `hmac-secret`，讓它交出一把「同一個鹽永遠給同一組
三十二位元組、而且必須有人按過按鈕」的對稱金鑰 —— 然後在路上撞出四個
從來沒有任何 client 行使過的缺陷。**

---

## 進度

### 新增

| | |
| --- | --- |
| [`exp189-the-same-salt-twice`](../experiments/exp189-the-same-salt-twice/) | 這條路上第一根產物**不是證據**的實驗 |
| [`crates/fuzzy-commitment`](../crates/fuzzy-commitment/) | exp181 的模糊承諾，從 exp182 的 2377 行 `main.rs` 抽出來，8 個主機測試 |

### 修好（全部硬體驗證）

| 位置 | 缺陷 |
| --- | --- |
| exp183 | `CTAPHID_INIT` 回 `0x08`（＝`NMSG`）而註解寫 `CBOR`；修好後暴露 `CBOR_BUF.init()` 在每個請求路徑上 —— **每次開機只能回答一個 CBOR 命令** |
| exp188 | `makeCredential` 的 `0x06` 是 extensions 卻讀成 `pinUvAuthParam`；`getAssertion` 的 `0x07` 是 uint 卻讀成 byte string |
| `crates/cbor` | `skip` 拒絕所有負數 map key —— 而每一個 COSE key 都是 `{1, 3, -1, -2, -3}` |
| exp186/187/188 | 九個指向不存在目錄的 lineage 連結 |

### exp189 的核心宣稱，已在板子上成立

```
PASS  the same salt twice gave the same thirty-two bytes, bit for bit
      salt one vs salt two: 125 of 256 bits differ
      credential A vs credential B, same salt: 110 of 256 bits differ
PASS  nobody pressed, 4 times, and no key came out   FIDO_ERR_OPERATION_DENIED
```

兩個臂的對照，**不需要板子**就成立：

| 映像檔 | `forge.py` | `not a secret. this is a test key` |
| --- | --- | --- |
| `exp189.uf2` | 偽造出一個 assertion | 在位元組裡 |
| `exp189-bank8.uf2` | 一無所獲 | 不在 |

`bank8` 臂在矽晶片上重建成功：拔電後 `534 / 7936` 個晶格改變（6.73%），
對照剛燒完的 `3419 / 7936`（零視窗）。糾錯碼每個金鑰位元容得下 31 格裡的
16 格，從來沒接近極限。

### 還欠

`bank8` 臂的**七次按鈕**（同一個鹽兩次，背後的秘密在任何檔案裡都不存在）。
指令是 `./bank8.sh` 然後 `./roundtrip.sh bank8`。README 的 Expected output
明說了這一格是空的。

---

## 檢討

六個錯誤，五類。每一類都附上**已經寫進 repo 的對策**，因為寫在這裡而沒有寫
進 `check.sh` 的教訓，等於沒有寫。

### 一、沒有先讀就先寫，於是重付了一次已經付過的代價

exp189 的 LED 一開始只有兩態（亮／不亮＝按我／沒事），然後我用一行印到
stderr 的文字要求使用者**拔線** —— 給一個沒在看終端機的人。

而 exp182 的原始碼裡早就寫著：

> *the LED is the debug channel, so design it before you need it, and exp180
> had already used three LED states for exactly this. **This one went back to
> words and cost a round trip to find out.***

它學過、寫下來了、就寫在被修好的那一行旁邊，而我沒讀。

**對策：** 動一條路上的新實驗之前，`grep` 那條路上**已驗證實驗的原始碼註解**，
不只是 README。這個 repo 的教訓多半寫在被修好的那一行旁邊，而不是在標題底下。
exp189 現在用 exp182 一模一樣的三態詞彙，`check.sh` 逐個守住。

### 二、儀器被測了，測量沒有

三次，同一個形狀：

- `check.sh` 對四份**捏造的** fixture 跑 `verify.py`，從來沒對真正入庫的
  `roundtrip.json` / `nopress.json` 跑過。於是一份它自己的驗證器會拒絕的紀錄
  留在庫裡，而 `check.sh` 是綠的。
- `roundtrip.sh` 無條件燒 `constant` 臂。對著一塊剛佈建好 `bank8` 的板子跑，
  它把金鑰來源的 SRAM 清零，然後花掉**七次按鈕**重測一個早就捕獲過的臂。
- `bank8.sh` 等「port 消失」當作拔線訊號 —— 但**燒錄本身就會讓 port 消失**，
  所以它把重開誤認成人的動作，讀了兩次 boot 1 還印出一段名為「boot 2」的東西。

**對策：**
- 任何判定腳本都要對**真實產物**執行，不只對 fixture。`check.sh` 現在對入庫的
  兩份 transcript 判定，而且只有一份在的時候直接失敗。
- 任何會花掉人力的步驟，先驗證它**花在對的東西上**。`roundtrip.sh` 的臂變成
  參數（`constant` / `bank8` / `keep`），而且只要板子的日誌說 `UNPROVISIONED`
  就連第一次按都不會開口要。
- 偵測人的動作要看**板子自己的時鐘**（重開會讓它倒退），不要看主機端的 port。

### 三、給人的指示走在人看不到的通道上

`ga-nopress` 這個案例走同一段韌體、點同一盞燈，所以我用**唯一到得了現場的
訊號**去要求那個絕對不能發生的按壓。金鑰吐出來兩次。

使用者的兩句話定案了這件事：*「如何知道是哪一個案例？只有 LED 可以用來指引」*
和 *「既然不要做就不需要講不是嗎？」*

**對策：** 現場的人只有板子。
- **一個訊號只能有一個意思。** 恆亮＝按我，永遠，沒有例外要記。
- **需要「不要做」的步驟，不該待在需要人的腳本裡。** 那個案例現在是
  `./nopress.sh`，Needs 1，啟動後走開。
- 韌體要記下**墊片何時真的讀到低電位**，並用板子自己的時鐘過濾（日誌是環形會
  回放），這樣意外的結果分得出「裝置自己設了那個 bit」和「有人按了」。

### 四、靜默失敗

`panic-halt` 讓 exp183 的三次死亡看起來跟壞掉的線一樣。exp189 又犯一次：
`SecretKey::from_slice` 對三十二個零回 `Err`（零不是合法的 P-256 純量），
`.unwrap()` 在 USB 開始服務之前就炸掉 —— **一塊在那之前死掉的板子，就是一塊
離開匯流排的板子**，只能用手救。

`bank8.sh` 也一樣：它安靜地放棄，然後印出一段不存在的 boot 2。

**對策：**
- 死掉要說話。exp183 和 exp189 都有 `#[panic_handler]` 印出檔名行號，
  `check.sh` 在 `panic-halt` 回來時失敗。
- 沉默要有意義。兩秒一次的心跳讓「閒著」和「死了」變成不同的觀察。
- 抓得到 hang 的只有上膛的 watchdog（`crates/breadcrumb`），而且它讓板子
  **自己重開** —— 那之後每一次迭代都免費。
- 放棄要非零退出並說為什麼。沒有「沒發生的 boot 的讀數」這種東西。

### 五、斷言走在證據前面

三次：

| 我說的 | 當時的證據 | 真相 |
| --- | --- | --- |
| 「libfido2 一個 CBOR 都不會送給它」 | `FIDO_ERR_RX` | 那跟「沒人按按鈕」一樣說得通，判定不了 |
| 「`bank8` 臂只是 trait 住錯目錄」 | 沒讀那個 backend | exp183 的 `Bank8SecureBackend` 是把**編譯進去的種子**寫進 bank 8 再讀回來 |
| `EXP189_SKIP_FLASH=1` | 無 | 我在指令列上發明了一個腳本裡不存在的東西，代價是七次按鈕 |

**對策：** 聲稱一個機制之前，找一個**能區分它與競爭解釋**的測量。第一項後來
是這樣定案的：用 repo 自己的 client 直接問 `getInfo`，它答得出來，而 libfido2
連問都沒問 —— 兩條路唯一的差別就是那個能力位元組。

### 六、修好一個洞，讓另一個更深

- 第一版 `bank8` 臂照設計從 SRAM 重建金鑰，`forge.py` **還是**偽造成功 ——
  因為 `DEVICE_SECRET` 那個常數還編譯在裡面，沒被用到而已。
  **一個在檔案裡的秘密，就是任何拿到那個檔案的人的秘密。**
- 第一版「沒有秘密就不 spawn CTAPHID task」把**整塊板帶下 USB** —— 因為 HID
  介面在描述元裡照樣宣告，而沒有人服務的介面比會拒絕的介面糟糕得多。

**對策：** 每個「修好了」之後問一次：**這支映像檔在最壞的讀者眼中是什麼樣子？
這塊板在最不客氣的 client 眼中是什麼樣子？** 前者現在是 `check.sh` 讀兩支映像檔
的位元組；後者是「照常服務、用自己的狀態碼拒絕」。

---

## 這一輪做對的三件事，值得複製

1. **零按鈕的 A/B。** 很多結論根本不需要人：解析錯誤發生在等按鈕**之前**，
   所以兩種拒絕的**時間長度**就是答案 —— `0.094 s` 對 `60.099 s`、
   `0.095 s` 對 `20.109 s`。
2. **用舊版寫的紀錄驗證新版的抽取。** `crates/fuzzy-commitment` 重建出
   exp182 六天前用內嵌程式碼登記的金鑰，記錄從沒被覆寫過 —— 沒有辦法作假。
3. **先讓迭代變便宜，再開始迭代。** exp183 前三輪各花一次走到桌邊；裝上
   heartbeat、會說話的 panic handler、封包日誌與上膛 watchdog 之後，剩下的
   全部免費。這就是 [`the-board-is-the-loop`](./the-board-is-the-loop.md) 的
   算術，實際發生一次。

---

## 一句總結

這一輪四個缺陷有一個共同點：**沒有任何 client 問過那個問題，所以沒有人發現
答案是錯的。** exp183 的能力位元組讓每一個 libfido2 client 連第一個 CBOR
都送不出去，於是沒有人送到第二個；exp188 的 extensions 沒有人送過；
`crates/cbor` 的負數 key 沒有人跳過過。

而我自己的六個錯誤也有一個共同點：**儀器沒有被它要測的東西測過。**
兩者是同一句話的兩面。
