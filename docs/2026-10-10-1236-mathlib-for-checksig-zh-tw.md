# 要不要為 OP_CHECKSIG 引入 Mathlib

<!-- SPDX-License-Identifier: Apache-2.0 -->

2026-10-10 的評估。起因是兩個問題：

- Bitcoin Script 這種 stack machine 能不能在 RP2350 的 RV32 上做形式化驗證？
- 其中最重的 `OP_CHECKSIG`（secp256k1 上的 ECDSA 或 BIP340 Schnorr 驗章），值不值得為它引入 Mathlib？之後還會有更多密碼學運算要證明。

這份文件回答第二個問題。

**結論：現在不引入。** `OP_CHECKSIG` 的證明，工作量大半落在 Mathlib 幫不上的地方；Mathlib 能幫上的部分，有一半核心 Lean 已經做得到（第三節的實測）。等真的有一個證明卡在 Mathlib 擅長的事情上，再引入，而且只讓那幾個定理依賴它。

這份評估沒有用到板子。文中「實測」的部分，都是在雲端 session 裡跑出來、貼上的輸出。

## 一、先修正一個說法：Mathlib 的成本不在「信任」

[2026-10-02 的 briefing](./2026-10-02-0930-verified-kernel-road-briefing-zh-tw.md) 決定不用 Mathlib，理由寫的是「少一個 2 GB 的信任對象」。這個說法不太精確。

**Mathlib 不會讓我們多信任什麼**

- Mathlib 的證明一樣全部由 Lean 核心檢查，用到的公理只有 Lean 自己的三個：`propext`、`Classical.choice`、`Quot.sound`。
- `tools/lean/lean.sh check` 拒絕的是 `sorryAx`、`Lean.ofReduceBool` 和 `Lean.trustCompiler`，也就是沒證完的、和靠編譯器算出來的。Mathlib 兩種都不需要。
- 第三節的實測沒有用到 Mathlib，印出來的公理也正是這三個。

**真正的成本有兩種**

- **定義要被讀。** 如果定理的敘述裡出現 Mathlib 的定義，例如它的橢圓曲線點、它的 `ZMod`，審查的人就得相信那個定義寫對了。證明再多，也不會被額外信任；但敘述裡的定義會。
- **工程成本。**
  - 每個新的雲端 session 都要下載數 GB 的預編譯檔。現在的 `tools/lean/setup.sh` 是 580 MB。
  - 每個 import Mathlib 的檔案，檢查時間都會變長。
  - Lean 升級時，得跟著 Mathlib 的版本走。

  確切的下載量和時間還**沒有實測**。

**版本對得上，連得到**：

```
$ git ls-remote https://github.com/leanprover-community/mathlib4 refs/tags/v4.34.0
5ed2965256430c3649e86755f9576b54eca72435	refs/tags/v4.34.0
```

repo 的 Lean 是 4.34.0，Mathlib 有對應的 `v4.34.0` tag，這個環境也連得到它的 GitHub。

## 二、把 OP_CHECKSIG 的證明拆開看

驗章要算的是：u₁ = z·s⁻¹、u₂ = r·s⁻¹（mod n），R = u₁G + u₂Q，再檢查 R 的 x 座標 mod n 是否等於 r。BIP340 的流程類似，另外還要做帶標籤的 SHA-256，而 exp208 已經證明過 SHA-256 kernel。

在 RV32IM 上把它證完，大致有六層：

