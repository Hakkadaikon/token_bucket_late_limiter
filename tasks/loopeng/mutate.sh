#!/usr/bin/env bash
# mutation oracle: spec に意味のある変異を注入し、各 INV が kill するか確認。
# killed = TLC がエラー(invariant 違反 or trace) を出す。survivor = No error。
# 各変異で原本と diff が非空であること(変異が当たったこと)を必ず確認する。
set -u
cd "$(dirname "$0")"
export _JAVA_OPTIONS="-Djava.io.tmpdir=${TMPDIR:-/tmp}/tla"
mkdir -p "${TMPDIR:-/tmp}/tla"

BASE=TokenBucket
WORK="${TMPDIR:-/tmp}/tbmut"
rm -rf "$WORK"; mkdir -p "$WORK"
cp "$BASE.cfg" "$WORK/M.cfg"
# cfg の INIT/NEXT/INVARIANT は module 名非依存なのでそのまま使える。
sed -i 's/^INIT Init/INIT Init/' "$WORK/M.cfg"

run_mut () {
    local name="$1" sedexpr="$2"
    cp "$BASE.tla" "$WORK/M.tla"
    # module 名を M に揃える
    sed -i 's/MODULE TokenBucket/MODULE M/' "$WORK/M.tla"
    cp "$WORK/M.tla" "$WORK/M.orig.tla"
    sed -i "$sedexpr" "$WORK/M.tla"
    if diff -q "$WORK/M.tla" "$WORK/M.orig.tla" >/dev/null; then
        echo "NOT-APPLIED  $name  (変異未適用 — 検査不成立)"
        return
    fi
    ( cd "$WORK" && timeout "${MUT_TIMEOUT:-30}" tlc -config M.cfg M.tla >tlc.out 2>&1 )
    local rc=$?
    if [ $rc -eq 124 ]; then
        echo "KILLED       $name  [timeout — 発散変異、打ち切り=kill 扱い]"
    elif grep -q "No error has been found" "$WORK/tlc.out"; then
        echo "SURVIVOR     $name"
    elif grep -qE "Invariant .* is violated|Error: Invariant" "$WORK/tlc.out"; then
        local inv=$(grep -oE "Invariant [A-Za-z0-9]+ is violated" "$WORK/tlc.out" | head -1)
        echo "KILLED       $name  [$inv]"
    else
        echo "KILLED       $name  (illegal-state/other error — 不正状態を踏んで停止)"
    fi
}

# baseline: 変異なしで No error を確認
run_mut "baseline-noop"          's/XXNOOPXX/XXNOOPXX/'
# M1: clamp 除去 — 補充が capacity を超えて溢れる
run_mut "M1-no-clamp"            's/newTokens == Min(Capacity, tokens + refill)/newTokens == tokens + refill/'
# M2: Succeed ガード緩和 — tokens 不足でも消費(過剰消費)
run_mut "M2-weak-guard"          's/tokens >= req\[p\]/tokens >= 0/'
# M3: Succeed 消費量ずらし — 保存則破壊(1多く消費)
run_mut "M3-consume-off"         's/tokens[\x27] = tokens - req\[p\]/tokens\x27 = tokens - req[p] - 1/'
# M4: Enter の lock ガードだけ除去(Tick のは残す)— 相互排他喪失。
#     idle 行の次行(Enter の lock = NoProc)を TRUE に。MutexInv が kill すべき。
run_mut "M4-no-mutex"            '/pc\[p\] = "idle"/{n; s/lock = NoProc/TRUE/}'
# M5: 過剰補充 — refill を 1 多く
run_mut "M5-over-refill"         's/refill == Rate \* dt/refill == Rate * dt + 1/'
# M6: Fail のガードを反転 — tokens 足りているのに失敗扱い(消費せず）。
#     これは「成功すべきを失敗にする」異常。安全性(Inv1-4)は壊さない可能性が高い
#     equivalent 候補。kill されなければ「活性/正常系の話で安全性 INV の管轄外」と分類する。
run_mut "M6-fail-guard-flip"     's/    \/\\ tokens < req\[p\]/    \/\\ tokens >= req[p]/'
# M7: granted を更新し忘れる(保存則の granted 側破壊)
run_mut "M7-no-granted"          's/granted[\x27] = granted + req\[p\]/granted\x27 = granted/'
