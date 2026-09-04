// The single-instance mutex alone is not proof of a HEALTHY running copy: a
// wowstreamd stuck mid-startup (its first dialog hidden behind other
// windows) or wedged mid-shutdown holds the mutex while answering on no
// dashboard — and offering "Open dashboard" then lands the user on
// ERR_CONNECTION_REFUSED (field report v0.4.1). This file holds the pure
// resolution loop, portable so it is unit-testable off Windows; the Windows
// guard injects the real mutex/probe callbacks.
package main

// stuckOutcome is what waitStuckResolution observed the other copy do.
type stuckOutcome int

const (
	// stuckStillStuck: the deadline passed with the mutex still held and no
	// dashboard answering — the copy is genuinely wedged.
	stuckStillStuck stuckOutcome = iota
	// stuckBecameAlive: a dashboard now answers — the copy was mid-startup;
	// the normal already-running choices apply.
	stuckBecameAlive
	// stuckWentAway: the mutex freed — the copy was mid-shutdown; the caller
	// received a freshly claimed handle via claim() and proceeds silently.
	stuckWentAway
)

// waitStuckResolution polls until a mutex-holding copy with no dashboard
// resolves itself one way or the other, or the bounded wait runs out.
//
//	claim()   tries to take the single-instance mutex; ok=true hands
//	          ownership to the caller (release via the returned handle,
//	          managed by the caller's closure).
//	probe()   reports whether a dashboard answers now.
//	expired() reports whether the bounded wait is over.
//	sleep()   waits one poll step.
//
// The probe runs before the first sleep so a copy that finished starting
// between the caller's own probe and this call is caught immediately.
func waitStuckResolution(claim func() bool, probe func() bool, expired func() bool, sleep func()) stuckOutcome {
	for {
		if probe() {
			return stuckBecameAlive
		}
		if claim() {
			return stuckWentAway
		}
		if expired() {
			return stuckStillStuck
		}
		sleep()
	}
}