| 層次 | 內容 | Mathlib 幫多少 |
| --- | --- | --- |
| ① RV32 多精度運算 | 256 位元數字拆成 8 個 32 位元 limb，加、減、乘、模 p 化簡；要證明機器碼算出的 limb 等於 `Nat` 上的值 | **幾乎沒幫助**。這跟 exp208 SHA-256 是同一類證明，靠的是 `lean/Rv32` 既有的 `run_line`、`overlay`、`omega`。**這是工作量最大的一層** |
| ② 模反元素 | 用費馬小定理（x^(p−2)）或延伸 GCD 求倒數 | **有幫助**。Mathlib 的 `ZMod p` 只要知道 p 是質數，就是體，費馬小定理也是現成的。核心 Lean 的 `Fin n` 只是交換環，**沒有現成的「模 p 的體」**（見第三節） |
| ③ p 和 n 是質數 | secp256k1 的兩個 256 位元質數 | **有幫助但不是免費**。256 位元數字不能用試除法，要用 Lucas/Pratt 這類質數證書。Mathlib 有 Lucas 定理，證書還是要自己準備；核心 Lean 的大數運算夠快，驗算證書不需要 `native_decide` |
| ④ Jacobian 座標公式等於 affine 公式 | 實作用的座標換算和教科書定義的點加倍、點相加一致 | **核心 Lean 已經做得到**（第三節實測） |
| ⑤ 演算法層的等價 | Strauss–Shamir、視窗法、GLV 這類加速法，要用到群的結合律和交換律 | **幫助最大**。Mathlib 已經證明橢圓曲線的點構成交換群，結合律的證明出了名的難。如果實作就是規格的照抄版本，例如最樸素的 double-and-add，這一層就不需要 |
| ⑥ 跟 Bitcoin 一致 | 驗章結果和 Bitcoin Core（libsecp256k1）完全相同 | **完全沒幫助**。Mathlib 能證明「跟數學一致」，不能證明「跟 libsecp256k1 一致」。後者還是要靠 BIP340 測試向量、Wycheproof 這類差分測試，就像 repo 用 `hashlib` 對照 SHA-256 的規格 |

還有一點對證明有利：**CHECKSIG 是驗章，用到的資料全部公開**。所以 exp207（`lean/Rv32/Ct.lean`）那種常數時間的要求不適用，證明可以少一個維度。之後如果要在板子上簽章，常數時間的要求才會回來。

## 三、實測：核心 Lean 4.34.0 做得到什麼

### 不用 Mathlib，`grind` 能證 Jacobian 加倍公式

這個檔案在 scratchpad 裡，用 repo 的 `tools/lean/lean-4.34.0-linux/bin/lean` 直接檢查，沒有任何 import：

```lean
-- secp256k1, y² = x³ + 7: Jacobian doubling against the affine formula,
-- in core Lean 4.34.0 with no Mathlib, by `grind` alone.
--   Jacobian (a = 0): S = 4XY², M = 3X², X3 = M² − 2S, Y3 = M(S − X3) − 8Y⁴, Z3 = 2YZ
--   affine:           x = X/Z², y = Y/Z³, λ = 3x²/(2y), x3 = λ² − 2x

-- X3 multiplied out, in any commutative ring.
theorem dbl_x {α} [Lean.Grind.CommRing α] (X Y : α) :
    let S := 4*X*Y^2; let M := 3*X^2; let X3 := M^2 - 2*S
    X3 = 9*X^4 - 8*X*Y^2 := by
  intro S M X3; grind

-- Y3 multiplied out, in any commutative ring.
theorem dbl_y {α} [Lean.Grind.CommRing α] (X Y : α) :
    let S := 4*X*Y^2; let M := 3*X^2; let X3 := M^2 - 2*S; let Y3 := M*(S - X3) - 8*Y^4
    Y3 = 3*X^2*(12*X*Y^2 - 9*X^4) - 8*Y^4 := by
  intro S M X3 Y3; grind

-- With division, in any field: the affine x of the doubled point is X3 / Z3².
theorem dbl_affine {α} [Lean.Grind.Field α] (X Y Z : α) (hZ : Z ≠ 0) (hY : Y ≠ 0) :
    let x := X / Z^2; let y := Y / Z^3
    let l := 3*x^2 / (2*y); let x3 := l^2 - 2*x
    let S := 4*X*Y^2; let M := 3*X^2; let X3 := M^2 - 2*S; let Z3 := 2*Y*Z
    (2:α) ≠ 0 → x3 = X3 / Z3^2 := by
  intro x y l x3 S M X3 Z3 h2; grind

#print axioms dbl_x
#print axioms dbl_y
#print axioms dbl_affine
```

