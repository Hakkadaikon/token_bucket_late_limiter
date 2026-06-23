package tokenbucket

import (
	"math"
	"math/rand"
	"sync"
	"testing"
	"testing/quick"
	"time"
)

// fakeClock は注入用の仮想時計。Advance で任意に時刻を進め(戻し)できる。
type fakeClock struct {
	mu sync.Mutex
	t  time.Time
}

func newFakeClock() *fakeClock { return &fakeClock{t: time.Unix(0, 0)} }

func (c *fakeClock) Now() time.Time {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.t
}

func (c *fakeClock) Advance(d time.Duration) {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.t = c.t.Add(d)
}

// readTokens は mutex 経由で現在の tokens を観測する(並行テストでも安全)。
func readTokens(l *Limiter) float64 {
	l.mu.Lock()
	defer l.mu.Unlock()
	return l.tokens
}

// T-001: rate <= 0 は不正設定として panic で弾く(0 と 負 の両方)
func TestNew_不正なrateを弾く(t *testing.T) {
	for _, rate := range []float64{0, -1} {
		func() {
			defer func() {
				if recover() == nil {
					t.Errorf("rate=%v: panic を期待したが起きなかった", rate)
				}
			}()
			New(rate, 1, nil)
		}()
	}
}

// T-002: capacity <= 0 は不正設定として panic で弾く(0 と 負 の両方)
func TestNew_不正なcapacityを弾く(t *testing.T) {
	for _, capacity := range []float64{0, -1} {
		func() {
			defer func() {
				if recover() == nil {
					t.Errorf("capacity=%v: panic を期待したが起きなかった", capacity)
				}
			}()
			New(1, capacity, nil)
		}()
	}
}

// T-003: New 直後はバケット満タン(capacity ぶんを一度に取れる)
func TestNew_初期は満タン(t *testing.T) {
	c := newFakeClock()
	l := New(1, 5, c.Now)
	if !l.AllowN(5) {
		t.Errorf("New 直後に AllowN(capacity) が失敗した。満タンでない")
	}
}

// T-010: tokens=0 のとき Allow() は false、残量据え置き
func TestAllow_残量ゼロで拒否(t *testing.T) {
	c := newFakeClock()
	l := New(1, 1, c.Now)
	if !l.Allow() {
		t.Fatalf("最初の Allow は成功するはず")
	}
	if l.Allow() {
		t.Errorf("残量ゼロなのに Allow が成功した")
	}
	if got := readTokens(l); got != 0 {
		t.Errorf("拒否後の tokens=%v, 期待 0(据え置き)", got)
	}
}

// T-011: 満タンで AllowN(capacity) は true、tokens は 0 に
func TestAllowN_満タンで全量取得(t *testing.T) {
	c := newFakeClock()
	l := New(1, 5, c.Now)
	if !l.AllowN(5) {
		t.Fatalf("満タンで AllowN(capacity) が失敗した")
	}
	if got := readTokens(l); got != 0 {
		t.Errorf("全量取得後の tokens=%v, 期待 0", got)
	}
}

// T-012: 満タンでも AllowN(capacity+1) は失敗、据え置き
func TestAllowN_容量超は常に失敗(t *testing.T) {
	c := newFakeClock()
	l := New(1, 5, c.Now)
	if l.AllowN(6) {
		t.Errorf("容量超 AllowN(capacity+1) が成功した")
	}
	if got := readTokens(l); got != 5 {
		t.Errorf("失敗後の tokens=%v, 期待 5(据え置き)", got)
	}
}

// T-013: rate=1,cap=1,空から1秒ちょうど経過で Allow() は true(補充境界)
func TestAllow_経過時間ちょうどで補充(t *testing.T) {
	c := newFakeClock()
	l := New(1, 1, c.Now)
	l.Allow() // 使い切る
	c.Advance(time.Second)
	if !l.Allow() {
		t.Errorf("1秒ちょうど経過後に補充されず Allow が失敗した")
	}
}

// T-014: 同条件で 0.999 秒(1秒未満)では補充足りず Allow() は false
func TestAllow_補充境界の直前は拒否(t *testing.T) {
	c := newFakeClock()
	l := New(1, 1, c.Now)
	l.Allow()
	c.Advance(999 * time.Millisecond)
	if l.Allow() {
		t.Errorf("1秒未満なのに補充されて Allow が成功した")
	}
}

