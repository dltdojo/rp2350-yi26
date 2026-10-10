# 用 C 寫 CDC，和 Rust + Embassy 有什麼不同

<!-- SPDX-License-Identifier: Apache-2.0 -->

這份文件比較兩種讓 Pico 2 透過 USB 說話的做法：

- **C 版**：exp226 到 exp227 在 RISC-V 殼層上用 C 自己寫的 CDC-ACM 裝置。
- **Rust 版**：這個 repo 先前七十多個實驗共用的 Rust + Embassy 做法。

文中的數字都是在這個 repo 裡量出來或數出來的，每個數字旁邊都寫了出處。只量過一次、還不能當結論的地方，也會直接寫明。

## 先說兩條路各在哪裡

**Rust 版**
- 從 exp104 開始，這個 repo 的韌體大多是 Rust，跑在 RP2350 的 ARM Cortex-M33 核心上。
- USB 用的是 `embassy-usb` 0.6.0 和 `embassy-rp` 0.10.0。
- repo 自己在上面包了三個 crate：
  - `crates/cdc-console`：開一個序列埠；
  - `crates/usb-log`：送記錄；
  - `crates/usb-reboot`：1200 baud 重開進燒錄模式。
- 根據 `crates/cdc-console` 開頭的說明，有七十五個實驗用同一套寫法開 CDC 埠。

**C 版**
- 從 exp209 開始，「已驗證 kernel」這條路改用另一顆核心：同一顆晶片上的 Hazard3 RISC-V。
- 架構分兩層：
  - 一個用 C 寫的殼層（shell）跑在 Machine mode；
  - 經過 Lean 證明的 kernel 跑在 User mode，被 PMP 圍住。
- 殼層的工作很單純：載入 kernel、執行、量 `minstret`，再把結果用 LED 閃出來。
- exp226 之前，這條路上沒有任何 USB。

**為什麼 exp226 用 C 自己寫，而不是把 Embassy 搬過來**
- 殼層本身就是 C，加上 `tools/hazard3/harness/harness.S`。整個殼層要小到可以從頭讀到尾。
- 它要掌控每一個 trap，量出來的指令數也要跟 RTL 模擬器上一模一樣。
- exp210 和 exp212 都擔心過「加 USB 協定堆疊會擴大信任範圍」。

這不是說 Embassy 做不到 RISC-V。這件事這裡沒有查證，也不是這次選 C 的理由。

## 一覽

| | Rust + Embassy | C（exp226、exp227） |
| --- | --- | --- |
| 核心 | ARM Cortex-M33 | Hazard3 RISC-V |
| 誰處理 USB 協定 | `embassy-usb`（上游） | `tools/hazard3/shell/usbdev.c`（repo 自己寫） |
| 誰碰 USB 控制器的暫存器 | `embassy-rp` 的 `usb.rs` | `tools/hazard3/shell/usb_chip.c`，照 embassy-rp 0.10 的寫入順序 |
| 時脈 | `embassy_rp::init(Default::default())` 把 clk_sys 設成 150 MHz（PLL_SYS），clk_ref 接晶振 | 只啟動 PLL_USB，clk_usb 和 clk_sys 都接 48 MHz；clk_ref 留在 ROSC |
| 執行方式 | USB 中斷加 async executor，任務各自等待 | 沒有中斷；每一次等待都呼叫 `usb_poll()` 輪詢 |
| 裝置長相 | 1209:0001、EF/02/01、IAD、0x81 / 0x01 / 0x82，設定描述元 70 bytes | 逐位元組相同（`usbdev_test.py` 拿 exp115 從真板錄下來的樹比對） |
| 主機打開埠以前 | `usb-log` 等 DTR，不寫 | 一樣：沒有 DTR 就不送 |
| 佇列滿了 | `usb-log` 在下一行前面標出 `(+N lines lost)` | 一次寫入整筆捨棄，數量記在狀態行的 `dropped=` |
| 1200 baud 重開 | 有（`usb-reboot`，預設開啟） | 沒有，回燒錄模式要用手按 BOOTSEL |
| 複合裝置（HID、MSC 等） | 有（`open_composite`） | 沒有，只有一個 CDC |
| 主機 → 板子（bulk OUT） | 有，`console.html` 用得到 | 端點有開，但還沒傳過任何一個位元組 |

## 時脈：這次最大的教訓

在 Rust 這邊，時脈是一行 `embassy_rp::init(Default::default())` 就決定了。我讀了 `embassy-rp` 0.10.0 的原始碼，它的 `Config::default()` 是 `ClockConfig::crystal(12_000_000)`：

- **clk_sys**：PLL_SYS 是 12 MHz × 125 ÷ (5 × 2) = 150 MHz，clk_sys 接在它上面。
- **clk_usb**：PLL_USB 是 12 MHz × 120 ÷ (6 × 5) = 48 MHz，clk_usb 接在它上面。
- **clk_ref**：接晶振。

