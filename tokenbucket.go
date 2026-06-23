// Package tokenbucket は lazy 補充方式のトークンバケット rate limiter を提供する。
//
// lazy 補充: タイマーを持たず、acquire のたびに前回からの経過時間ぶんを
// その場で補充する。状態は tokens と last の2つだけで、単一の mutex が
// 補充計算から消費判定までを1つのクリティカルセクションとして相互排他する。
package tokenbucket

import (
	"math"
	"sync"
	"time"
)

// Limiter は lazy 補充トークンバケット。ゼロ値は使えない。New で生成する。
type Limiter struct {
	rate     float64 // トークン/秒(補充速度)
	capacity float64 // バケット上限(=バースト許容量)
	now      func() time.Time

	mu     sync.Mutex // INV4: acquire 全体を1つのクリティカルセクションで相互排他
	tokens float64    // 現在の利用可能トークン。INV1: 0 <= tokens <= capacity
	last   time.Time  // 前回 acquire 時刻(補充の基点)
}

// New は満タン状態の Limiter を生成する。
// rate <= 0 または capacity <= 0 は不正な設定として panic で弾く。
// now が nil なら time.Now を既定にする(本番は monotonic、テストは fake clock を注入)。
func New(rate float64, capacity float64, now func() time.Time) *Limiter {
	if rate <= 0 {
		panic("tokenbucket: rate は正でなければならない")
	}
	if capacity <= 0 {
		panic("tokenbucket: capacity は正でなければならない")
	}
	if now == nil {
		now = time.Now
	}
	return &Limiter{
		rate:     rate,
		capacity: capacity,
		now:      now,
		tokens:   capacity, // 初期は満タン
		last:     now(),
	}
}

// Allow は AllowN(1) と等価。1 トークン消費できれば true。
func (l *Limiter) Allow() bool {
	return l.AllowN(1)
}

// AllowN は n トークンの消費を試みる。消費できれば true、足りなければ false。
// 手順(mutex で 1〜5 全体を相互排他。順序が load-bearing):
//  1. dt = now - last(秒)。dt < 0(時刻巻き戻り)は 0 にクランプ
//  2. tokens = min(capacity, tokens + rate*dt) … 補充とクランプを消費判定より先に
//  3. last = now()(消費の成否に依らず補充は確定)
//  4. n <= 0 は常に成功し tokens 不変
//  5. tokens >= n なら n 減らして true、さもなくば据え置きで false
func (l *Limiter) AllowN(n float64) bool {
	l.mu.Lock()
	defer l.mu.Unlock()

	now := l.now()
	dt := now.Sub(l.last).Seconds()
	if dt < 0 {
		dt = 0 // 時刻巻き戻り: 負補充しない(INV1 維持)
	}
	l.tokens = math.Min(l.capacity, l.tokens+l.rate*dt) // 補充直後に clamp(後段クランプ禁止)
	l.last = now

	if n <= 0 {
		return true // INV3: n<=0 は常に成功・tokens 不変
	}
	if l.tokens >= n {
		l.tokens -= n // INV3: 成功時ちょうど n 減
		return true
	}
	return false // INV3: 失敗時は据え置き
}
