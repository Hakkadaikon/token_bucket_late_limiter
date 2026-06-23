---- MODULE Live ----
EXTENDS TokenBucket
\* tokens を一度 0 にしてから Capacity へ戻る経路の存在を、反例として炙り出す。
\* 「0 を経験した後に Capacity へ戻ることは無い」と仮定 → 反例が出れば回復経路あり。
NeverRecovered == ~(tokens = Capacity /\ refilled > 0)
====
