---- MODULE TokenBucket ----
EXTENDS Integers, FiniteSets

(***************************************************************************)
(* lazy 補充トークンバケット rate limiter の設計モデル。                      *)
(*                                                                         *)
(* 離散化: 時刻はティック整数。tokens/capacity/rate/dt は整数スケーリング。   *)
(* rate は「1ティックあたり整数 rate トークン補充」。refill = rate*dt は整数。 *)
(* clamp は整数 min なので近似誤差なし(float の丸めは実装側の注意点)。       *)
(*                                                                         *)
(* 並行: 複数プロセスが acquire を試みる。mutex 1 本(lock 変数)で acquire   *)
(* 全体を相互排他。各プロセスは pc で「待機/補充済み/完了」を持つ。            *)
(* 要求トークン数 n は Enter 時に 0..Capacity+1 から非決定的に選ぶ            *)
(* (n=0/1/Capacity/Capacity+1 の境界を網羅探索に含めるため)。               *)
(* タイマー goroutine は無い(tokens は acquire の補充以外で変わらない)。      *)
(***************************************************************************)

CONSTANTS
    Procs,        \* プロセス集合(並行 acquire するアクター)
    NoProc,       \* lock 空きを表す番兵(Procs に属さない値)
    Capacity,     \* バケット上限(整数スケール)
    Rate,         \* 1 ティックあたり補充トークン(整数, >0)
    MaxTime        \* 検査する最大ティック(状態空間有限化)

ASSUME Capacity > 0
ASSUME Rate > 0
ASSUME MaxTime \in Nat
ASSUME NoProc \notin Procs

VARIABLES
    tokens,    \* 現在の利用可能トークン(整数, 0..Capacity)
    last,      \* 最後に補充計算した時刻
    t,         \* グローバル時刻(単調増加ティック)
    lock,      \* mutex 保持者。NoProc なら空き
    pc,        \* プロセス -> {"idle","held","done"}
    req,       \* プロセス -> このラウンドで要求するトークン数 n
    granted,   \* これまで成功 acquire で消費した総量(保存則検査用)
    refilled   \* これまで補充で増えた総量(保存則検査用)

vars == <<tokens, last, t, lock, pc, req, granted, refilled>>

Min(a, b) == IF a < b THEN a ELSE b

\* TypeOK は「型(変数が値を持つこと)」だけを縛り、tokens の範囲 0..Capacity は
\* あえて含めない。範囲は Inv1 の管轄にして、clamp 除去等の変異が Inv1 で kill
\* されることを oracle で示せるようにする(TypeOK で先に落とすと Inv1 の有効性が隠れる)。
TypeOK ==
    /\ tokens \in Int
    /\ last \in 0..MaxTime
    /\ t \in 0..MaxTime
    /\ lock \in Procs \cup {NoProc}
    /\ pc \in [Procs -> {"idle", "held", "done"}]
    /\ req \in [Procs -> 0..(Capacity + 1)]
    /\ granted \in Int
    /\ refilled \in Int

Init ==
    /\ tokens = Capacity        \* 満タン開始(バースト許容)
    /\ last = 0
    /\ t = 0
    /\ lock = NoProc
    /\ pc = [p \in Procs |-> "idle"]
    /\ req = [p \in Procs |-> 0]
    /\ granted = 0
    /\ refilled = 0

(* S-003: 時間を 1 ティック進める。lock が空きのときだけ進ませる         *)
(* (acquire 区間の途中で時間が動くと last/now の対応が崩れるため。       *)
(*  実装では acquire 内で now を 1 回だけ読むことに対応)。               *)
Tick ==
    /\ t < MaxTime
    /\ lock = NoProc
    /\ t' = t + 1
    /\ UNCHANGED <<tokens, last, lock, pc, req, granted, refilled>>

