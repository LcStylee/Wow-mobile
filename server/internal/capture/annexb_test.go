package capture

import (
	"bytes"
	"testing"
)

// Test NALUs. VCL slice payloads start with first_mb_in_slice as ue(v):
//
//	0x80... => leading bit 1        => first_mb_in_slice = 0 (new picture)
//	0x40... => bits 010             => first_mb_in_slice = 1 (same picture)
var (
	sps        = []byte{0x67, 0x42, 0xE0, 0x1F, 0xAA}
	pps        = []byte{0x68, 0xCE, 0x3C, 0x80}
	sei        = []byte{0x06, 0x05, 0x11, 0x22}
	idrSlice0  = []byte{0x65, 0x88, 0x84, 0x21, 0xFF} // IDR, first_mb = 0
	pSlice0    = []byte{0x41, 0x9A, 0x21, 0x6C}       // non-IDR, first_mb = 0 (0x9A = 1001...)
	pSliceCont = []byte{0x41, 0x40, 0x33, 0x44}       // non-IDR, first_mb = 1
)

func withStartCode(fourByte bool, nalu []byte) []byte {
	if fourByte {
		return append([]byte{0, 0, 0, 1}, nalu...)
	}
	return append([]byte{0, 0, 1}, nalu...)
}

func stream(nalus ...[]byte) []byte {
	var out []byte
	for _, n := range nalus {
		out = append(out, withStartCode(true, n)...)
	}
	return out
}

type collector struct {
	aus []AccessUnit
}

func (c *collector) collect(au AccessUnit) {
	c.aus = append(c.aus, AccessUnit{Data: bytes.Clone(au.Data), Keyframe: au.Keyframe})
}

func TestAnnexBGrouping(t *testing.T) {
	c := &collector{}
	p := NewAnnexBParser(c.collect)

	// IDR AU with parameter sets, then two P frames, second one multi-slice.
	p.Write(stream(sps, pps, sei, idrSlice0, pSlice0, pSlice0, pSliceCont))
	p.Flush()

	if len(c.aus) != 3 {
		t.Fatalf("got %d access units, want 3", len(c.aus))
	}
	if !c.aus[0].Keyframe {
		t.Error("first AU must be a keyframe")
	}
	if !bytes.Equal(c.aus[0].Data, stream(sps, pps, sei, idrSlice0)) {
		t.Errorf("AU0 = % x\nwant SPS+PPS+SEI+IDR", c.aus[0].Data)
	}
	if c.aus[1].Keyframe || !bytes.Equal(c.aus[1].Data, stream(pSlice0)) {
		t.Errorf("AU1 = % x, keyframe=%v; want single P slice", c.aus[1].Data, c.aus[1].Keyframe)
	}
	// Continuation slice (first_mb != 0) stays in the same AU.
	if !bytes.Equal(c.aus[2].Data, stream(pSlice0, pSliceCont)) {
		t.Errorf("AU2 = % x\nwant both slices of the picture", c.aus[2].Data)
	}
}

func TestAnnexBEmitsOnNextAUStart(t *testing.T) {
	c := &collector{}
	p := NewAnnexBParser(c.collect)

	p.Write(stream(sps, pps, idrSlice0))
	if len(c.aus) != 0 {
		t.Fatal("AU emitted before its boundary was known")
	}
	// The next picture's slice closes the previous AU as soon as its start
	// code and classifiable first bytes arrive — the slice need NOT be
	// complete. This early emission is what keeps the parser from adding a
	// constant frame period of latency.
	p.Write(stream(pSlice0))
	if len(c.aus) != 1 || !c.aus[0].Keyframe {
		t.Fatalf("got %d AUs, want the IDR unit as soon as the next picture's slice started", len(c.aus))
	}
	if !bytes.Equal(c.aus[0].Data, stream(sps, pps, idrSlice0)) {
		t.Errorf("AU0 = % x\nwant SPS+PPS+IDR", c.aus[0].Data)
	}
	// An SPS after a VCL NALU also opens the next unit: its arrival (start
	// code + type byte) closes the pSlice0 picture immediately.
	p.Write(stream(sps))
	if len(c.aus) != 2 || !bytes.Equal(c.aus[1].Data, stream(pSlice0)) {
		t.Fatalf("got %d AUs, want 2 — SPS must close the preceding picture", len(c.aus))
	}
}