寫 Rust 韌體的人不必知道這些，七十多個實驗也從來沒有為時脈煩惱過。

C 殼層原本完全不碰時脈，沿用開機程式留下的狀態。exp226 第一次量了這個狀態：

- clk_ref 和 clk_sys 都接在 ROSC 上；
- clk_sys 在三次開機分別是 10966、10950、10943 kHz；
- 晶振是關的。

exp226 第 3 版只啟動 PLL_USB、讓 clk_usb 跑 48 MHz，clk_sys 還留在 11 MHz。結果：

- 用晶片的頻率計數器對晶振量，clk_usb 確實是 48 MHz；
- 主機也確實重設了匯流排；
- 但列舉就是不會完成。

前三輪上板，列舉都沒有完成。第 4 版把 clk_sys 也移到 PLL_USB 的 48 MHz，第一次就列舉成功了。

所以推論是：**USB 控制器需要 clk_sys 至少跟 clk_usb 一樣快。** 但要說清楚，這只是一輪上板的推論，不是量出來的門檻：沒有任何一版讓 clk_sys 跑在 11 到 48 MHz 之間。

這件事的意義不在 C 或 Rust 哪個好。重點是：**框架替你做的決定，你就看不到。** Rust 這邊從來沒遇過這個問題，不是因為它比較懂硬體，而是因為 `init` 的預設值剛好避開了它。換到自己寫的那一刻，這個沒寫下來的前提就變成三次上板。

## 執行方式：中斷加 async，對上輪詢

Embassy 的 USB 驅動是靠中斷驅動的：`crates/cdc-console` 綁定 `USBCTRL_IRQ`。協定處理和記錄輸出都是 async 任務，由 executor 排程。韌體的其他部分可以專心做自己的事，USB 在背景被照顧。

C 殼層刻意不開任何中斷，`usb_chip.c` 開頭就這樣寫。USB 控制器每一個要處理的事件，都靠 `usb_poll()` 在等待迴圈裡去問。所以殼層的每一個等待，都得順便呼叫它：LED 每一拍之間的空檔、每段生命之間的停頓、開機後前幾秒的列舉，全部都要。這件事收在 `speak.h` 的 `pwait()` 裡。

**好處**：kernel 在 User mode 跑的那段時間，沒有任何東西會插進來。

- exp225 證明了 kernel 正好執行 3079 個指令，RTL 上量到的 `minstret` 是 3082。
- 加了 USB 以後，晶片上每一行 LIFE 回報的仍然是 3082（`0x0c0a`），exp226 和 exp227 的板子紀錄都是。

USB 沒有改變被量的東西，這正是殼層需要的性質。

**代價**：殼層有某一段時間沒在輪詢，主機的請求就得等。這次每段生命開始前的工作，大致有這些：

- 把 64 KiB 的區域清零；
- 對 kernel 算 SHA-256；
- 跑 kernel，約 64 µs。

這些時間沒有實際量過。三輪成功的上板裡，匯流排錯誤都是 0，列舉也都完成了，但這只說明這次的工作量沒有超過主機的耐性，不保證以後更長的工作也沒事。

## 程式量與信任範圍

**C 版：全部都在 repo 裡**

| 檔案 | 行數 | 內容 |
| --- | --- | --- |
| `usbdev.c` / `usbdev.h` | 284 / 85 | 描述元、EP0 請求、bulk IN 佇列；不碰任何暫存器 |
| `usb_chip.c` / `usb_chip.h` | 343 / 42 | XOSC、PLL_USB、時脈量測、控制器 |
| `speak.h` | 223 | 狀態行、文字格式化、會輪詢的等待、LED 的兩種形狀 |
| `usbdev_test.py` | 301 | 主機端測試 |

編成 RISC-V 目的檔以後，`usb_chip.o` 的 text 是 2628 bytes，`usbdev.o` 是 2328 bytes，合計約 5 KB。exp227 整個映像檔是 11456 bytes，裡面還包含 kernel、harness 和 SHA-256。

**Rust 版：大部分在上游**

- repo 自己的三個 crate：`cdc-console` 291 行、`usb-log` 734 行、`usb-reboot` 182 行。
- 底下的上游程式：`embassy-usb` 0.6.0 共 7323 行；`embassy-rp` 0.10.0 的 `usb.rs` 836 行、`clocks.rs` 2178 行。
- 以 exp190 為例，相依樹有 117 個 crate，其中 16 個名字帶 embassy。
- exp190 在 thumbv8m 上以 release 建置，text 是 23308 bytes。這個數字包含 executor、計時器、`lifeline`、`breadcrumb` 和記錄，不只是 USB，所以**不能**拿來跟上面的 5 KB 一對一比較。

**信任方式不同**

