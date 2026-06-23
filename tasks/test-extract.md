# テスト項目抽出台帳: トークンバケット rate limiter(lazy 補充)

対象: `Limiter`(`Allow() bool`, `AllowN(n int) bool`, コンストラクタ `New(rate, capacity, clock)`)
走査アンカー: 不変条件(INV1-4)+ 関数シグネチャ + 境界 + 並行

各 ID は「テストすべき振る舞い」1つ。手法を割り当て、テスト名へ落とし終えたら「設計済」を `[x]`。
実行ゲート(緑、型、flaky なし、-race)を通ったら「緑確認済」を `[x]`。

## 用語定義(抽出より先に埋める)

| 用語 | 定義(曖昧さを残さない) | この定義が生む境界と異常系 |
|------|--------------------------|----------------------------|
| rate | トークン/秒。補充速度。`> 0` を事前条件とする | rate=0(補充されない)/ 負(不正、弾く) |
| capacity | バケット上限=バースト許容量。`> 0` を事前条件 | capacity=0(常に失敗)/ 負(不正、弾く) |
| tokens | 現在の利用可能トークン(float64)。常に `0 <= tokens <= capacity` | 0(空)/ capacity(満タン)/ 端数 |
| lazy 補充 | acquire 時に `dt=now-last` ぶんを `min(cap, tokens+rate*dt)` で補充。タイマー無し | dt=0(補充なし)/ dt 巨大(capへclamp)/ dt<0(時刻巻き戻り→0クランプ) |
| clock | 時刻源 `func() time.Time`。本番は monotonic、テストは fake で仮想時刻を進める | 巻き戻り(monotonic前提だが防御) |
| n(AllowN) | 消費要求量。任意の int を受ける | 0(常に成功・不変)/ capacity 超(満タンでも失敗)/ 負(同値:n<=0 扱い) |
| acquire | 補充→clamp→last更新→消費判定 を mutex で相互排他した1単位 | 並行時の逐次化 |

## 台帳

### 事前条件・コンストラクタ(異常系)
- [x] T-001 <同値:rate> 「rate <= 0 で New するとパニック/エラー(不正を弾く)」
      → 手法: 同値分割 (blackbox-systematic.md) / テスト名: TestNew_不正なrateを弾く
- [x] T-002 <同値:capacity> 「capacity <= 0 で New するとパニック/エラー」
      → 手法: 同値分割 (blackbox-systematic.md) / テスト名: TestNew_不正なcapacityを弾く
- [x] T-003 <正常> 「New 直後はバケット満タン(tokens=capacity)」
      → 手法: 同値分割 (blackbox-systematic.md) / テスト名: TestNew_初期は満タン

### 境界値(INV1, INV3 の境界)
- [x] T-010 <境界:tokens=0> 「tokens=0 のとき Allow() → false、tokens 据え置き」
      → 手法: 境界値 (blackbox-systematic.md) / テスト名: TestAllow_残量ゼロで拒否
- [x] T-011 <境界:tokens=capacity> 「満タンで AllowN(capacity) → true、tokens=0 に」
      → 手法: 境界値 (blackbox-systematic.md) / テスト名: TestAllowN_満タンで全量取得
- [x] T-012 <境界:capacity+1> 「満タンで AllowN(capacity+1) → false、据え置き」
      → 手法: 境界値 (blackbox-systematic.md) / テスト名: TestAllowN_容量超は常に失敗
- [x] T-013 <境界:補充ちょうど> 「rate=1,cap=1,空から1秒ちょうど経過で Allow() → true(補充境界)」
      → 手法: 境界値 (blackbox-systematic.md) / テスト名: TestAllow_経過時間ちょうどで補充
- [x] T-014 <境界:補充直前> 「同条件で 0.999 秒(1秒未満)では Allow() → false(補充足りず)」
      → 手法: 境界値 (blackbox-systematic.md) / テスト名: TestAllow_補充境界の直前は拒否
- [x] T-015 <境界:cap clamp> 「長時間経過しても補充は capacity で頭打ち(溢れない)」
      → 手法: 境界値 (blackbox-systematic.md) / テスト名: TestAllow_長時間経過でも容量超えない

### 同値分割(n のクラス)
- [x] T-020 <同値:n=0> 「AllowN(0) は常に成功し tokens 不変」
      → 手法: 同値分割 (blackbox-systematic.md) / テスト名: TestAllowN_ゼロ要求は常に成功で不変
- [x] T-021 <同値:n<0> 「AllowN(負) の扱い(n<=0 と同値で常に成功・不変)」
      → 手法: 同値分割 (blackbox-systematic.md) / テスト名: TestAllowN_負の要求は不変で成功
- [x] T-022 <正常> 「Allow() は AllowN(1) と等価」
      → 手法: 同値分割 (blackbox-systematic.md) / テスト名: TestAllow_は1トークン消費