(* S-006 + S-003: lock 取得して acquire 開始 + 補充。                  *)
(* dt = t - last >= 0(t 単調なので S-014 の負補充は構造上起きない)。   *)
(* refill = Rate * dt、clamp は min。last := t。要求 n を確定。        *)
Enter(p) ==
    /\ pc[p] = "idle"
    /\ lock = NoProc
    /\ \E n \in 0..(Capacity + 1) :
        /\ req' = [req EXCEPT ![p] = n]
    /\ LET dt == t - last
           refill == Rate * dt
           newTokens == Min(Capacity, tokens + refill)
       IN  /\ tokens' = newTokens
           /\ refilled' = refilled + (newTokens - tokens)
           /\ last' = t
    /\ lock' = p
    /\ pc' = [pc EXCEPT ![p] = "held"]
    /\ UNCHANGED <<t, granted>>

(* S-004 / S-012: 補充後 tokens >= req[p] なら消費して成功。n=0 も成功。 *)
Succeed(p) ==
    /\ pc[p] = "held"
    /\ lock = p
    /\ tokens >= req[p]
    /\ tokens' = tokens - req[p]
    /\ granted' = granted + req[p]
    /\ lock' = NoProc
    /\ pc' = [pc EXCEPT ![p] = "done"]
    /\ UNCHANGED <<last, t, req, refilled>>

(* S-005 / S-013: 補充後 tokens < req[p] なら据え置き失敗(消費なし)。  *)
Fail(p) ==
    /\ pc[p] = "held"
    /\ lock = p
    /\ tokens < req[p]
    /\ lock' = NoProc
    /\ pc' = [pc EXCEPT ![p] = "done"]
    /\ UNCHANGED <<tokens, last, t, req, granted, refilled>>

(* done のプロセスを idle に戻し、繰り返し acquire を可能にする。       *)
(* tokens/last/t/granted/refilled は触らない(純粋に制御フローの巻き戻し)。*)
Reset(p) ==
    /\ pc[p] = "done"
    /\ pc' = [pc EXCEPT ![p] = "idle"]
    /\ UNCHANGED <<tokens, last, t, lock, req, granted, refilled>>

Next ==
    \/ Tick
    \/ \E p \in Procs : Enter(p)
    \/ \E p \in Procs : Succeed(p)
    \/ \E p \in Procs : Fail(p)
    \/ \E p \in Procs : Reset(p)

Spec == Init /\ [][Next]_vars /\ WF_vars(Tick)
            /\ \A p \in Procs : WF_vars(Enter(p) \/ Succeed(p) \/ Fail(p))

(***************************************************************************)
(* 不変条件                                                                *)
(***************************************************************************)

\* INV1: 0 <= tokens <= capacity
Inv1 == tokens >= 0 /\ tokens <= Capacity

\* INV2(補充単調): 補充で増えた総量は非負。t 単調 + clamp で refill >= 0。
Inv2 == refilled >= 0

\* INV3(保存則): tokens = Capacity + refilled - granted。
\* 成功時に tokens が n 減り granted が n 増える / 補充で tokens と refilled が同量増える、
\* を一本の保存則で締める。失敗時は granted/refilled/tokens とも不変。
Inv3 == tokens = Capacity + refilled - granted

\* INV4(過剰許可なし): 消費総量は供給総量(初期 + 補充)を超えない。
Inv4 == granted <= Capacity + refilled

\* mutex 相互排他: 同時に held なのは高々 1 プロセス。
MutexInv == \A p1, p2 \in Procs :
    (pc[p1] = "held" /\ pc[p2] = "held") => (p1 = p2)

\* lock と pc の整合: held なら自分が lock 保持者。
LockHeldConsistent == \A p \in Procs : (pc[p] = "held") => (lock = p)

(***************************************************************************)
(* 活性(LIVE1, 任意)                                                      *)
(* 別 cfg で検査する。消費しないなら時間経過で tokens は Capacity へ回復。   *)
(***************************************************************************)
Liveness == <>(tokens = Capacity)

====
