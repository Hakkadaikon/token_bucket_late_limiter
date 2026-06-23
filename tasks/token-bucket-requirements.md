# 題材: トークンバケット rate limiter

test-design と loop-engineering の両スキルを刺すための練習題材。
別セッションでこのファイルを起点に着手する。

## なぜこの題材か

| 層 | 刺さる理由 |
|---|---|
| loop-engineering (TLA+) | 残量という状態 × 時間補充 × 並行 acquire の安全性を網羅探索したい |
| test-design | 境界値・property・並行と、振る舞いが多く手法選定が効く |
| formal-verification (Lean) | 任意 → 余力なら「lazy 補充計算 = タイマー補充と等価」あたりを証明（YAGNI、無理に結線しない） |

## スコープ (ponytail: 最小)

- API: `Allow() bool`(1 トークン消費) と `AllowN(n int) bool`
- 補充方式: **lazy**(acquire 時に経過時間ぶんを補充計算)。タイマー goroutine は持たない
- 状態は2つだけ: `(tokens float64, last time.Time)`
- 並行安全: mutex 1本(ponytail: グローバルロック、スループット要れば後でシャーディング)
- 言語: Go 想定(`golang.org/x/time/rate` 相当を自作して検証対象にする)

設定パラメータ:
- `rate`(トークン/秒)
- `capacity`(バケット上限 = バースト許容量)

## 不変条件 / 安全性(loop-engineering で固める)

これらを TLA+ spec に落として TLC で網羅検査する。

- INV1: `0 <= tokens <= capacity`(補充で溢れない・過剰消費しない)
- INV2: 補充は単調 — 経過時間に比例、時間が戻らない限り tokens は acquire 以外で減らない
- INV3: acquire(n) が成功するのは `tokens >= n` のときだけ。成功時 `tokens' = tokens - n`
- INV4: 並行 acquire で「同一瞬間に許可された総量」が利用可能 tokens を超えない(mutex の相互排他)

活性(任意・余力あれば):
- LIVE1: rate > 0 なら、十分待てば tokens は capacity まで回復する

## 振る舞いの網羅抽出(test-design で洗い出す → テストリスト化)

カタログから手法を割り当てる。最低限のたたき:

### 境界値
- tokens = 0 のとき Allow() → false
- tokens = capacity のとき AllowN(capacity) → true、AllowN(capacity+1) → false
- 経過時間ちょうどで 1 トークン補充される境界

### 同値分割
- rate: 0 / 正 / (負・不正は弾く)
- capacity: 0 / 正
- AllowN の n: 0 / 1 / capacity 以下 / capacity 超

### property based
- PROP1: 任意の操作列でも常に `0 <= tokens <= capacity`(INV1 と1対1)
- PROP2: 長時間平均の許可レート <= 設定 rate(バースト後はならす)
- PROP3: AllowN(n) 成功 ⇔ 直前 tokens >= n(INV3 と1対1)

### 並行
- N goroutine が同時に Allow() → 許可された総数が初期 tokens を超えない(INV4 と1対1)
- race detector(`go test -race`)で competing acquire を回す

### 時間関連(テストしにくい点)
- time.Now() を直接呼ばず clock を注入(`func() time.Time` か interface)。
  テストで仮想時刻を進めて補充を決定的に検証する
- ponytail: 本番は time.Now、テストは fake clock。最小の seam だけ用意

## 検証三層の結線(workflow-guidelines の検証ゲート)

1. 状態遷移・並行あり → **TLA+**(INV1-4 を spec 化、TLC 検査、反例は Gherkin へ)
2. critical な数学的性質 → lazy 補充の正しさ。**Lean は任意**(過剰なら入れない)
3. 上2層の不変条件・述語を **TDD のテストリスト** に1対1で橋渡し(PROP1↔INV1 等)

## 成果物の置き場(rules 準拠)

- TLA+/EARS/Gherkin 中間生成物 → `tasks/loopeng/` 配下、git 管理外
- Lean 証明物(やるなら)→ `tasks/fv/` 配下、git 管理外
- 本体コード・テスト・コミットには管理番号(S-001/R-xx 等)や手法用語を漏らさない

## 進め方(別セッション)

1. plan mode に入る → 検証ゲート3問に答えてから着手
2. loop-engineering で EARS + 状態モデル → TLA+ spec → TLC → Gherkin
3. test-design で振る舞い網羅 → テストリスト(上の橋渡しを反映)
4. (やるなら)実装は TDD で Red → Green → Refactor