func TestAnnexBEarlyEmitWaitsForClassifiableHeader(t *testing.T) {
	c := &collector{}
	p := NewAnnexBParser(c.collect)

	p.Write(stream(sps, pps, idrSlice0))
	// Start code plus the NAL header alone: a VCL type needs
	// first_mb_in_slice before the boundary is decidable — no emission yet.
	p.Write([]byte{0, 0, 0, 1, pSlice0[0]})
	if len(c.aus) != 0 {
		t.Fatal("AU emitted before first_mb_in_slice was readable")
	}
	// The first payload byte decides it (leading bit 1 => first_mb = 0).
	p.Write(pSlice0[1:2])
	if len(c.aus) != 1 || !c.aus[0].Keyframe {
		t.Fatalf("got %d AUs, want the IDR unit once the slice header was classifiable", len(c.aus))
	}
	// A continuation slice (first_mb != 0) must NOT trigger early emission.
	p.Write(pSlice0[2:])
	p.Write(withStartCode(true, pSliceCont))
	if len(c.aus) != 1 {
		t.Fatalf("got %d AUs, want 1 — continuation slice wrongly split the picture", len(c.aus))
	}
	p.Flush()
	if len(c.aus) != 2 || !bytes.Equal(c.aus[1].Data, stream(pSlice0, pSliceCont)) {
		t.Fatalf("final AU must hold both slices of the picture, got % x", c.aus[len(c.aus)-1].Data)
	}
}

func TestAnnexBThreeByteStartCodes(t *testing.T) {
	c := &collector{}
	p := NewAnnexBParser(c.collect)

	var in []byte
	in = append(in, withStartCode(false, sps)...)
	in = append(in, withStartCode(false, pps)...)
	in = append(in, withStartCode(false, idrSlice0)...)
	in = append(in, withStartCode(false, pSlice0)...)
	p.Write(in)
	p.Flush()

	if len(c.aus) != 2 {
		t.Fatalf("got %d AUs, want 2", len(c.aus))
	}
	// Output is normalized to 4-byte codes regardless of input form.
	if !bytes.Equal(c.aus[0].Data, stream(sps, pps, idrSlice0)) {
		t.Errorf("AU0 = % x", c.aus[0].Data)
	}
}

func TestAnnexBSplitAcrossChunks(t *testing.T) {
	full := stream(sps, pps, idrSlice0, pSlice0, pSliceCont, pSlice0)
	want := func() []AccessUnit {
		c := &collector{}
		p := NewAnnexBParser(c.collect)
		p.Write(full)
		p.Flush()
		return c.aus
	}()
	if len(want) != 3 {
		t.Fatalf("reference parse produced %d AUs, want 3", len(want))
	}

	// Every chunk size from 1 (worst case: every start code split) up.
	for size := 1; size <= len(full); size++ {
		c := &collector{}
		p := NewAnnexBParser(c.collect)
		for i := 0; i < len(full); i += size {
			p.Write(full[i:min(i+size, len(full))])
		}
		p.Flush()
		if len(c.aus) != len(want) {
			t.Fatalf("chunk size %d: got %d AUs, want %d", size, len(c.aus), len(want))
		}
		for i := range want {
			if !bytes.Equal(c.aus[i].Data, want[i].Data) || c.aus[i].Keyframe != want[i].Keyframe {
				t.Fatalf("chunk size %d: AU%d mismatch:\ngot  % x\nwant % x", size, i, c.aus[i].Data, want[i].Data)
			}
		}
	}
}

func TestAnnexBLeadingGarbageAndTrailingZeros(t *testing.T) {
	c := &collector{}
	p := NewAnnexBParser(c.collect)

	// Garbage before the first start code is discarded; trailing_zero_8bits
	// after a NALU must not leak into its payload.
	var in []byte
	in = append(in, 0xDE, 0xAD, 0xBE, 0xEF)
	in = append(in, withStartCode(true, sps)...)
	in = append(in, 0x00, 0x00) // trailing zeros, then a 4-byte code follows
	in = append(in, withStartCode(true, idrSlice0)...)
	in = append(in, withStartCode(true, pSlice0)...)
	p.Write(in)
	p.Flush()

	if len(c.aus) != 2 {
		t.Fatalf("got %d AUs, want 2", len(c.aus))
	}
	if !bytes.Equal(c.aus[0].Data, stream(sps, idrSlice0)) {
		t.Errorf("AU0 = % x — trailing zeros or garbage leaked", c.aus[0].Data)
	}
}