// T-015: 長時間経過しても補充は capacity で頭打ち(溢れない)
func TestAllow_長時間経過でも容量超えない(t *testing.T) {
	c := newFakeClock()
	l := New(1, 3, c.Now)
	l.AllowN(3) // 空にする
	c.Advance(1000 * time.Second)
	if l.AllowN(4) {
		t.Errorf("長時間経過後に capacity 超の取得が成功した(溢れている)")
	}
	if got := readTokens(l); got != 3 {
		t.Errorf("補充後の tokens=%v, 期待 3(capacity で頭打ち)", got)
	}
}

// T-020: AllowN(0) は常に成功し tokens 不変
func TestAllowN_ゼロ要求は常に成功で不変(t *testing.T) {
	c := newFakeClock()
	l := New(1, 5, c.Now)
	l.AllowN(2) // tokens=3
	before := readTokens(l)
	if !l.AllowN(0) {
		t.Errorf("AllowN(0) が失敗した")
	}
	if got := readTokens(l); got != before {
		t.Errorf("AllowN(0) で tokens が %v -> %v に変化した", before, got)
	}
}

// T-021: AllowN(負) は n<=0 と同値で常に成功・不変
func TestAllowN_負の要求は不変で成功(t *testing.T) {
	c := newFakeClock()
	l := New(1, 5, c.Now)
	l.AllowN(2) // tokens=3
	before := readTokens(l)
	if !l.AllowN(-1) {
		t.Errorf("AllowN(-1) が失敗した")
	}
	if got := readTokens(l); got != before {
		t.Errorf("AllowN(-1) で tokens が %v -> %v に変化した", before, got)
	}
}

// T-022: Allow() は 1 トークン消費(AllowN(1) と等価)
func TestAllow_は1トークン消費(t *testing.T) {
	c := newFakeClock()
	l := New(1, 5, c.Now)
	l.Allow()
	if got := readTokens(l); got != 4 {
		t.Errorf("Allow 後の tokens=%v, 期待 4(1消費)", got)
	}
}

// T-030: 同一時刻で連続 acquire しても補充されない(dt=0)
func TestAllow_同一時刻では補充なし(t *testing.T) {
	c := newFakeClock()
	l := New(1, 5, c.Now)
	l.AllowN(5) // 空に。時刻は進めない
	if l.Allow() {
		t.Errorf("同一時刻(dt=0)なのに補充されて Allow が成功した")
	}
	if got := readTokens(l); got != 0 {
		t.Errorf("同一時刻での tokens=%v, 期待 0", got)
	}
}

// T-031: clock が巻き戻っても(dt<0)負補充せず、tokens は増えも負にもならない
func TestAllow_時刻巻き戻りで負補充しない(t *testing.T) {
	c := newFakeClock()
	c.Advance(100 * time.Second) // last=100s
	l := New(1, 5, c.Now)
	l.AllowN(2) // tokens=3
	c.Advance(-50 * time.Second) // 50s へ巻き戻し
	before := readTokens(l)
	l.Allow()
	got := readTokens(l)
	if got < 0 || got > 5 {
		t.Errorf("巻き戻り後 tokens=%v が範囲[0,5]外(INV1 破り)", got)
	}
	// 巻き戻り中は dt=0 クランプなので補充なし。Allow で 1 消費されるだけ。
	if got != before-1 {
		t.Errorf("巻き戻りで補充された疑い: %v -> %v(期待 %v)", before, got, before-1)
	}
}

// T-040(PROP1↔INV1): 任意の操作列でも常に 0 <= tokens <= capacity
func TestProperty_残量は常に範囲内(t *testing.T) {
	f := func(seed int64, rate01, cap01 uint16, steps uint8) bool {
		rate := 1 + float64(rate01%1000)/10  // (0,100] 程度の正値
		capacity := 1 + float64(cap01%1000)/10
		c := newFakeClock()
		l := New(rate, capacity, c.Now)
		rng := rand.New(rand.NewSource(seed))
		for i := 0; i < int(steps)+5; i++ {
			c.Advance(time.Duration(rng.Intn(2000)) * time.Millisecond)
			n := rng.Float64() * capacity * 1.5 // 容量超も混ぜる
			l.AllowN(n)
			if tok := readTokens(l); tok < 0 || tok > capacity {
				t.Logf("tokens=%v 範囲[0,%v]外", tok, capacity)
				return false
			}
		}
		return true
	}
	if err := quick.Check(f, &quick.Config{MaxCount: 500}); err != nil {
		t.Error(err)
	}
}

