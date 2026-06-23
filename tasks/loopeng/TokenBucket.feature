# lazy 補充トークンバケット rate limiter の受け入れ仕様。
# TLA+ で安全性(範囲・保存則・相互排他)を網羅検査した結果から起こした。
# 時刻・トークンは実装の単位(トークン/秒, 経過秒)で書く。
# 補充は acquire 時のみ: 経過時間ぶんを足して capacity でクランプ、その後に消費判定。

Feature: トークンバケット rate limiter (lazy 補充)

  Background:
    Given レート rate = 1 トークン/秒
    And 容量 capacity = 2 トークン
    And クロックは単調増加で acquire 内では now を1回だけ読む

  # --- 範囲の安全性 (INV1) ---

  Scenario: 補充は capacity を超えて溢れない
    Given tokens = 1 かつ last = 0 秒
    When now = 10 秒で acquire(0) する
    Then 補充後 tokens は 2 (= capacity) でクランプされる
    And tokens が capacity を超えない

  Scenario: 過剰消費で tokens が負にならない
    Given tokens = 0 かつ last = now
    When acquire(1) する
    Then 失敗する
    And tokens は 0 のまま (負にならない)

  # --- 境界: tokens = 0 ---

  Scenario: tokens = 0 では Allow は失敗する
    Given tokens = 0 かつ経過時間ゼロ
    When acquire(1) する
    Then 失敗する
    And tokens は 0 のまま

  # --- 境界: tokens = capacity ---

  Scenario: tokens = capacity なら capacity ぶん一括取得できる
    Given tokens = 2 (= capacity) かつ経過時間ゼロ
    When acquire(2) する
    Then 成功する
    And tokens は 0 になる

  Scenario: capacity を超える要求は満タンでも失敗する
    Given tokens = 2 (= capacity) かつ経過時間ゼロ
    When acquire(3) する
    Then 失敗する
    And tokens は 2 のまま (消費しない)

  # --- 境界: 経過時間ちょうどで1トークン補充 ---

  Scenario: 経過1秒ちょうどで rate ぶん1トークン補充される
    Given tokens = 0 かつ last = 0 秒
    When now = 1 秒で acquire(1) する
    Then 補充で tokens が 1 になり
    And acquire(1) は成功して tokens は 0 になる

  Scenario: 経過が足りなければ補充は1トークン未満で失敗する
    Given tokens = 0 かつ last = 0 秒
    When now = 0 秒 (経過ゼロ) で acquire(1) する
    Then 補充は 0 で tokens は 0 のまま
    And acquire(1) は失敗する

  # --- 消費の事後条件 (INV3 保存則) ---

  Scenario: 成功時はちょうど n だけ減る
    Given tokens = 2 かつ経過時間ゼロ
    When acquire(1) する
    Then 成功する
    And tokens は 1 になる (= 2 - 1)

  Scenario: 失敗時は tokens を据え置く
    Given tokens = 1 かつ経過時間ゼロ
    When acquire(2) する
    Then 失敗する
    And tokens は 1 のまま

  Scenario: n = 0 は常に成功し tokens を変えない
    Given tokens = 0 かつ経過時間ゼロ
    When acquire(0) する
    Then 成功する
    And tokens は 0 のまま

  # --- 並行で総許可量が供給量を超えない (INV4, mutex 逐次化) ---

  Scenario: 2プロセスの並行 acquire が初期 tokens を超えて許可しない
    Given tokens = 2 (= capacity) かつ経過時間ゼロ
    And プロセス A が acquire(2) を、プロセス B が acquire(1) を同時に試みる
    When mutex により acquire が逐次化される
    Then A と B に許可された合計は 2 トークンを超えない
    And 片方だけが成功する (先に lock を取った側が 2 を取り、もう片方は失敗)

  Scenario: 並行でも合計消費は供給量 (初期 + 補充) を超えない
    Given tokens = 1 かつ rate ぶんの補充が1トークン入る経過
    And 3プロセスがそれぞれ acquire(1) を同時に試みる
    When mutex により逐次化される
    Then 成功した acquire の合計は 2 トークン (初期1 + 補充1) を超えない

  # --- 回復 (LIVE1, 到達性) ---

  Scenario: 消費後に時間が経てば tokens は capacity まで回復する
    Given tokens = 0 かつ last = now
    When 誰も消費せずに capacity / rate 秒 (= 2 秒) 経過してから acquire(0) する
    Then 補充で tokens は 2 (= capacity) まで回復する

  # --- 正常系の活性: 成功すべき要求は失敗のまま放置されない ---
  # (安全性検査では捕まらない「成功できるのに失敗扱いする」退行を締める)

  Scenario: 供給があるなら acquire は成功する (理由なく失敗しない)
    Given tokens = 2 (= capacity) かつ経過時間ゼロ
    When acquire(1) する
    Then 成功する
    And これは「足りているのに失敗を返す」退行が無いことを保証する
