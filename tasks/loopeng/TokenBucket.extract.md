# 抽出台帳: lazy 補充トークンバケット rate limiter

元仕様: tasks/token-bucket-requirements.md および呼び出し元の自然言語要求(対象システム + 固めたい不変条件)。
走査アンカー: 自然言語要求の各箇条書き(API / acquire 手順 / 並行 / INV1-4 / LIVE1)を1単位とする。

## 離散化方針(float を扱えない TLC 用の近似。実装への注意点として保全)

- 時刻はティック単位の整数。グローバル時刻 t を持ち、プロセスはその時点の t を now として acquire する。
- tokens / capacity / rate / dt はすべて整数にスケーリングする。
  rate は「1ティックあたり整数 rate トークンを補充」とみなす(rate トークン/秒 × 1ティック)。
  補充量 refill = rate * dt は整数演算で厳密。
- clamp: tokens_after_refill = min(capacity, tokens + rate*dt)。整数 min なので近似誤差なし。
- 注意(実装側): 本番は float64 / fixed-point。lazy 補充計算の順序(まず refill+clamp、その後に消費判定)と
  clamp 位置(refill 直後に capacity で頭打ち)をモデルどおりに保つ。float の丸めで tokens が
  わずかに capacity を超える/負になる経路を実装テストで締める(モデルは整数なのでそこは別途)。

## 台帳

- [x] S-001 「状態は tokens(0..capacity)と last(最後に補充計算した時刻)の2つ」
      → The system SHALL maintain tokens in 0..capacity and last as the time of the most recent refill computation. (ubiquitous / 状態定義)
- [x] S-002 「rate > 0, capacity > 0 のパラメータ」
      → The system SHALL be configured with rate > 0 and capacity > 0. (ubiquitous / 事前条件)
- [x] S-003 「acquire 時に dt = now - last ぶん補充: tokens = min(capacity, tokens + rate*dt), last = now」
      → WHEN a process begins acquire at time now the system SHALL set tokens to min(capacity, tokens + rate*(now-last)) and set last to now. (event / 補充)
- [x] S-004 「補充後 tokens >= n なら成功し tokens -= n」
      → WHEN acquire(n) finds tokens >= n after refill the system SHALL decrement tokens by n and report success. (event / 成功)
- [x] S-005 「補充後 tokens < n なら失敗し据え置き」
      → IF acquire(n) finds tokens < n after refill THEN the system SHALL leave tokens unchanged and report failure. (unwanted / 失敗)
- [x] S-006 「mutex 1本で acquire 全体を相互排他。タイマー goroutine 無し」
      → WHILE one process holds the lock the system SHALL NOT let another process enter acquire. (state / 相互排他)
      → The system SHALL NOT change tokens outside of an acquire (no background timer). (ubiquitous / 補充は acquire のみ)
- [x] S-007 INV1 「常に 0 <= tokens <= capacity」
      → The system SHALL never let tokens fall below 0 or exceed capacity. (ubiquitous / 安全性 → Inv)
- [x] S-008 INV2 「補充は単調 — 時間が進む限り補充ぶんは非負、tokens は acquire 以外で減らない」
      → WHILE time does not move backward the refill amount SHALL be non-negative. (state)
      → The system SHALL NOT decrease tokens except by a successful acquire consumption. (ubiquitous → Inv 化: 非 acquire 遷移で tokens' >= tokens)
- [x] S-009 INV3 「acquire(n) 成功は補充後 tokens >= n のときだけ。成功時 tokens'=tokens-n、失敗時 tokens'=tokens」
      → WHEN acquire(n) succeeds the system SHALL have had post-refill tokens >= n and SHALL set tokens' = tokens - n. (event → Inv)
      → IF acquire(n) does not succeed THEN tokens' = tokens (post-refill 据え置き、消費なし). (unwanted → Inv)
- [x] S-010 INV4 「並行 acquire で同一瞬間に許可された総量が利用可能 tokens を超えない(mutex 逐次化)」
      → WHILE multiple processes acquire concurrently the total amount granted SHALL NOT exceed the tokens that were available, because acquire is serialized by the lock. (state → Inv: グローバル保存則)
- [x] S-011 LIVE1(任意)「rate > 0 なら十分待てば tokens は capacity まで回復」
      → WHERE no acquire consumes, IF time keeps advancing THEN eventually tokens = capacity. (optional / liveness → temporal)

## unwanted の系統生成(各 event に不正入力を問う)

- [x] S-012 acquire(n) の n が 0 → 成功扱い(0 消費、tokens 不変)。境界。
      → WHEN acquire(0) the system SHALL succeed without changing tokens. (event)
- [x] S-013 acquire(n) の n が capacity 超 → 補充が満タンでも常に失敗。
      → IF n > capacity THEN acquire(n) SHALL always fail. (unwanted)
- [x] S-014 now < last(時間巻き戻り)→ dt < 0。lazy 補充が負の補充をしないこと。
      → IF now < last THEN the system SHALL NOT apply a negative refill (clamp dt at 0 / treat as no refill). (unwanted)
      注: 本モデルではグローバル時刻 t は単調増加とし、各プロセスの now = t を使うので now >= last は構造的に保証。
      ただし実装では単調クロックを使う注意点として残す(壁時計だと巻き戻りあり)。

## トレーサビリティ・マトリクス

| 仕様条項 | 要件(EARS) | 形式手法(TLA+) | テスト(Gherkin/TDD) |
|---|---|---|---|
| S-001 状態 | tokens∈0..cap, last∈Time | VARIABLES tokens,last,lock,pc / TypeOK | - |
| S-002 param | rate>0, cap>0 | CONSTANT 制約(ASSUME) | tokens=0→Allow false |
| S-003 補充 | refill+clamp | RefillAndTry の min 計算 | 経過時間ちょうどで1補充の境界 |
| S-004 成功 | tokens-=n | TrySucceed disjunct | AllowN(cap)=true |
| S-005 失敗 | 据え置き | TryFail disjunct | tokens=0→false |
| S-006 mutex | 相互排他 | lock 変数 + pc, MutexInv | 並行で総許可<=初期tokens |
| S-007 INV1 | 0<=tokens<=cap | Inv1 | PROP1 |
| S-008 INV2 | 非acquireで減らない | Inv2(補充単調) | - |
| S-009 INV3 | 成功⇔post tokens>=n | Inv3 | PROP3 |
| S-010 INV4 | 総許可保存 | Inv4(granted+tokens の保存) | 並行シナリオ |
| S-011 LIVE1 | 回復 | Liveness(任意) | - |
| S-012 n=0 | 0消費成功 | TrySucceed(n=0 含む) | AllowN(0)=true境界 |
| S-013 n>cap | 常に失敗 | TryFail | AllowN(cap+1)=false |
| S-014 巻戻り | 負補充なし | t 単調 + dt>=0 | 単調クロック注意 |
