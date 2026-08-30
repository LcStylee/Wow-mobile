package capture

import "errors"

// H.264 NAL unit types this parser cares about (Rec. ITU-T H.264 table 7-1).
const (
	nalSliceNonIDR = 1 // coded slice of a non-IDR picture (VCL)
	nalSliceIDR    = 5 // coded slice of an IDR picture (VCL)
	nalSEI         = 6
	nalSPS         = 7
	nalPPS         = 8
	nalAUD         = 9
)

// AccessUnit is one decodable unit: every parameter-set/SEI NALU immediately
// preceding a picture plus all slices of that picture, each prefixed with a
// 4-byte start code — exactly what pion's H.264 payloader consumes.
type AccessUnit struct {
	Data     []byte
	Keyframe bool // contains an IDR slice
}

// AnnexBParser incrementally splits an H.264 Annex-B byte stream into access
// units. Feed arbitrary chunks with Write; complete units are delivered to the
// callback. Both 3-byte (00 00 01) and 4-byte (00 00 00 01) start codes are
// handled, including codes split across Write boundaries.
//
// Access-unit boundaries (H.264 §7.4.1.2.3/.4, reduced to what the supported
// encoders emit):
//   - a VCL NALU (type 1/5) whose first_mb_in_slice == 0 starts a new
//     picture; additional slices of the same picture have first_mb != 0 and
//     stay in the current unit;
//   - SPS/PPS/SEI/AUD arriving after a VCL NALU belong to the *next* unit.
//
// Latency, load-bearing: a unit is emitted as soon as the next unit's opening
// NALU can be *classified* — its NAL header plus (for slices) enough bytes to
// decode first_mb_in_slice, all of which arrive in the same pipe write as the
// terminating start code in practice. Waiting for that NALU to complete
// instead would cost a full frame period (~17 ms @60 fps) on the
// single-slice-per-frame streams these encoders emit, a third of the
// 30–60 ms glass-to-glass budget. Call Flush when the stream ends to emit the
// buffered tail.
type AnnexBParser struct {
	onAU func(AccessUnit)

	buf     []byte // stream tail: current (unterminated) NALU body
	scanned int    // buf[:scanned] is known to contain no start code
	synced  bool   // true once the first start code has been seen

	au       []byte // access unit under construction
	auHasVCL bool
	auIsIDR  bool
	auHasSPS bool
	auHasPPS bool

	// Cached copies of the newest SPS/PPS seen on the stream. None of the
	// supported encoders repeat parameter sets on periodic (GOP) IDRs — only
	// the very first frame after an encoder (re)start carries them — but a
	// browser that joins or PLI-recovers on a later IDR cannot decode without
	// them: the picture stays black even though bytes flow. emit therefore
	// prepends the cached sets to every keyframe access unit that lacks its
	// own, making every IDR a true join point.
	spsCache []byte
	ppsCache []byte
	prefixed []byte // scratch for the SPS/PPS-prefixed keyframe (reused)
}

// maxNALUBytes bounds memory if the stream desynchronizes (e.g. ffmpeg writes
// garbage): no legal NALU at our bitrates approaches this.
const maxNALUBytes = 8 << 20

// NewAnnexBParser returns a parser delivering access units to onAU. The
// AccessUnit passed to the callback is only valid for the duration of the
// call; the parser reuses its buffers.
func NewAnnexBParser(onAU func(AccessUnit)) *AnnexBParser {
	return &AnnexBParser{onAU: onAU}
}