### 時間関連(clock 注入で決定的に)
- [x] T-030 <境界:dt=0> 「同一時刻で連続 acquire しても補充されない」
      → 手法: 境界値 (blackbox-systematic.md) / テスト名: TestAllow_同一時刻では補充なし
- [x] T-031 <異常:巻き戻り> 「clock が巻き戻っても(dt<0)負補充せず据え置き」
      → 手法: エラー推測 (blackbox-experience.md) / テスト名: TestAllow_時刻巻き戻りで負補充しない

### property based(PROP↔INV 橋渡し)
- [x] T-040 <不変:INV1> 「任意の操作列でも常に 0 <= tokens <= capacity」(PROP1↔INV1)
      → 手法: PBT (modern-generative.md) / テスト名: TestProperty_残量は常に範囲内
- [x] T-041 <不変:INV3> 「AllowN(n) 成功 ⇔ 直前(補充後)tokens >= n、成功時ちょうど n 減」(PROP3↔INV3)
      → 手法: PBT (modern-generative.md) / テスト名: TestProperty_成功条件と消費量
- [x] T-042 <不変:PROP2> 「長時間平均の許可レート <= 設定 rate(バースト後はならす)」(PROP2)
      → 手法: PBT/メタモルフィック (modern-generative.md) / テスト名: TestProperty_長期平均レートは設定以下

### 並行(INV4 橋渡し、-race)
- [x] T-050 <不変:INV4> 「N goroutine が同時 Allow() → 許可総数が初期 tokens(+補充)を超えない」(↔INV4)
      → 手法: 並行テスト (nonfunctional-process.md) / テスト名: TestConcurrent_許可総数は利用可能量以下
- [x] T-051 <非機能> 「-race で competing acquire を回しデータ競合なし」
      → 手法: 並行/race detector (nonfunctional-process.md) / テスト名: TestConcurrent_レース検出(-race実行)

### 正常系活性(M6 退行ガード: 足りているのに失敗しない)
- [x] T-060 <正常> 「tokens >= n のとき AllowN(n) は理由なく失敗しない」
      → 手法: 状態遷移/正常系 (blackbox-systematic.md) / テスト名: TestAllowN_供給十分なら成功する

## トレーサビリティマトリクス(消し込み台帳)

| 振る舞い(T番号) | 種別 | 手法(reference) | テスト名 | 設計済 | 緑確認済 | mutation |
|---|---|---|---|---|---|---|
| T-001 | 異常 | 同値分割 | TestNew_不正なrateを弾く | [x] | [x] | - |
| T-002 | 異常 | 同値分割 | TestNew_不正なcapacityを弾く | [x] | [x] | - |
| T-003 | 正常 | 同値分割 | TestNew_初期は満タン | [x] | [x] | - |
| T-010 | 境界 | 境界値 | TestAllow_残量ゼロで拒否 | [x] | [x] | - |
| T-011 | 境界 | 境界値 | TestAllowN_満タンで全量取得 | [x] | [x] | - |
| T-012 | 境界 | 境界値 | TestAllowN_容量超は常に失敗 | [x] | [x] | - |
| T-013 | 境界 | 境界値 | TestAllow_経過時間ちょうどで補充 | [x] | [x] | INV3 |
| T-014 | 境界 | 境界値 | TestAllow_補充境界の直前は拒否 | [x] | [x] | - |
| T-015 | 境界 | 境界値 | TestAllow_長時間経過でも容量超えない | [x] | [x] | INV1 |
| T-020 | 同値 | 同値分割 | TestAllowN_ゼロ要求は常に成功で不変 | [x] | [x] | - |
| T-021 | 同値 | 同値分割 | TestAllowN_負の要求は不変で成功 | [x] | [x] | - |
| T-022 | 正常 | 同値分割 | TestAllow_は1トークン消費 | [x] | [x] | - |
| T-030 | 境界 | 境界値 | TestAllow_同一時刻では補充なし | [x] | [x] | - |
| T-031 | 異常 | エラー推測 | TestAllow_時刻巻き戻りで負補充しない | [x] | [x] | INV1 |
| T-040 | 不変 | PBT | TestProperty_残量は常に範囲内 | [x] | [x] | INV1 |
| T-041 | 不変 | PBT | TestProperty_成功条件と消費量 | [x] | [x] | INV3 |
| T-042 | 不変 | PBT | TestProperty_長期平均レートは設定以下 | [x] | [x] | - |
| T-050 | 不変 | 並行 | TestConcurrent_許可総数は利用可能量以下 | [x] | [x] | INV4 |
| T-051 | 非機能 | race | TestConcurrent_レース検出 | [x] | [x] | INV4 |
| T-060 | 正常 | 状態遷移 | TestAllowN_供給十分なら成功する | [x] | [x] | - |