// T-041(PROP3↔INV3): AllowN(n) 成功 ⇔ 補充後 tokens>=n、成功時ちょうど n 減
func TestProperty_成功条件と消費量(t *testing.T) {
	f := func(seed int64, rate01, cap01 uint16, steps uint8) bool {
		rate := 1 + float64(rate01%1000)/10
		capacity := 1 + float64(cap01%1000)/10
		c := newFakeClock()
		l := New(rate, capacity, c.Now)
		rng := rand.New(rand.NewSource(seed))
		for i := 0; i < int(steps)+5; i++ {
			c.Advance(time.Duration(rng.Intn(2000)) * time.Millisecond)
			n := rng.Float64() * capacity * 1.5
			// 補充後・消費前の tokens を知るため、まず n=0 で補充だけ走らせる。
			l.AllowN(0)
			avail := readTokens(l)
			ok := l.AllowN(n)
			after := readTokens(l)
			if n <= 0 {
				if !ok || after != avail {
					return false // n<=0 は常に成功・不変
				}
				continue
			}
			expectOK := avail >= n
			if ok != expectOK {
				t.Logf("avail=%v n=%v ok=%v 期待=%v", avail, n, ok, expectOK)
				return false
			}
			if ok {
				if math.Abs((avail-n)-after) > 1e-9 {
					t.Logf("成功時の消費量がずれ: avail=%v n=%v after=%v", avail, n, after)
					return false
				}
			} else if after != avail {
				t.Logf("失敗時に据え置きでない: %v -> %v", avail, after)
				return false
			}
		}
		return true
	}
	if err := quick.Check(f, &quick.Config{MaxCount: 500}); err != nil {
		t.Error(err)
	}
}

// T-042(PROP2): 一定間隔で多数回 acquire しても許可総量 <= 経過時間*rate + capacity
func TestProperty_長期平均レートは設定以下(t *testing.T) {
	f := func(rate01, cap01 uint16, intervalMs uint16) bool {
		rate := 1 + float64(rate01%100)/10 // (0,10]
		capacity := 1 + float64(cap01%100)/10
		interval := time.Duration(1+int(intervalMs%1000)) * time.Millisecond
		c := newFakeClock()
		l := New(rate, capacity, c.Now)
		const calls = 2000
		granted := 0.0
		for i := 0; i < calls; i++ {
			c.Advance(interval)
			if l.AllowN(1) {
				granted++
			}
		}
		elapsed := float64(calls) * interval.Seconds()
		upper := elapsed*rate + capacity // バースト込みの上界
		if granted > upper+1e-9 {
			t.Logf("granted=%v > upper=%v (rate=%v cap=%v)", granted, upper, rate, capacity)
			return false
		}
		return true
	}
	if err := quick.Check(f, &quick.Config{MaxCount: 300}); err != nil {
		t.Error(err)
	}
}

// T-050(INV4): 初期満タン cap=K、N(>K) goroutine が同時 Allow() で成功総数 <= K
func TestConcurrent_許可総数は利用可能量以下(t *testing.T) {
	const K = 50
	const N = 500
	c := newFakeClock() // 時刻固定 = 補充なし(INV4 を純粋に検証)
	l := New(1, K, c.Now)

	var wg sync.WaitGroup
	var mu sync.Mutex
	granted := 0
	for i := 0; i < N; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			if l.Allow() {
				mu.Lock()
				granted++
				mu.Unlock()
			}
		}()
	}
	wg.Wait()
	if granted != K {
		t.Errorf("成功総数=%d, 期待ちょうど %d(補充なしなので初期量と一致)", granted, K)
	}
}

// T-051: -race で competing acquire を回しデータ競合がないこと(go test -race で実行)
func TestConcurrent_レース検出(t *testing.T) {
	c := newFakeClock()
	l := New(100, 100, c.Now)
	var wg sync.WaitGroup
	for i := 0; i < 100; i++ {
		wg.Add(1)
		go func(k int) {
			defer wg.Done()
			c.Advance(time.Millisecond) // clock も競合させる
			l.AllowN(float64(k%3 + 1))
		}(i)
	}
	wg.Wait()
}

// T-060: tokens >= n のとき AllowN(n) は理由なく失敗しない(正常系退行ガード)
func TestAllowN_供給十分なら成功する(t *testing.T) {
	c := newFakeClock()
	l := New(1, 10, c.Now)
	for i := 0; i < 5; i++ {
		if !l.AllowN(2) { // 各回 tokens は十分(10,8,6,4,2)
			t.Errorf("%d 回目: 供給十分なのに AllowN(2) が失敗した", i)
		}
	}
}
