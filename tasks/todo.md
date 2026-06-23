# todo: トークンバケット rate limiter

検証ゲート(済): 状態遷移+並行あり→TLA+ で固める / Lean は任意→YAGNIでスキップ / TDDへ橋渡し。

## フェーズ
- [x] loop-engineering: EARS + 状態モデル → TLA+ spec(INV1-4)→ TLC 検査 → Gherkin(tasks/loopeng/)
- [x] test-design: 振る舞い網羅 → テストリスト(PROP↔INV 橋渡し)(tasks/test-extract.md, 20項目)
- [x] TDD 実装: limiter 本体(lazy補充, mutex1本, clock注入)
- [x] テスト: 境界値/同値/property/並行(-race)20件全緑
- [x] go.mod / aqua 整備, go vet, go test -race 緑
- [x] コミット(micro-commit, 3コミット)

## レビュー欄

### 検証三層の結線
- TLA+(設計): INV1-4 を離散化 spec で網羅検査(2600 states, 反例なし)。mutation oracle で真の安全性 survivor 0。
  M6(過小許可)のみ survivor=安全性の管轄外 → 正常系テスト T-060 で締めた。
- Lean(証明): YAGNI でスキップ。lazy 補充は線形計算で自明、INV1/3/4 は TLA+ と property テストで担保済み。
- TDD(実装): 台帳 T-ID を1対1でテスト化。PROP1↔INV1(T-040), PROP3↔INV3(T-041), INV4↔並行(T-050)。

### 確定した実装上の勘所(モデル検査由来)
- clamp は補充直後(消費判定の前)。後段クランプは INV1 を破る。
- last 更新は消費の成否に依らず必ず行う(失敗時も補充は確定)。
- 時刻巻き戻り(dt<0)は 0 にクランプして負補充を防ぐ。
- mutex は補充計算〜消費判定を1クリティカルセクションに含める(分割すると INV4 が破れる)。

### 検証結果(自分で実行確認)
- go vet ./... : クリーン
- go test -race -count=1 ./... : 20/20 PASS
- go test -race -count=5 ./... : 安定(flaky なし)

### 残点・既知の限界
- float64 の丸め誤差はモデル管轄外。実装は math.Min clamp + property テストで範囲を締めている。
- 活性 LIVE1 は到達性のみ確認(完全な temporal 証明は YAGNI で見送り)。
- スループットが要るならグローバル mutex をシャーディングに(現状は要件どおり1本)。
- go コマンドは GOCACHE を書き込み可能パスへ(既定 ~/.cache/go-build が read-only な環境のため)。
