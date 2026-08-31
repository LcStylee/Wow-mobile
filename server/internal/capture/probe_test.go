package capture

import (
	"errors"
	"strings"
	"testing"
)

func TestChooseEncoderSkipsFailingCandidate(t *testing.T) {
	// The original field black-screen: nvenc compiled in but its GPU runtime
	// absent. The trial must skip it and land on the working fallback.
	enc, err := chooseEncoder([]Encoder{NVENC, X264}, func(e Encoder) error {
		if e == NVENC {
			return errors.New("Cannot load libcuda.so.1")
		}
		return nil
	})
	if err != nil || enc != X264 {
		t.Fatalf("chooseEncoder = %q, %v; want x264, nil", enc, err)
	}
}

func TestChooseEncoderAllEncoderFailuresIsHardError(t *testing.T) {
	_, err := chooseEncoder([]Encoder{NVENC, X264}, func(e Encoder) error {
		return errors.New("no capable devices found")
	})
	if err == nil {
		t.Fatal("want an error when every encoder trial fails for encoder reasons")
	}
	// The error must hand the user the escape hatch.
	if !strings.Contains(err.Error(), "--encoder") {
		t.Fatalf("error should mention pinning --encoder; got: %v", err)
	}
}

func TestChooseEncoderLavfiLessFFmpegFallsBackUnverified(t *testing.T) {
	// An ffmpeg built without the lavfi device cannot run ANY trial; that
	// proves nothing about its encoders, so the most-preferred compiled-in
	// candidate is used (with a loud warning) instead of refusing to start.
	enc, err := chooseEncoder([]Encoder{NVENC, X264}, func(e Encoder) error {
		return errors.New("Unknown input format: 'lavfi'")
	})
	if err != nil || enc != NVENC {
		t.Fatalf("chooseEncoder = %q, %v; want nvenc (unverified fallback), nil", enc, err)
	}
}

func TestChooseEncoderMixedFailuresStayHard(t *testing.T) {
	// One lavfi failure does NOT unlock the fallback when another candidate
	// failed for a real encoder reason — the trial DID run there.
	_, err := chooseEncoder([]Encoder{NVENC, X264}, func(e Encoder) error {
		if e == NVENC {
			return errors.New("No such filter: 'testsrc2'")
		}
		return errors.New("x264 init failed")
	})
	if err == nil {
		t.Fatal("mixed failures must remain a hard error")
	}
}

func TestIsTestSourceFailure(t *testing.T) {
	cases := []struct {
		msg  string
		want bool
	}{
		{"Unknown input format: 'lavfi'", true},
		{"No such filter: 'testsrc2'", true},
		{"testsrc2: No such filter", true},
		{"Cannot load libcuda.so.1", false},
		{"no NVENC capable devices found", false},
		// ffmpeg component-context prefixes must NOT trip the classifier:
		// a genuine encoder failure whose stderr tail carries "[lavfi @ ...]"
		// or "[Parsed_testsrc2_0 @ ...]" lines is still an encoder failure,
		// or chooseEncoder would fall back to the broken encoder unverified.
		{"[lavfi @ 0x55d3f0] deprecated option | Cannot load libcuda.so.1", false},
		{"[Parsed_testsrc2_0 @ 0x7f1a20] frame dropped | no NVENC capable devices found", false},
	}
	for _, c := range cases {
		if got := isTestSourceFailure(errors.New(c.msg)); got != c.want {
			t.Errorf("isTestSourceFailure(%q) = %v, want %v", c.msg, got, c.want)
		}
	}
}