// Write consumes the next chunk of the elementary stream.
func (p *AnnexBParser) Write(chunk []byte) {
	p.buf = append(p.buf, chunk...)
	for {
		i := indexStartCode(p.buf[p.scanned:])
		if i < 0 {
			// No start code; all but the last two bytes (a possible prefix of
			// a code split across chunks) need not be rescanned.
			p.scanned = max(len(p.buf)-2, 0)
			break
		}
		i += p.scanned
		if p.synced {
			p.handleNALU(trimTrailingZeros(p.buf[:i]))
		}
		// Drop the NALU and its terminating 3-byte code. A 4-byte code's
		// leading zero was removed by trimTrailingZeros above.
		p.buf = append(p.buf[:0], p.buf[i+3:]...)
		p.scanned = 0
		p.synced = true
	}
	// Early emission (see type comment): buf now holds the incomplete first
	// NALU of what may be the next access unit. If its first bytes already
	// prove it opens a new unit, the current unit is complete — deliver it
	// now instead of waiting for this NALU to be terminated one frame later.
	// handleNALU cannot double-emit afterwards: emit clears auHasVCL.
	if p.synced && p.auHasVCL {
		if startsNew, decided := prefixStartsNewAU(p.buf); decided && startsNew {
			p.emit()
		}
	}
	if len(p.buf) > maxNALUBytes {
		// Desynchronized stream: resync at the next start code.
		p.buf = p.buf[:0]
		p.scanned = 0
		p.synced = false
	}
}

// Flush consumes the buffered tail (stream end terminates the final NALU the
// way a start code would) and emits the access unit under construction, if it
// holds a picture. Use on stream end only; mid-stream flushing would split
// units.
func (p *AnnexBParser) Flush() {
	if p.synced {
		p.handleNALU(trimTrailingZeros(p.buf))
	}
	p.buf = p.buf[:0]
	p.scanned = 0
	p.synced = false
	if p.auHasVCL {
		p.emit()
	}
	p.au = p.au[:0]
	p.auHasVCL = false
	p.auIsIDR = false
	p.auHasSPS = false
	p.auHasPPS = false
}

func (p *AnnexBParser) handleNALU(nalu []byte) {
	if len(nalu) == 0 {
		return
	}
	typ := nalu[0] & 0x1F
	isVCL := typ == nalSliceNonIDR || typ == nalSliceIDR

	startsNewAU := false
	switch {
	case isVCL:
		fm, ok := firstMBInSlice(nalu)
		// Unparseable slice header: treat as a picture boundary — worst case
		// we split one frame, versus concatenating frames forever.
		startsNewAU = !ok || fm == 0
	case typ == nalSPS || typ == nalPPS || typ == nalSEI || typ == nalAUD:
		startsNewAU = true
	}
	if startsNewAU && p.auHasVCL {
		p.emit()
	}

	p.au = append(p.au, 0, 0, 0, 1)
	p.au = append(p.au, nalu...)
	switch {
	case isVCL:
		p.auHasVCL = true
		p.auIsIDR = p.auIsIDR || typ == nalSliceIDR
	case typ == nalSPS:
		p.auHasSPS = true
		p.spsCache = append(p.spsCache[:0], nalu...) // nalu aliases p.buf: copy
	case typ == nalPPS:
		p.auHasPPS = true
		p.ppsCache = append(p.ppsCache[:0], nalu...)
	}
}

// prefixStartsNewAU classifies whether the NALU whose first bytes are in
// prefix (still unterminated — no following start code yet) opens a new
// access unit. decided == false means more bytes are needed to tell. The
// rules mirror handleNALU exactly so early emission and completion-time
// handling always agree on the boundary.
func prefixStartsNewAU(prefix []byte) (startsNew, decided bool) {
	if len(prefix) == 0 {
		return false, false // not even the NAL header yet
	}
	typ := prefix[0] & 0x1F
	switch typ {
	case nalSliceNonIDR, nalSliceIDR:
		if fm, ok := firstMBInSlice(prefix); ok {
			return fm == 0, true
		}
		// firstMBInSlice reads at most 8 payload bytes. With fewer buffered
		// the parse may have failed on truncation — wait for more. With the
		// full window present, the header is malformed; treat it as a
		// boundary, matching handleNALU's worst-case-split fallback.
		if len(prefix) >= 9 {
			return true, true
		}
		return false, false
	case nalSPS, nalPPS, nalSEI, nalAUD:
		return true, true
	default:
		return false, true
	}
}

