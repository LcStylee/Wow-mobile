//go:build windows

package capture

// Built-in system audio capture: WASAPI shared-mode loopback on the default
// playback device — what you hear on the PC — with no third-party driver
// (the DirectShow "virtual-audio-capturer" path stays available as
// --audio-source dshow). Raw COM through vtables, no cgo: the release build
// is CGO_ENABLED=0.

import (
	"context"
	"fmt"
	"io"
	"runtime"
	"syscall"
	"time"
	"unsafe"

	"golang.org/x/sys/windows"
)

var (
	ole32                = windows.NewLazySystemDLL("ole32.dll")
	procCoCreateInstance = ole32.NewProc("CoCreateInstance")

	clsidMMDeviceEnumerator = windows.GUID{Data1: 0xBCDE0395, Data2: 0xE52F, Data3: 0x467C, Data4: [8]byte{0x8E, 0x3D, 0xC4, 0x57, 0x92, 0x91, 0x69, 0x2E}}
	iidIMMDeviceEnumerator  = windows.GUID{Data1: 0xA95664D2, Data2: 0x9614, Data3: 0x4F35, Data4: [8]byte{0xA7, 0x46, 0xDE, 0x8D, 0xB6, 0x36, 0x17, 0xE6}}
	iidIAudioClient         = windows.GUID{Data1: 0x1CB9AD4C, Data2: 0xDBFA, Data3: 0x4C32, Data4: [8]byte{0xB1, 0x78, 0xC2, 0xF5, 0x68, 0xA7, 0x03, 0xB2}}
	iidIAudioCaptureClient  = windows.GUID{Data1: 0xC8ADBD64, Data2: 0xE71E, Data3: 0x48A0, Data4: [8]byte{0xA4, 0xDE, 0x18, 0x5C, 0x39, 0x5C, 0xD3, 0x17}}
	// KSDATAFORMAT_SUBTYPE_IEEE_FLOAT; PCM differs only in Data1 (1).
	subtypeFloat = windows.GUID{Data1: 0x00000003, Data2: 0x0000, Data3: 0x0010, Data4: [8]byte{0x80, 0x00, 0x00, 0xAA, 0x00, 0x38, 0x9B, 0x71}}
)

const (
	clsctxAll                = 0x17
	eRender                  = 0
	eConsole                 = 0
	audclntSharemodeShared   = 0
	audclntStreamflagsLoop   = 0x00020000
	audclntBufferflagsSilent = 0x2
	waveFormatPCM            = 1
	waveFormatIEEEFloat      = 3
	waveFormatExtensible     = 0xFFFE

	// vtable slots (IUnknown takes 0..2)
	slotRelease                 = 2
	slotGetDefaultAudioEndpoint = 4 // IMMDeviceEnumerator
	slotActivate                = 3 // IMMDevice
	slotInitialize              = 3 // IAudioClient
	slotGetMixFormat            = 8
	slotStart                   = 10
	slotStop                    = 11
	slotGetService              = 14
	slotGetBuffer               = 3 // IAudioCaptureClient
	slotReleaseBuffer           = 4
	slotGetNextPacketSize       = 5
)

type waveFormatEx struct {
	FormatTag      uint16
	Channels       uint16
	SamplesPerSec  uint32
	AvgBytesPerSec uint32
	BlockAlign     uint16
	BitsPerSample  uint16
	CbSize         uint16
}

type waveFormatExtensibleT struct {
	waveFormatEx
	ValidBits   uint16
	ChannelMask uint32
	SubFormat   windows.GUID
}

// comCall invokes vtable slot `slot` of the COM object obj. The directive
// keeps pointers passed as uintptr(unsafe.Pointer(&x)) valid for the call
// (heap-allocates them): the conversion is not written inside the syscall
// expression itself, so without it a stack move could invalidate them.
//
//go:uintptrescapes
func comCall(obj unsafe.Pointer, slot int, args ...uintptr) error {
	vtbl := *(*unsafe.Pointer)(obj)
	fn := *(*uintptr)(unsafe.Add(vtbl, uintptr(slot)*unsafe.Sizeof(uintptr(0))))
	hr, _, _ := syscall.SyscallN(fn, append([]uintptr{uintptr(obj)}, args...)...)
	if int32(hr) < 0 {
		return fmt.Errorf("HRESULT 0x%08X", uint32(hr))
	}
	return nil
}

