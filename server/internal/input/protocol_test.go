package input

import (
	"errors"
	"reflect"
	"testing"
)

// le16 appends v little-endian.
func le16(b []byte, v uint16) []byte { return append(b, byte(v), byte(v>>8)) }

func msg(typ byte, rest ...uint16) []byte {
	b := []byte{typ}
	for _, v := range rest {
		b = le16(b, v)
	}
	return b
}

func TestDecodeEveryType(t *testing.T) {
	tests := []struct {
		name string
		in   []byte
		want Event
	}{
		{
			name: "pointer down left",
			in:   []byte{TypePointerDown, 0, 0x34, 0x12, 0x78, 0x56, 0, 0},
			want: PointerDown{Button: ButtonLeft, X: 0x1234, Y: 0x5678},
		},
		{
			name: "pointer down middle",
			in:   []byte{TypePointerDown, 2, 0xFF, 0xFF, 0x00, 0x00, 0, 0},
			want: PointerDown{Button: ButtonMiddle, X: 65535, Y: 0},
		},
		{
			name: "pointer move",
			in:   []byte{TypePointerMove, 0b101, 0x01, 0x00, 0x02, 0x00, 0xFE, 0xFF},
			want: PointerMove{Buttons: 0b101, X: 1, Y: 2, Seq: 0xFFFE},
		},
		{
			name: "pointer up right",
			in:   []byte{TypePointerUp, 1, 0x00, 0x80, 0x00, 0x80, 0, 0},
			want: PointerUp{Button: ButtonRight, X: 0x8000, Y: 0x8000},
		},
		{
			name: "key down W with shift+ctrl",
			in:   []byte{TypeKey, 1, 0x57, 0x00, 0x03, 0x00, 0, 0},
			want: Key{Down: true, VK: 0x57, Mods: ModShift | ModCtrl},
		},
		{
			name: "key up, undefined high mods bits masked",
			in:   []byte{TypeKey, 0, 0x1B, 0x00, 0xF8, 0xFF, 0, 0},
			want: Key{Down: false, VK: 0x1B, Mods: 0},
		},
		{
			name: "wheel up",
			in:   []byte{TypeWheel, 0, 0x10, 0x00, 0x20, 0x00, 0x78, 0x00},
			want: Wheel{X: 0x10, Y: 0x20, Delta: 120},
		},
		{
			name: "wheel down negative delta",
			in:   []byte{TypeWheel, 0xEE, 0x00, 0x00, 0x00, 0x00, 0x88, 0xFF},
			want: Wheel{X: 0, Y: 0, Delta: -120},
		},
		{
			name: "release all",
			in:   []byte{TypeReleaseAll, 0},
			want: ReleaseAll{},
		},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got, err := Decode(tt.in)
			if err != nil {
				t.Fatalf("Decode(% x): %v", tt.in, err)
			}
			if !reflect.DeepEqual(got, tt.want) {
				t.Fatalf("Decode(% x) = %#v, want %#v", tt.in, got, tt.want)
			}
		})
	}
}

func TestDecodeRejects(t *testing.T) {
	tests := []struct {
		name string
		in   []byte
	}{
		{"empty", nil},
		{"unknown type", msg(0x07, 0, 0, 0)},
		{"unknown high type", []byte{0xFF, 0}},
		{"pointer down short", []byte{TypePointerDown, 0, 1, 2}},
		{"pointer down long", append(msg(TypePointerDown), make([]byte, 9)...)[:9]},
		{"pointer move short", []byte{TypePointerMove}},
		{"pointer up bad button", []byte{TypePointerUp, 3, 0, 0, 0, 0, 0, 0}},
		{"pointer down bad button", []byte{TypePointerDown, 200, 0, 0, 0, 0, 0, 0}},
		{"key bad down value", []byte{TypeKey, 2, 0x57, 0, 0, 0, 0, 0}},
		{"key short", []byte{TypeKey, 1, 0x57}},
		{"wheel short", []byte{TypeWheel, 0, 1, 2, 3, 4, 5}},
		{"release all wrong length", []byte{TypeReleaseAll}},
		{"release all long", []byte{TypeReleaseAll, 0, 0}},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			_, err := Decode(tt.in)
			if !errors.Is(err, ErrProtocol) {
				t.Fatalf("Decode(% x) err = %v, want ErrProtocol", tt.in, err)
			}
		})
	}
}

func TestSeqNewer(t *testing.T) {
	tests := []struct {
		a, b uint16
		want bool
	}{
		{1, 0, true},
		{0, 1, false},
		{5, 5, false},
		{0, 0xFFFF, true},     // wrap: 0 is one after 65535
		{0xFFFF, 0, false},    // and 65535 is older than 0
		{0x8000, 0, false},    // exactly half the space apart: ambiguous, not newer
		{0x8001, 0, false},    // more than half behind
		{0x7FFF, 0, true},     // just under half ahead
		{10, 0xFFF0, true},    // wrap across zero
		{0xFFF0, 10, false},   // reverse of the above
		{40000, 30000, true},  // plain forward, high range
		{30000, 40000, false}, // plain backward, high range
	}
	for _, tt := range tests {
		if got := SeqNewer(tt.a, tt.b); got != tt.want {
			t.Errorf("SeqNewer(%d, %d) = %v, want %v", tt.a, tt.b, got, tt.want)
		}
	}
}