輸出，三個都通過，只用到三個標準公理：

```
$ lean --version
Lean (version 4.34.0, x86_64-unknown-linux-gnu, commit 293d5d0c0c3f3dded4688b3ccd6a33939ac5102b, Release)
$ lean probe.lean
'dbl_x' depends on axioms: [propext, Classical.choice, Quot.sound]
'dbl_y' depends on axioms: [propext, Classical.choice, Quot.sound]
'dbl_affine' depends on axioms: [propext, Classical.choice, Quot.sound]
exit=0
```

這只測了加倍的 x 座標。點相加，以及完整的 y 座標，還沒試。但這種「清掉分母後的多項式恆等式」正是 `grind` 的交換環求解器擅長的題型，所以第④層大概不需要 Mathlib。

### 缺的是「模 p 的體」

核心 Lean 4.34.0 的 `grind` 有 `Fin n` 的交換環實例，但整個 `Init` 裡唯一的 `Field` 實例是有理數：

```
$ grep -rn "^instance.*: Field \|^instance.*CommRing (Fin" Init
Init/GrindInstances/Ring/Rat.lean:18:instance : Field Rat where
Init/GrindInstances/Ring/Fin.lean:111:instance (n : Nat) [NeZero n] : CommRing (Fin n) where
```

所以上面那個在「任意體」上成立的定理，要套到 secp256k1 的模 p 運算上，得先替 `Fin p` 做一個 `Field` 實例。這需要兩樣東西：倒數存在（費馬小定理或延伸 GCD），以及 p 是質數。這正是第②、③層，也是 Mathlib 第一個真正省力的地方。

不用 Mathlib，自己寫的話：費馬小定理約幾百行，質數證書要另外寫一套驗算。數量級是一個實驗，不是一個專案。這是估計，沒有實測。

## 四、建議

1. **現在不引入。** 往 CHECKSIG 走的第一步一定是第①層：模 p 的加法和乘法在 RV32 上的證明。Mathlib 在那裡幫不上忙。照 [what-belongs-to-an-experiment.md](./what-belongs-to-an-experiment.md) 的原則，不要在還沒有實際用到它的證明之前，就先把東西放進來。
2. **規格先照抄演算法。** 把規格寫成和實作同樣步驟的 double-and-add，第⑤層就不需要群定理。規格是否等於 Bitcoin 的驗章，用測試向量做差分測試。
3. **出現以下任一情況，就引入 Mathlib：**
   - 第②、③層自己寫的成本，明顯高於引入的工程成本；
   - 想用 Strauss–Shamir、視窗法或 GLV 加速，必須用到群律；
   - 之後的密碼學題目需要大量代數結構，例如配對、格密碼、多項式承諾，那時自己寫的成本會一路累加。
4. **引入時的做法：**
   - 固定在 `v4.34.0`，跟 `tools/lean` 的 Lean 版本一起升級；
   - 放在**獨立的 Lean 套件**，`lean/Rv32` 不依賴它；
   - RV32 那層的定理把需要的數學事實當成**假設**，例如「Jacobian 加倍等於 affine 加倍」或「`Fin p` 是體」，由 Mathlib 那邊證明後，在最上層的一個檔案組合起來。這樣核心函式庫維持現狀，Mathlib 只出現在真正需要它的那幾個定理裡；
   - 先實測下載量、磁碟用量和 `check.sh` 的時間，寫進 setup 和 [tool-needs.md](./tool-needs.md)，再開始用。

## 五、如果下一步是 CHECKSIG

建議的第一個實驗：**secp256k1 的模 p 加法與乘法，在 RV32IM 上的證明。** 它是整件事最大的一塊，完全不需要 Mathlib，而且之後不管走 ECDSA 還是 Schnorr、引不引入 Mathlib，都用得到。

照 [experiments/README.md](../experiments/README.md#how-this-repository-is-developed) 的流程，開工前還是要先讀前例、再提問。