func comRelease(obj unsafe.Pointer) {
	if obj != nil {
		_ = comCall(obj, slotRelease)
	}
}

// loopbackClient is an activated IAudioClient on the default render device
// plus its mix format (CoTaskMem, freed by close).
type loopbackClient struct {
	enum, device, client unsafe.Pointer
	wfx                  unsafe.Pointer
	format               LoopbackFormat
	blockAlign           int
}

func (c *loopbackClient) close() {
	if c.wfx != nil {
		windows.CoTaskMemFree(c.wfx)
	}
	comRelease(c.client)
	comRelease(c.device)
	comRelease(c.enum)
}

// openLoopback activates the default playback device's audio client and
// reads its mix format. The caller must have initialized COM on this thread.
func openLoopback() (*loopbackClient, error) {
	c := &loopbackClient{}
	hr, _, _ := procCoCreateInstance.Call(
		uintptr(unsafe.Pointer(&clsidMMDeviceEnumerator)), 0, clsctxAll,
		uintptr(unsafe.Pointer(&iidIMMDeviceEnumerator)), uintptr(unsafe.Pointer(&c.enum)))
	if int32(hr) < 0 {
		return nil, fmt.Errorf("creating the audio device enumerator: HRESULT 0x%08X", uint32(hr))
	}
	if err := comCall(c.enum, slotGetDefaultAudioEndpoint, eRender, eConsole, uintptr(unsafe.Pointer(&c.device))); err != nil {
		c.close()
		return nil, fmt.Errorf("no default playback device: %w", err)
	}
	if err := comCall(c.device, slotActivate, uintptr(unsafe.Pointer(&iidIAudioClient)), clsctxAll, 0, uintptr(unsafe.Pointer(&c.client))); err != nil {
		c.close()
		return nil, fmt.Errorf("activating the audio client: %w", err)
	}
	if err := comCall(c.client, slotGetMixFormat, uintptr(unsafe.Pointer(&c.wfx))); err != nil {
		c.close()
		return nil, fmt.Errorf("reading the mix format: %w", err)
	}
	wf := (*waveFormatEx)(c.wfx)
	isFloat := wf.FormatTag == waveFormatIEEEFloat
	if wf.FormatTag == waveFormatExtensible && wf.CbSize >= 22 {
		ext := (*waveFormatExtensibleT)(c.wfx)
		isFloat = ext.SubFormat == subtypeFloat
	}
	sampleFmt := ""
	switch {
	case isFloat && wf.BitsPerSample == 32:
		sampleFmt = "f32le"
	case isFloat && wf.BitsPerSample == 64:
		sampleFmt = "f64le"
	case !isFloat && wf.BitsPerSample == 16:
		sampleFmt = "s16le"
	case !isFloat && wf.BitsPerSample == 24:
		sampleFmt = "s24le"
	case !isFloat && wf.BitsPerSample == 32:
		sampleFmt = "s32le"
	default:
		c.close()
		return nil, fmt.Errorf("unsupported mix format: tag %#x, %d bits", wf.FormatTag, wf.BitsPerSample)
	}
	c.format = LoopbackFormat{SampleFmt: sampleFmt, Rate: int(wf.SamplesPerSec), Channels: int(wf.Channels)}
	c.blockAlign = int(wf.BlockAlign)
	return c, nil
}

// withCOM runs fn on a locked OS thread with COM initialized (MTA).
func withCOM(fn func() error) error {
	runtime.LockOSThread()
	defer runtime.UnlockOSThread()
	switch err := windows.CoInitializeEx(0, windows.COINIT_MULTITHREADED); err {
	case nil, syscall.Errno(1): // S_OK, S_FALSE (already initialized): balance it
		defer windows.CoUninitialize()
	case syscall.Errno(windows.RPC_E_CHANGED_MODE):
		// Initialized in another mode on this thread: still usable, not ours.
	default:
		return fmt.Errorf("CoInitializeEx: %w", err)
	}
	return fn()
}

