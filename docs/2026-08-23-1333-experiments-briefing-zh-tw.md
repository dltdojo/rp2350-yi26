# rp2350-yi26 實驗簡報

**快照時間：2026-08-23 13:33 UTC** · 涵蓋 exp101 – exp179，共 79 個實驗

這份文件是整個實驗集的鳥瞰圖，用正體中文寫給第一次接觸這個 repo 的人。
它不取代任何一個實驗自己的 README —— 那些才是權威來源，這裡只負責回答
「這 79 個實驗到底在做什麼、彼此怎麼接起來、我該從哪裡進去」。

文中每個數字都是從 repo 當下的檔案算出來的，不是從記憶或既有敘述抄的；
算法附在最後一節，你可以自己重跑一次。

---

## 一句話

**用 Rust + Embassy 把 RP2350 的 USB 控制器、安全性架構與真實周邊從頭到尾摸過一遍，每一步都在真板子上跑過才寫下來。**

技術選型是排他的，不是偏好問題：

| 用 | 不用 |
| --- | --- |
| `no_std` Rust | C / C++ |
| [Embassy](https://embassy.dev) 非同步框架 | Pico SDK |
| `embassy-usb` 裝置堆疊 | TinyUSB |
| `async` / `await` | 阻塞式 HAL、RTOS 執行緒 |

選 Rust 的理由集中在 USB 與安全性這個特定領域：描述元解析、端點緩衝區與 CBOR 協定解碼正是 C 韌體最容易寫出記憶體安全漏洞的地方，而借用檢查器在編譯期就把那一類錯誤排除，執行期零成本。周邊所有權被 move 而非按慣例共享，所以兩段程式碼不可能同時驅動同一個端點。

選 Embassy 的理由更直接：**USB 裝置與安全周邊本質上就是一堆大多時間閒置、由中斷驅動的並行狀態機** —— 控制管線、每個類別介面、每個端點、網路 Socket 與非同步加解密。`await` 直接表達「等下一個 SETUP 封包」或「等下一個網路請求」，不必在中斷處理常式裡手刻狀態機。

---

## 標的硬體

[RP2350](https://www.raspberrypi.com/products/rp2350/)，Raspberry Pi Pico 2 上的微控制器：

- 雙核心，可在 Arm Cortex-M33 與 RISC-V Hazard3 之間切換
- 520 KB 晶片內 SRAM（512 KB 主記憶體 + 兩個 4 KB 獨立 Bank）
- USB 1.1 控制器，**device 與 host 雙角色**
- 3 個 PIO 區塊 / 12 個狀態機
- 安全功能：Arm TrustZone-M (SAU)、`ACCESSCTRL` 匯流排過濾器、簽章開機、OTP 熔絲

**幾乎不綁特定板子。** BOOTSEL、UF2 開機磁碟、USB 控制器全部住在 RP2350 自己的 ROM 與矽晶片裡，任何 RP2350 設計的行為都一樣。只有兩件事跟板子有關，而且都是改一行：LED 的 GPIO（預設 `PIN_25`），以及封裝 feature（`rp235xa` 30 腳 vs `rp235xb` 48 腳）。驗證一律在正式版 Pico 2（non-W）上做。

---

## 規模

| 項目 | 數量 |
| --- | --- |
| 實驗（exp101 – exp179） | **79** |
| 共用 Rust crate（`crates/`） | **16** |
| WebUSB 網頁（`tools/pages/`） | **5** |
| 主機端工具 | **1**（`tools/yi26`） |
| 設計決策公告（`docs/announcements/`） | **20**（19 篇專文 + 索引） |

16 個 crate 是被抽出來、可以獨立測試的協定與策略邏輯，不含 socket 也不含硬體：
`bootsel`、`breadcrumb`、`cbor`、`dhcp`、`draw`、`entropy-health`、`fat12`、`framing`、`http-route`、`image-integrity`、`log-policy`、`log-ring`、`mdns`、`partition-table`、`usb-log`、`usb-reboot`。

5 個網頁全部是 WebUSB，不需要任何工具鏈就能在手機瀏覽器上跑：描述元檢查器（`inspect`）、日誌檢視器（`log`）、主控台（`console`）、把板子送進 bootloader（`bootsel`）、以及**直接寫入韌體**的 `pflash`。從 exp126 之後，這些頁面由板子自己供應。

---

## 實驗地圖

79 個實驗不是平鋪的清單，而是幾條各有終點的軌道。

### 起步（exp101 – exp103）

證明三件事各自獨立成立：**硬體鏈**（板子、線、主機看得到彼此，還沒有 Rust）、**編譯鏈**（這台機器能交叉編譯 RP2350 韌體，不需要板子）、**兩者接起來**（原始碼變成會閃的 LED）。

exp103 是整個 repo 最簡單的韌體，卻是最難自動驗證的一個 —— 原因見下面的 Needs 分級。

### USB 基礎（exp104 – exp107）

板子透過 CDC-ACM 回話；韌體把自己送進 bootloader，**BOOTSEL 按鈕從此退休**（exp105 之後的韌體都能靠 1200-baud touch 自己重開）；三個任務共用一條序列日誌，而且印東西不會卡住工作。

### 晶片自己的感測器與熵源（exp108 – exp114）

這一段從「讀溫度」開始，很快變成一串關於**如何不被自己的測試騙**的實驗：

- **exp109** —— 真實熵源，以及索取它的代價：一個**錯了好幾千倍**的驅動預設值
- **exp111** —— 兩個看起來都很隨機的來源，以及兩個廉價測試能與不能告訴你的事
- **exp112** —— 一個悄悄不再使用硬體 RNG 的建置，以及**每一個沒察覺的測試**
- **exp113** —— 一個板子自己 46 毫秒就能窮舉的種子：為什麼「空間大」不等於「熵高」
- **exp114** —— SP 800-90B 規定的兩個連續測試，以及一個測試失敗就拒絕輸出的來源

### 瀏覽器軌，已完成（exp115 – exp126）

十二個實驗指向同一個目的地：**用手機除錯韌體**。板子插進 Android 手機，開一個網頁，讀裝置自己的日誌 —— 不裝 app、不用第二台電腦、不用除錯探針。

之所以重要，是因為**手機是最難對付的主機**：它唯一的 USB 埠正被待測裝置佔著，所以 `adb` 剛好在你最需要的時候不能用，而原廠手機上沒有 Wireshark。當你無法從主機端觀察，裝置就必須觀察自己，而你必須能在手機上讀到。

終點：一支只有一個 USB 埠的手機可以**燒錄**板子（exp117）、**跟它對話**（exp120）、**讀它的日誌**（exp116），而且日誌頁面是從板子本身供應的（exp126）。

### 框架與所有權軌（exp127 – exp137）

主機用一個位元組改變板子，而 **LED 不再是韌體還活著的證據**（exp127）。接著是一串關於「訊息邊界從哪裡來」的實驗：手工重組封包、一個沒有位元組的封包（ZLP）、從中途加入資料流（COBS vs Length-prefix）。還有抽獎應用與三種日誌留存策略（exp134）。

### 更新之路（exp138 – exp147）

RP2350 的 ROM 裡有分割表、A/B 連結、會比較的映像版本號、try-before-you-buy 旗標、`pick_ab_parition` 和 `explicit_buy`。這條路用已經在那裡的東西，量出手刻一套本來能多買到什麼：

- 分割表放在 flash 位移 0 於是韌體得搬家（exp139）
- CRC 能被四個位元組偽造 vs 雜湊不可偽造（exp140）
- PICOBOOT 介面直接從手機瀏覽器抹除與寫入 flash（exp141, exp146）
- 雙槽 A/B 映像依版本號自動選擇開機（exp142）與試用逾時回滾（exp143）
- 手機端一鍵完成雙韌體更新編排（exp147）

### 網路之路，已完成（exp148 – exp153, exp155, exp161）

CDC-NCM 讓板子化身為免驅動的 USB 乙太網路卡，插上手機或筆電即可化身為 Web 伺服器：

- **exp148 – exp149** —— 板子自建 DHCP 伺服器回答 DISCOVER 與 REQUEST，2 毫秒發出位址。
- **exp150 – exp152** —— 板子服務靜態網頁與即時日誌；配合虛擬 FAT12 磁碟，在取得 IP 後自動掛載，提供 `OPEN.HTM` 讓手機一鍵點擊進站。
- **exp153** —— 透過 Android 乙太網路分享連上外網，發送 HTTP 請求到 `1.1.1.1`，推翻「手機不能做 NAT」的假設，量測 Captive Portal 204 與沒有 TLS 的 301 代價。
- **exp161** —— 一個埠 4 個路由（`/`, `/log`, `/status`, `/trng`），量測出並行的瓶頸不是 URL 空間，而是唯一的 TRNG 硬體週邊。
- **exp155** —— 首次透過網路控制硬體 LED；實測證明 CORS 不擋請求發送，唯有非簡單標頭觸發 Preflight 才能在動作前進行來源審查。

### 簽章之路，已完成（exp154, exp156 – exp160, exp162, exp163）

回答「這顆晶片能保守秘密嗎？」的完整硬體測量（詳見 [`docs/can-this-chip-keep-a-secret.md`](./can-this-chip-keep-a-secret.md)）：

- **exp154** —— 掃描 4096 列 OTP 熔絲，證明 OTP 只能儲存、不能隱藏金鑰。
- **exp156** —— 透過 `ACCESSCTRL` 與 `FORCE_CORE_NS`，以三讀量測法確認硬體隔離牆存在。
- **exp159** —— 在 SRAM Bank 8 生成 P-256 私鑰，Flash 從未出現金鑰；Non-secure 讀取觸發 Fault，但可透過 mailbox 請求 61 毫秒代簽。
- **exp160** —— 後量子 ML-DSA-65 運作狀態高達 65 KB，溢出至公開堆疊，私鑰 seed 被 Non-secure 核心當場撈出。
- **exp162** —— 揭露主 SRAM Bank 0–7 為 4-byte 交錯結構，`ACCESSCTRL` 無法在主記憶體建立大區塊連續隔離區。
- **exp163** —— 輪詢量測金鑰暴露時間窗；擦除（Wipe）僅需 2.3% 時間，但每次從 seed 重新展開金鑰占據總耗時的 63%。

### 屬性之路（exp164 – exp165）

深入 Armv8-M 安全性架構：

- **exp164** —— 使用 `TT` 指令讀取 SAU，證實 `ACCESSCTRL.FORCE_CORE_NS` 標記的是匯流排而非 CPU 核心架構狀態，核心本體依然處於 Secure。
- **exp165** —— 首次配置 SAU 區域；在 SRAM Bank 9 配置 Non-secure 成功，但在 Bootrom 與 `SIO_NS` 的設定被更高層級的屬性單元靜默覆寫（Overrule）。

### 韌體驗證之路（exp166 – exp167）

回答「這塊板子會接受誰的韌體？」：

- **exp166** —— 首次在板子上驗證 P-256 數位簽章（97.7 毫秒）；確立「簽章需要秘密，驗證只需完整性（公鑰）」原則；設計 `wrong-region` 測試確保簽章綁定位址區間。
- **exp167** —— 由當前運行的 Slot A 驗證 Slot B；遭遇 QMI `ATRANS` 視窗邊界 HardFault 限制，確立必須在 RAM 中驗證後再寫入 Flash 的架構。

### 安全金鑰之路（exp168 – exp178）

手刻打造能在真實瀏覽器與真實網站運作的 FIDO2 / WebAuthn 實體安全金鑰器具：

- **exp168** —— 從純 CTAPHID 堆疊起步，手寫 HID 描述元免裝 udev 規則，以標準協定語言宣告一無所知。
- **exp169 – exp170** —— 手刻 `crates/cbor` 規範編碼與嚴格解碼器，防範長度欺騙與非正規 CBOR。
- **exp171 – exp172** —— WebAuthn P-256 憑證與登入斷言；私鑰由裝置秘密、TRNG 與 RP ID 即時衍生，Flash 完全不存使用者金鑰；以恆定時間比對 HMAC 標籤。
- **exp173** —— 與官方 `libfido2` 對接，解析 `FIDO_ERR_INVALID_PARAM` 為無使用者在場，具備 `FIDO_2_0` 資格。
- **exp174** —— 走進真實 Chrome 與 `webauthn.io` 登入！修正 TRNG 採樣速度（1400 倍提升）並引入 `CTAPHID_KEEPALIVE` 心跳封包突破瀏覽器 20 秒超時限制。
- **exp175** —— 離線攻擊示範：純從 `.uf2` 檔案提取常數偽造合法 WebAuthn 斷言（檔案即身分）。
- **exp176 – exp178** —— 橫向對比 YubiKey、開源 C 實作 `pico-fido` 與 Google OpenSK (Rust) 框架。

### 身分之路（exp179）

探索物理不可複製函數（PUF）的物理基礎：

- **exp179** —— 拔除 USB 傳輸線冷開機（Cold Boot），量測 520 KB SRAM，證明通電時並未清零（50.5% ~ 51.2% 均勻隨機分佈），推翻過往文獻斷言，證明全零是燒錄工具所致，為 SRAM PUF 固有身分鋪路。

---

## 貫穿全案的方法論

### 一、Needs 分級：這個實驗要花掉多少「人」

每個實驗都標了 0 到 3 的 **Needs**，回答一個問題：**凌晨兩點、板子插著、沒有其他人醒著的時候，我能做哪些？**

| 級別 | 意思 | 數量 |
| --- | --- | --- |
| **0 · 完全不用** | 連板子都不用，一台機器就夠 | 3 |
| **1 · 一塊板** | 板子接著，之後純軟體 | 45 |
| **2 · 一個動作** | 一個人做一個動作，其餘軟體自己來 | 21 |
| **3 · 一個人** | **人就是量測儀器** —— 這裡沒有東西看得到結果 | 10 |

這個數字防呆：它寫在 `check.sh` 裡緊鄰它描述的程式碼旁邊（`PRESENCE=x`），而 `lib.sh` 的 `presence_check` 會在它和索引表不一致時失敗 —— **所以那張表沒辦法悄悄爛成一個謊言。**

### 二、兩個腳本，一份共用程式庫

每個實驗目錄裡都有同樣兩個腳本：`run.sh`（互動式導覽）與 `check.sh`（快速非互動判決）。共用函式庫 `lib.sh` 統一了平台守衛、PASS/FAIL 計算與顯示。

### 三、任何平台相關的東西都屬於工具，不屬於腳本

`tools/yi26` 統一封裝所有 host 端的底層操作（序列埠讀寫、WebUSB 卸載、PICOBOOT 燒錄、FIDO 查詢等），每個指令都支援 `--explain` 說明背後原理。

### 四、沒在真板子上跑過就不發布

所有提交至 `main` 的成果都必須在實體硬體上親眼驗證過。`Expected output` 區塊永遠是真實硬體輸出的貼上紀錄，絕非預測值。

---

## 幾個最值得帶走的發現

| 實驗 | 發現 |
| --- | --- |
| **exp109 / exp174** | 驅動預設值錯上好幾千倍（TRNG `sample_count`），埋伏 65 個實驗後在真實瀏覽器面前被捕獲 |
| **exp138** | 大家白手起家刻的 A/B 更新機制，RP2350 的開機 ROM 裡本來就有，只要開口問 |
| **exp140** | 四個位元組就能把 CRC 偽造成任意值，同樣攻擊對雜湊失效：可靠性 ≠ 真實性 |
| **exp153** | 推翻「手機不能做 NAT」的主張 —— 乙太網路分享就是開關 |
| **exp155** | CORS 從來不擋請求發送，只有 Preflight 能在動作發生前進行來源審查 |
| **exp160 / exp162** | 後量子金鑰運作集達 65KB 溢出至公開堆疊，SRAM 4-byte 交錯使主記憶體無法大面積隔離 |
| **exp164** | `FORCE_CORE_NS` 標記的是匯流排而非 CPU 架構核心狀態 |
| **exp166** | 簽章需要秘密，驗證只需要完整性 —— 驗證端根本不需要硬體隔離牆 |
| **exp174** | 瀏覽器等待按鈕的耐心只有 20 秒，`CTAPHID_KEEPALIVE` 是真實器具的關鍵守衛 |
| **exp175** | 沒有硬體安全熔絲時，二進位檔案本身就是身分，純靠 `.uf2` 即可偽造斷言 |
| **exp179** | 拔掉傳輸線冷開機，SRAM 並未被硬體清零，推翻過往文獻迷思，打開 SRAM PUF 之門 |

---

## 現況與下一步

- **起步與 USB 基礎軌（exp101–exp107）：完成。**
- **晶片感測器與熵源軌（exp108–exp114）：完成。**
- **瀏覽器軌（exp115–exp126）：完成。**
- **框架與所有權軌（exp127–exp137）：完成。**
- **更新之路（exp138–exp147）：完成。**
- **網路之路（exp148–exp153, exp155, exp161）：完成。**
- **簽章之路（exp154, exp156–exp163）：完成**，產出機密性評估文件 [`docs/can-this-chip-keep-a-secret.md`](./can-this-chip-keep-a-secret.md)。
- **屬性之路（exp164–exp165）：完成**第一階段 SAU 與記憶體定義探測。
- **韌體驗證之路（exp166–exp167）：完成。**
- **安全金鑰之路（exp168–exp178）：完成**，手刻 CTAPHID/WebAuthn 於真實瀏覽器驗證通過，並完成開源/商業方案比對。
- **身分之路（exp179–）：進行中。** exp179 完成了 SRAM 冷開機隨機分佈驗證，後續將推進溫度漂移對比與實體不可複製函數（PUF）穩定性量測。

---

## 這份文件的數字怎麼來的

全部可重跑：

```sh
# 實驗目錄數（79 個已索引 + 1 個進行中）
ls -d experiments/exp* | wc -l                    # → 80
# 索引列數
grep -oP '^\| \[exp\d+[^\]]*\]\([^)]*\)' experiments/README.md | wc -l  # → 79

# 共用 crate 數
ls crates/ | wc -l                                # → 16

# 網頁數
ls tools/pages/*.html | wc -l                     # → 5

# 公告檔案數（含 README.md，共 19 篇專題文章）
ls docs/announcements/*.md | wc -l                # → 20

# Needs 分佈，直接從索引表統計
sed -n '/^## Index/,/^## The browser track/p' experiments/README.md \
  | grep -oP '^\| \[exp\d+[^\]]*\]\([^)]*\) \| \K[0-3]' \
  | sort | uniq -c
#   3 0
#  45 1
#  21 2
#  10 3
```

---

## 延伸閱讀

| 想知道 | 讀 |
| --- | --- |
| 完整實驗索引與所有軌道 | [`experiments/README.md`](../experiments/README.md) |
| 技術選型的理由 | [`README.md`](../README.md) |
| 給 AI 代理人的規矩 | [`AGENTS.md`](../AGENTS.md) |
| 這顆晶片能保守秘密嗎 | [`docs/can-this-chip-keep-a-secret.md`](./can-this-chip-keep-a-secret.md) |
| 用別人的手機除錯要花什麼代價 | [`docs/debugging-on-a-phone.md`](./debugging-on-a-phone.md) |
| 沒有 Linux 怎麼辦 | [`docs/platforms.md`](./platforms.md) |
| 哪些 zip 已經被實際走過 | [`docs/pack-verification.md`](./pack-verification.md) |
| 設計決策與實戰公告紀錄 | [`docs/announcements/`](./announcements/) |