func (p *AnnexBParser) emit() {
	data := p.au
	// SPS/PPS ride with EVERY keyframe access unit (see the cache fields):
	// a keyframe missing either set gets the cached copies prepended, in
	// SPS-then-PPS order, so any IDR is decodable by a fresh joiner. Non-IDR
	// units are never touched.
	if p.auIsIDR && (!p.auHasSPS || !p.auHasPPS) && len(p.spsCache) > 0 && len(p.ppsCache) > 0 {
		pre := p.prefixed[:0]
		if !p.auHasSPS {
			pre = append(pre, 0, 0, 0, 1)
			pre = append(pre, p.spsCache...)
		}
		if !p.auHasPPS {
			pre = append(pre, 0, 0, 0, 1)
			pre = append(pre, p.ppsCache...)
		}
		pre = append(pre, p.au...)
		p.prefixed = pre
		data = pre
	}
	p.onAU(AccessUnit{Data: data, Keyframe: p.auIsIDR})
	p.au = p.au[:0]
	p.auHasVCL = false
	p.auIsIDR = false
	p.auHasSPS = false
	p.auHasPPS = false
}

// indexStartCode returns the offset of the first 00 00 01 sequence in b, or -1.
func indexStartCode(b []byte) int {
	for i := 0; i+2 < len(b); i++ {
		if b[i] == 0 && b[i+1] == 0 && b[i+2] == 1 {
			return i
		}
	}
	return -1
}

// trimTrailingZeros strips trailing 0x00 bytes: the leading zero of a 4-byte
// start code and any trailing_zero_8bits padding both belong to the boundary,
// not the NALU.
func trimTrailingZeros(b []byte) []byte {
	for len(b) > 0 && b[len(b)-1] == 0 {
		b = b[:len(b)-1]
	}
	return b
}

// firstMBInSlice extracts first_mb_in_slice — the first ue(v) field of the
// slice header — from a type 1/5 NALU (header byte + EBSP payload).
func firstMBInSlice(nalu []byte) (uint32, bool) {
	if len(nalu) < 2 {
		return 0, false
	}
	// first_mb_in_slice sits in the first payload bytes; 8 bytes bound the
	// reader (a ue(v) this large would be an absurd macroblock address).
	payload := nalu[1:]
	if len(payload) > 8 {
		payload = payload[:8]
	}
	r := newEBSPReader(payload)
	v, err := r.readUE()
	if err != nil {
		return 0, false
	}
	return v, true
}

// ebspReader reads bits from an EBSP (encapsulated byte sequence payload),
// transparently skipping the 0x03 emulation-prevention byte that follows two
// zero bytes (H.264 §7.4.1).
type ebspReader struct {
	data  []byte
	pos   int  // next byte index
	bit   uint // next bit within data[pos], 0 = MSB
	zeros int  // consecutive 0x00 bytes fully consumed
}

var errBitstream = errors.New("capture: truncated or invalid bitstream")

func newEBSPReader(data []byte) *ebspReader {
	return &ebspReader{data: data}
}

func (r *ebspReader) readBit() (uint32, error) {
	if r.bit == 0 && r.zeros >= 2 && r.pos < len(r.data) && r.data[r.pos] == 0x03 {
		r.pos++
		r.zeros = 0
	}
	if r.pos >= len(r.data) {
		return 0, errBitstream
	}
	b := (r.data[r.pos] >> (7 - r.bit)) & 1
	r.bit++
	if r.bit == 8 {
		if r.data[r.pos] == 0 {
			r.zeros++
		} else {
			r.zeros = 0
		}
		r.bit = 0
		r.pos++
	}
	return uint32(b), nil
}

// readUE decodes one unsigned exp-Golomb value: n leading zero bits, a one
// bit, then n info bits; value = 2^n - 1 + info (H.264 §9.1).
func (r *ebspReader) readUE() (uint32, error) {
	var zeros int
	for {
		b, err := r.readBit()
		if err != nil {
			return 0, err
		}
		if b == 1 {
			break
		}
		zeros++
		if zeros > 31 {
			return 0, errBitstream // not a value any conforming encoder emits
		}
	}
	v := uint32(1)<<zeros - 1
	for i := 0; i < zeros; i++ {
		b, err := r.readBit()
		if err != nil {
			return 0, err
		}
		v += b << (zeros - 1 - i)
	}
	return v, nil
}
