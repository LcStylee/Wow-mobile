package main

import "testing"

// A copy mid-startup: the dashboard comes up after a few polls — the caller
// must get stuckBecameAlive and show the NORMAL already-running choices.
func TestWaitStuckResolutionBecomesAlive(t *testing.T) {
	polls := 0
	got := waitStuckResolution(
		func() bool { return false },
		func() bool { polls++; return polls >= 3 },
		func() bool { return polls > 10 },
		func() {},
	)
	if got != stuckBecameAlive {
		t.Fatalf("outcome = %v, want stuckBecameAlive", got)
	}
}

// A copy mid-shutdown: the mutex frees — the caller proceeds silently with
// the freshly claimed handle, no dialog at all.
func TestWaitStuckResolutionWentAway(t *testing.T) {
	polls := 0
	got := waitStuckResolution(
		func() bool { polls++; return polls >= 2 },
		func() bool { return false },
		func() bool { return polls > 10 },
		func() {},
	)
	if got != stuckWentAway {
		t.Fatalf("outcome = %v, want stuckWentAway", got)
	}
}

// Genuinely wedged: neither resolves before the deadline.
func TestWaitStuckResolutionStillStuck(t *testing.T) {
	polls := 0
	got := waitStuckResolution(
		func() bool { return false },
		func() bool { return false },
		func() bool { polls++; return polls >= 4 },
		func() {},
	)
	if got != stuckStillStuck {
		t.Fatalf("outcome = %v, want stuckStillStuck", got)
	}
	if polls != 4 {
		t.Fatalf("expired() consulted %d times, want 4 (probe before claim before expiry, each round)", polls)
	}
}

// The dashboard must be probed BEFORE the first sleep and before claiming:
// a copy that finished starting between the caller's own probe and this
// call is caught immediately, and a live copy's mutex is never claimed.
func TestWaitStuckResolutionProbesFirst(t *testing.T) {
	claimed := false
	got := waitStuckResolution(
		func() bool { claimed = true; return true },
		func() bool { return true },
		func() bool { return true },
		func() { t.Fatal("slept before resolving") },
	)
	if got != stuckBecameAlive || claimed {
		t.Fatalf("outcome = %v (claimed=%v), want stuckBecameAlive without a claim attempt", got, claimed)
	}
}