- Rust 這邊信任的是上游：很多人用、很多板子跑過。repo 不測 `embassy-usb` 本身；`usb-log` 有 12 個單元測試，`cdc-console` 和 `usb-reboot` 沒有。
- C 這邊沒有上游可以信任，只能靠自己測。所以把程式切成兩層：
  - **`usbdev.c`**：不碰任何暫存器，所以能在主機上用 ctypes 完整測試，33 項宣稱外加 7 個故意寫錯的版本（mutant）。它的描述元拿去跟 exp115 從一塊跑 Rust 韌體的真板錄下的樹比對，所以 C 裝置在主機眼中跟 Rust 裝置一模一樣。`tools/pages/` 的網頁一行都不用改，`log.html` 直接就能讀 exp226。
  - **`usb_chip.c`**：碰暫存器，沒有模擬器可以跑，只能上板。照 embassy-rp 的寫入順序寫，是讓它少錯的辦法，不是證明它對。

## 上板的成本

| 實驗 | 輪數 | 結果 |
| --- | --- | --- |
| exp226 | 1–3 | 列舉不完成：第 1 輪 LED 看不懂，裝置選單是空的；第 2 輪停在匯流排重設之後；第 3 輪出現錯誤 4（exp225 的第 4 項檢查，原因至今不明），選單又是空的 |
| exp226 | 4 | clk_sys 改成 48 MHz 後列舉成功，也讀到 log |
| exp226 | 5 | 修好 log 的三個小問題（行被截斷、半行、異常的 sof_khz） |
| exp227 | 1 | 第一輪就成功，LED 和網頁同步 |

Rust 這邊的 USB，前人早在上游付清了上板的代價，這個 repo 直接拿來用。C 這邊只能自己重新付一次，而且付在最貴的地方：雲端開發、沒有板子，每一輪都要有人走一趟。

付清之後，代價就不會再來：

- exp227 把 exp226 的 USB 部分搬進 `speak.h`，exp226 的 UF2 仍然逐位元組相同；
- exp227 第一次上板就成功。

之後這條路上的每一個實驗，都可以從這裡開始。

## C 版目前還缺的

- **沒有 1200 baud 重開。** 要回燒錄模式只能按 BOOTSEL，所以每個實驗的 lifeline 欄位都寫 no。`usbdev.c` 收得到 SET_LINE_CODING，要加這個功能是做得到的，但還沒做。
- **bulk OUT 沒有實際用過。** 主機送給板子的方向，端點有開，但一個位元組都還沒傳過。
- **沒有處理 USB 的休眠和喚醒。** `usb_chip.c` 裡沒有 suspend 或 resume 的處理。exp226 第 4 輪看到一個像是匯流排停了約 80 秒的量測值，那和休眠有沒有關係，還不知道。
- **只有一個 CDC。** 沒有複合裝置，也沒有 Embassy 那種介面數量的預算問題。
- **記錄遺失的標示比較粗。** 只有狀態行的 `dropped=` 計數，沒有 `usb-log` 那種在下一行前面標出遺失幾行的寫法。

## 怎麼選

- **一般韌體用 Rust + Embassy。** 功能齊全：重開、複合裝置、雙向傳輸都有，上游也已經被大量使用。不需要從頭讀完 USB 堆疊的時候，這是代價最低的路。
- **已驗證 kernel 的殼層用 C。** 殼層要小、要能整個讀完、不能有中斷，量出來的指令數也要跟模擬器一樣，這些是 Embassy 的設計目標以外的事。
- **代價要算清楚。** 自己寫，就要自己付上板的成本，還要把框架原本替你決定的事一件件找出來，例如時脈。exp226 用四輪換到了一個能在主機上測試的裝置邏輯，也換到了一套別的實驗可以直接引用的共用程式。

## 出處

- `crates/cdc-console/src/lib.rs`：七十五個實驗、介面預算、`USBCTRL_IRQ`。
- `crates/usb-log/src/lib.rs`：DTR 等待、`(+N lines lost)`。
- `crates/usb-reboot/src/lib.rs`：1200 baud 重開。
- `embassy-rp` 0.10.0 `src/lib.rs`（`Config::default`）、`src/clocks.rs`（`ClockConfig::crystal`）。
- `tools/hazard3/shell/usb_chip.c`、`usbdev.c`、`speak.h`、`usbdev_test.py`。
- [exp226 的 README](../exp226-the-shell-that-speaks/README.md)：每一輪的上板紀錄和時脈量測。
- 本實驗的 [README](./README.md) 和 `board/round1-life.txt`。
- 數字的量法：行數用 `wc -l`；目的檔大小用 `llvm-size`，C 用殼層的編譯旗標 `-Os`、rv32im，Rust 用 exp190 自己的 release 設定（`opt-level = "s"`、LTO）；相依樹用 `cargo tree --offline`。都在 2026-10-10 量的。
