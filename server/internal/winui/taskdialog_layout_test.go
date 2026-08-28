package winui

import (
	"encoding/binary"
	"testing"
)

// The packed TASKDIALOGCONFIG offsets must tile the struct exactly: pack(1)
// means zero padding, so each field starts where the previous one ends and
// the last one ends at cbSize. A hole or overlap here is the exact class of
// bug the manual packing exists to prevent.
func TestTaskDialogConfigOffsetsTile(t *testing.T) {
	fields := []struct {
		name string
		off  int
		size int
	}{
		{"cbSize", tdcOffCbSize, 4},
		{"hwndParent", tdcOffHwndParent, 8},
		{"hInstance", tdcOffHInstance, 8},
		{"dwFlags", tdcOffFlags, 4},
		{"dwCommonButtons", tdcOffCommonButtons, 4},
		{"pszWindowTitle", tdcOffWindowTitle, 8},
		{"hMainIcon/pszMainIcon", tdcOffMainIcon, 8},
		{"pszMainInstruction", tdcOffMainInstruction, 8},
		{"pszContent", tdcOffContent, 8},
		{"cButtons", tdcOffCButtons, 4},
		{"pButtons", tdcOffPButtons, 8},
		{"nDefaultButton", tdcOffDefaultButton, 4},
		{"cRadioButtons", tdcOffCRadioButtons, 4},
		{"pRadioButtons", tdcOffPRadioButtons, 8},
		{"nDefaultRadioButton", tdcOffDefaultRadioButton, 4},
		{"pszVerificationText", tdcOffVerificationText, 8},
		{"pszExpandedInformation", tdcOffExpandedInformation, 8},
		{"pszExpandedControlText", tdcOffExpandedControlText, 8},
		{"pszCollapsedControlText", tdcOffCollapsedControlText, 8},
		{"hFooterIcon/pszFooterIcon", tdcOffFooterIcon, 8},
		{"pszFooter", tdcOffFooter, 8},
		{"pfCallback", tdcOffCallback, 8},
		{"lpCallbackData", tdcOffCallbackData, 8},
		{"cxWidth", tdcOffCxWidth, 4},
	}
	next := 0
	for _, f := range fields {
		if f.off != next {
			t.Errorf("%s: offset %d, want %d (pack(1): no padding before any field)", f.name, f.off, next)
		}
		next = f.off + f.size
	}
	if next != tdcSize {
		t.Errorf("fields end at %d, but tdcSize (cbSize) is %d", next, tdcSize)
	}

	// TASKDIALOG_BUTTON: 4-byte id immediately followed by the 8-byte PCWSTR
	// — 12-byte stride, not the 16 a naturally aligned struct would take.
	if tdBtnOffID != 0 || tdBtnOffText != 4 || tdBtnStride != 12 {
		t.Errorf("TASKDIALOG_BUTTON layout wrong: id@%d text@%d stride %d", tdBtnOffID, tdBtnOffText, tdBtnStride)
	}
}

// packTaskDialogConfig places every value at its documented offset, sets
// cbSize, and leaves all unset fields zero.
func TestPackTaskDialogConfig(t *testing.T) {
	v := tdcValues{
		flags:           tdfUseCommandLinks | tdfAllowDialogCancellation,
		commonButtons:   tdcbfCancelButton,
		windowTitle:     0x1111_2222_3333_4444,
		mainInstruction: 0x5555_6666_7777_8888,
		content:         0x9999_AAAA_BBBB_CCCC,
		buttonCount:     5,
		buttonsPtr:      0xDDDD_EEEE_0000_FFFF,
		defaultButton:   1000,
	}
	buf := packTaskDialogConfig(v)
	if len(buf) != tdcSize {
		t.Fatalf("buffer size %d, want %d", len(buf), tdcSize)
	}
	u32 := func(off int) uint32 { return binary.LittleEndian.Uint32(buf[off:]) }
	u64 := func(off int) uint64 { return binary.LittleEndian.Uint64(buf[off:]) }

	if u32(tdcOffCbSize) != tdcSize {
		t.Errorf("cbSize = %d, want %d", u32(tdcOffCbSize), tdcSize)
	}
	if u32(tdcOffFlags) != v.flags || u32(tdcOffCommonButtons) != v.commonButtons {
		t.Error("flags/common buttons misplaced")
	}
	if u64(tdcOffWindowTitle) != v.windowTitle ||
		u64(tdcOffMainInstruction) != v.mainInstruction ||
		u64(tdcOffContent) != v.content {
		t.Error("string pointers misplaced")
	}
	if u32(tdcOffCButtons) != v.buttonCount || u64(tdcOffPButtons) != v.buttonsPtr {
		t.Error("button array fields misplaced")
	}
	if int32(u32(tdcOffDefaultButton)) != v.defaultButton {
		t.Error("default button misplaced")
	}
	// Everything not explicitly set must be zero ("none"): check the widest
	// unset fields, including both unions.
	for _, off := range []int{tdcOffHwndParent, tdcOffHInstance, tdcOffMainIcon,
		tdcOffCRadioButtons, tdcOffPRadioButtons, tdcOffVerificationText,
		tdcOffFooterIcon, tdcOffFooter, tdcOffCallback, tdcOffCallbackData} {
		if u32(off) != 0 {
			t.Errorf("unset field at offset %d not zero", off)
		}
	}
	if u32(tdcOffCxWidth) != 0 {
		t.Error("cxWidth must stay 0 (auto width)")
	}
}

// packTaskDialogButtons interleaves ids and text pointers at the packed
// 12-byte stride.
func TestPackTaskDialogButtons(t *testing.T) {
	ids := []int32{1000, 1001, 1900}
	texts := []uint64{0xAAAA_0001, 0xBBBB_0002, 0xCCCC_0003}
	buf := packTaskDialogButtons(ids, texts)
	if len(buf) != len(ids)*tdBtnStride {
		t.Fatalf("buffer size %d, want %d", len(buf), len(ids)*tdBtnStride)
	}
	for i := range ids {
		off := i * tdBtnStride
		if got := int32(binary.LittleEndian.Uint32(buf[off+tdBtnOffID:])); got != ids[i] {
			t.Errorf("button %d id = %d, want %d", i, got, ids[i])
		}
		if got := binary.LittleEndian.Uint64(buf[off+tdBtnOffText:]); got != texts[i] {
			t.Errorf("button %d text ptr = %#x, want %#x", i, got, texts[i])
		}
	}
}
