package capture

import (
	"strings"
	"testing"
)

func TestEncodeSizeMatchIsQuiet(t *testing.T) {
	w, h, mismatch := EncodeSize(1080, 1920, 1080, 1920)
	if w != 1080 || h != 1920 || mismatch {
		t.Fatalf("exact match: got %dx%d mismatch=%v", w, h, mismatch)
	}
}

func TestEncodeSizeAdoptsActualWindow(t *testing.T) {
	// The field-reported failure: WoW came up ~1080x1040 while 1080x1920 was
	// configured. The stream must adopt the real window — a fixed crop of the
	// assumed size is the black-frames-with-working-clicks failure.
	w, h, mismatch := EncodeSize(1080, 1040, 1080, 1920)
	if w != 1080 || h != 1040 || !mismatch {
		t.Fatalf("got %dx%d mismatch=%v, want 1080x1040 mismatch=true", w, h, mismatch)
	}
}

func TestEncodeSizeEvenFloorsOddRects(t *testing.T) {
	// Odd client areas happen (borders, DPI rounding); H.264 4:2:0 needs
	// mod-2, so the encode even-floors and the sub-pixel scale is accepted.
	w, h, mismatch := EncodeSize(1081, 1041, 1080, 1920)
	if w != 1080 || h != 1040 || !mismatch {
		t.Fatalf("odd rect: got %dx%d mismatch=%v, want 1080x1040 mismatch=true", w, h, mismatch)
	}
	// An odd rect that even-floors ONTO the configured size is not a
	// mismatch: the encoded frame is exactly what was advertised.
	w, h, mismatch = EncodeSize(1081, 1921, 1080, 1920)
	if w != 1080 || h != 1920 || mismatch {
		t.Fatalf("odd-but-matching rect: got %dx%d mismatch=%v, want 1080x1920 mismatch=false", w, h, mismatch)
	}
}

func TestEncodeSizeUnreadableWindowKeepsConfig(t *testing.T) {
	// No trustworthy rect (window vanished between checks): keep the
	// configured frame quietly — there is nothing real to warn about yet.
	for _, c := range [][2]int{{0, 0}, {-1, 1080}, {1080, -5}} {
		w, h, mismatch := EncodeSize(c[0], c[1], 1080, 1920)
		if w != 1080 || h != 1920 || mismatch {
			t.Errorf("EncodeSize(%d,%d): got %dx%d mismatch=%v, want config quietly", c[0], c[1], w, h, mismatch)
		}
	}
}

func TestEncodeSizeDegenerateWindowKeepsConfigLoudly(t *testing.T) {
	// A real but unencodably small rect (mid-collapse) keeps the configured
	// frame — but IS flagged, because the window provably mismatches.
	w, h, mismatch := EncodeSize(8, 8, 1080, 1920)
	if w != 1080 || h != 1920 || !mismatch {
		t.Fatalf("degenerate rect: got %dx%d mismatch=%v, want 1080x1920 mismatch=true", w, h, mismatch)
	}
	// 17x17 even-floors to 16x16 — exactly the minimum, still encodable.
	w, h, mismatch = EncodeSize(17, 17, 1080, 1920)
	if w != 16 || h != 16 || !mismatch {
		t.Fatalf("minimum rect: got %dx%d mismatch=%v, want 16x16 mismatch=true", w, h, mismatch)
	}
}

func TestMismatchWarningNamesBothSizesAndCauses(t *testing.T) {
	msg := MismatchWarning(1080, 1040, 1080, 1920, 1080, 1040)
	for _, want := range []string{"1080x1040", "1080x1920", "Config.wtf", "re-run setup"} {
		if !strings.Contains(msg, want) {
			t.Errorf("warning %q missing %q", msg, want)
		}
	}
}