func TestFirstMBInSlice(t *testing.T) {
	tests := []struct {
		name string
		nalu []byte
		want uint32
		ok   bool
	}{
		{"first_mb 0", []byte{0x65, 0x88, 0x00}, 0, true},
		{"first_mb 0 alt", []byte{0x41, 0x9A, 0x00}, 0, true},
		{"first_mb 1", []byte{0x41, 0x40}, 1, true},
		{"first_mb 2", []byte{0x41, 0x60}, 2, true},
		{"first_mb 3", []byte{0x41, 0x20}, 3, true}, // 00100
		{"first_mb 6", []byte{0x41, 0x38}, 6, true}, // 00111
		{"header only", []byte{0x41}, 0, false},
		{"all zero bits", []byte{0x41, 0x00, 0x00}, 0, false},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got, ok := firstMBInSlice(tt.nalu)
			if got != tt.want || ok != tt.ok {
				t.Fatalf("firstMBInSlice(% x) = %d,%v want %d,%v", tt.nalu, got, ok, tt.want, tt.ok)
			}
		})
	}
}

func TestExpGolomb(t *testing.T) {
	// ue(v) encodings: value => bit string
	//   0 => 1
	//   1 => 010
	//   2 => 011
	//   3 => 00100
	//   7 => 0001000
	//   8 => 0001001
	tests := []struct {
		bits []byte
		want []uint32
	}{
		{[]byte{0b10100110}, []uint32{0, 1, 2}}, // 1 010 011 (0)
		{[]byte{0b00100000}, []uint32{3}},       // 00100
		{[]byte{0b00010000}, []uint32{7}},       // 0001000
		{[]byte{0b00010010}, []uint32{8}},       // 0001001
		{[]byte{0b11111111}, []uint32{0, 0, 0, 0, 0, 0, 0, 0}},
	}
	for _, tt := range tests {
		r := newEBSPReader(tt.bits)
		for i, want := range tt.want {
			got, err := r.readUE()
			if err != nil {
				t.Fatalf("bits % x value %d: %v", tt.bits, i, err)
			}
			if got != want {
				t.Fatalf("bits % x value %d = %d, want %d", tt.bits, i, got, want)
			}
		}
	}

	// Truncated stream errors instead of fabricating a value.
	r := newEBSPReader([]byte{0x00})
	if _, err := r.readUE(); err == nil {
		t.Fatal("truncated ue(v) did not error")
	}
}

func TestExpGolombEmulationPrevention(t *testing.T) {
	// EBSP 00 00 03 FF: the 0x03 after two zero bytes is an
	// emulation-prevention byte; the RBSP is 00 00 FF — 16 zero bits followed
	// by 8 one bits.
	r := newEBSPReader([]byte{0x00, 0x00, 0x03, 0xFF})
	for i := 0; i < 24; i++ {
		b, err := r.readBit()
		if err != nil {
			t.Fatalf("bit %d: %v", i, err)
		}
		want := uint32(0)
		if i >= 16 {
			want = 1
		}
		if b != want {
			t.Fatalf("bit %d = %d, want %d (emulation-prevention byte mishandled)", i, b, want)
		}
	}
	if _, err := r.readBit(); err == nil {
		t.Fatal("read past end of de-escaped payload")
	}

	// Without two preceding zero bytes, 0x03 is ordinary payload:
	// 0x01 0x03 => 0000000100000011 => ue reads 7 zeros, 1, then 7 info bits
	// 0000001 => 127 + 1 = 128.
	r = newEBSPReader([]byte{0x01, 0x03})
	got, err := r.readUE()
	if err != nil {
		t.Fatalf("readUE: %v", err)
	}
	if got != 128 {
		t.Fatalf("ue = %d, want 128 (0x03 wrongly skipped)", got)
	}
}