// ProbeLoopback reports the default playback device's mix format — the raw
// PCM layout StreamLoopback will write.
func ProbeLoopback() (LoopbackFormat, error) {
	var f LoopbackFormat
	err := withCOM(func() error {
		c, err := openLoopback()
		if err != nil {
			return err
		}
		defer c.close()
		f = c.format
		return nil
	})
	return f, err
}

// StreamLoopback captures what the PC plays and writes it to w as raw PCM in
// the device mix format, until ctx ends or capture fails (device unplugged
// or switched: the supervisor restarts the pipeline, which re-probes the new
// default device). want is the format the ffmpeg reading w was started for;
// a mismatch (device changed between probe and start) is an error so the
// restart picks the new one up. Silence is padded in while nothing plays.
func StreamLoopback(ctx context.Context, w io.Writer, want LoopbackFormat) error {
	return withCOM(func() error {
		c, err := openLoopback()
		if err != nil {
			return err
		}
		defer c.close()
		if c.format != want {
			return fmt.Errorf("playback device format changed (%+v, ffmpeg expects %+v)", c.format, want)
		}
		const bufferHns = 2_000_000 // 200 ms shared buffer, in 100 ns units
		if err := comCall(c.client, slotInitialize, audclntSharemodeShared, audclntStreamflagsLoop, bufferHns, 0, uintptr(c.wfx), 0); err != nil {
			return fmt.Errorf("initializing loopback capture: %w", err)
		}
		var capture unsafe.Pointer
		if err := comCall(c.client, slotGetService, uintptr(unsafe.Pointer(&iidIAudioCaptureClient)), uintptr(unsafe.Pointer(&capture))); err != nil {
			return fmt.Errorf("getting the capture service: %w", err)
		}
		defer comRelease(capture)
		if err := comCall(c.client, slotStart); err != nil {
			return fmt.Errorf("starting loopback capture: %w", err)
		}
		defer comCall(c.client, slotStop) //nolint:errcheck

		rate := int64(c.format.Rate)
		slack := rate / 20 // 50 ms of tolerated lag before silence is padded
		start := time.Now()
		var written int64
		silence := make([]byte, 0)
		tick := time.NewTicker(10 * time.Millisecond)
		defer tick.Stop()
		for {
			select {
			case <-ctx.Done():
				return nil
			case <-tick.C:
			}
			for {
				var packet uint32
				if err := comCall(capture, slotGetNextPacketSize, uintptr(unsafe.Pointer(&packet))); err != nil {
					return fmt.Errorf("loopback capture: %w", err)
				}
				if packet == 0 {
					break
				}
				var data unsafe.Pointer
				var frames, flags uint32
				if err := comCall(capture, slotGetBuffer, uintptr(unsafe.Pointer(&data)), uintptr(unsafe.Pointer(&frames)), uintptr(unsafe.Pointer(&flags)), 0, 0); err != nil {
					return fmt.Errorf("loopback capture: %w", err)
				}
				n := int(frames) * c.blockAlign
				var werr error
				if flags&audclntBufferflagsSilent != 0 || data == nil {
					if cap(silence) < n {
						silence = make([]byte, n)
					}
					_, werr = w.Write(silence[:n])
				} else {
					_, werr = w.Write(unsafe.Slice((*byte)(data), n))
				}
				if err := comCall(capture, slotReleaseBuffer, uintptr(frames)); err != nil {
					return fmt.Errorf("loopback capture: %w", err)
				}
				if werr != nil {
					return werr
				}
				written += int64(frames)
			}
			expected := int64(time.Since(start).Seconds() * float64(rate))
			if pad := silenceFill(written, expected, slack); pad > 0 {
				n := int(pad) * c.blockAlign
				if cap(silence) < n {
					silence = make([]byte, n)
				}
				if _, err := w.Write(silence[:n]); err != nil {
					return err
				}
				written += pad
			}
		}
	})
}