// SPS/PPS must ride with EVERY keyframe access unit: none of the supported
// encoders repeat parameter sets on periodic GOP IDRs, but a browser joining
// (or PLI-recovering) on such an IDR cannot decode without them — the classic
// "bytes flow, screen stays black" failure. The parser caches the newest
// SPS/PPS and prepends them to keyframes that lack their own.
func TestAnnexBAttachesCachedSPSPPSToBareKeyframes(t *testing.T) {
	c := &collector{}
	p := NewAnnexBParser(c.collect)

	// Opening IDR carries its own SPS/PPS; a GOP later the encoder emits a
	// bare IDR (the real-world nvenc/x264 behavior without repeat-headers).
	p.Write(stream(sps, pps, idrSlice0, pSlice0, idrSlice0, pSlice0))
	p.Flush()

	if len(c.aus) != 4 {
		t.Fatalf("got %d access units, want 4", len(c.aus))
	}
	// AU0: already has the parameter sets — must NOT be double-prefixed.
	if !bytes.Equal(c.aus[0].Data, stream(sps, pps, idrSlice0)) {
		t.Errorf("AU0 = % x\nwant SPS+PPS+IDR untouched", c.aus[0].Data)
	}
	// AU2: the bare mid-stream IDR gains the cached SPS+PPS, in that order.
	if !c.aus[2].Keyframe {
		t.Fatal("AU2 must be the mid-stream keyframe")
	}
	if !bytes.Equal(c.aus[2].Data, stream(sps, pps, idrSlice0)) {
		t.Errorf("AU2 = % x\nwant cached SPS+PPS prepended to the bare IDR", c.aus[2].Data)
	}
	// Non-IDR units stay untouched.
	if !bytes.Equal(c.aus[1].Data, stream(pSlice0)) || !bytes.Equal(c.aus[3].Data, stream(pSlice0)) {
		t.Errorf("P-frame AUs must not gain parameter sets: % x / % x", c.aus[1].Data, c.aus[3].Data)
	}
}

// A keyframe carrying only ONE of its parameter sets in-band still gets BOTH
// cached sets prepended, keeping the prefix in SPS-then-PPS order for every
// combination — prepending only the missing PPS ahead of an in-band SPS would
// invert the documented order. The duplicated set is legal and harmless.
func TestAnnexBKeyframeWithOneInBandSetGetsBothCached(t *testing.T) {
	c := &collector{}
	p := NewAnnexBParser(c.collect)

	// AU0 primes the cache; AU1 has an in-band SPS but no PPS; AU2 has an
	// in-band PPS but no SPS.
	p.Write(stream(sps, pps, idrSlice0, sps, idrSlice0, pps, idrSlice0))
	p.Flush()

	if len(c.aus) != 3 {
		t.Fatalf("got %d access units, want 3", len(c.aus))
	}
	if !bytes.Equal(c.aus[1].Data, stream(sps, pps, sps, idrSlice0)) {
		t.Errorf("SPS-only IDR = % x\nwant cached SPS+PPS first, then the in-band SPS", c.aus[1].Data)
	}
	if !bytes.Equal(c.aus[2].Data, stream(sps, pps, pps, idrSlice0)) {
		t.Errorf("PPS-only IDR = % x\nwant cached SPS+PPS first, then the in-band PPS", c.aus[2].Data)
	}
}

// A NEWER SPS/PPS pair replaces the cache (bitrate restarts re-emit possibly
// different sets), and a keyframe before any SPS/PPS ever appeared is passed
// through unmodified rather than prefixed with nothing.
func TestAnnexBSPSPPSCacheFreshness(t *testing.T) {
	c := &collector{}
	p := NewAnnexBParser(c.collect)

	// Keyframe before any parameter set: emitted as-is.
	p.Write(stream(idrSlice0, pSlice0))
	// Then a full IDR with sets, then a bare IDR: must get the NEW sets.
	sps2 := []byte{0x67, 0x42, 0xE0, 0x20, 0xBB}
	p.Write(withStartCode(true, sps2))
	p.Write(stream(pps, idrSlice0, idrSlice0))
	p.Flush()

	if len(c.aus) != 4 {
		t.Fatalf("got %d access units, want 4", len(c.aus))
	}
	if !bytes.Equal(c.aus[0].Data, stream(idrSlice0)) {
		t.Errorf("pre-SPS keyframe must pass through untouched: % x", c.aus[0].Data)
	}
	if !bytes.Equal(c.aus[3].Data, stream(sps2, pps, idrSlice0)) {
		t.Errorf("bare IDR must carry the NEWEST cached sets:\n got % x\nwant % x",
			c.aus[3].Data, stream(sps2, pps, idrSlice0))
	}
}
