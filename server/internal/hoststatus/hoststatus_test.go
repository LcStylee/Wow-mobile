package hoststatus

import (
	"encoding/json"
	"testing"
)

// The status JSON shape is a contract with client/host/host.js — this test
// pins field names and the step lifecycle.
func TestJSONShape(t *testing.T) {
	s := New("v1.2.3",
		Step{ID: "game", Label: "World of Warcraft"},
		Step{ID: "ffmpeg", Label: "FFmpeg"},
	)
	s.SetStep("game", StateOK, `found: C:\wow\WowClassic.exe`)
	s.SetStep("ffmpeg", StateRunning, "installing FFmpeg via winget…")
	s.SetStep("nonexistent", StateOK, "ignored") // unknown ids never panic
	s.SetEncoder("h264_nvenc")
	s.SetResolution("590x1048")
	s.SetClientType("classicEra")
	s.SetPairingURL("https://192.168.1.20:8443/?token=abc")
	s.SetRunning(true)
	s.SetPhoneInfo("192.168.1.30:51234", "Safari")
	s.SetConnectedFunc(func() bool { return true })
	s.SetStatsFunc(func() Stream {
		return Stream{Kbps: 8000, FPS: 59.9, EncodeMs: 4.2,
			FramesCaptured: 1200, FramesSent: 1199, LastKeyframeAgeMs: 350}
	})

	var got struct {
		Version    string `json:"version"`
		Running    bool   `json:"running"`
		Steps      []Step `json:"steps"`
		Encoder    string `json:"encoder"`
		Resolution string `json:"resolution"`
		ClientType string `json:"clientType"`
		AddonNote  string `json:"addonNote"`
		PairingURL string `json:"pairingUrl"`
		Phone      Phone  `json:"phone"`
		Stream     Stream `json:"stream"`
	}
	if err := json.Unmarshal(s.JSON(), &got); err != nil {
		t.Fatalf("status JSON invalid: %v", err)
	}
	if got.Version != "v1.2.3" || !got.Running || got.Encoder != "h264_nvenc" ||
		got.Resolution != "590x1048" || got.ClientType != "classicEra" {
		t.Fatalf("scalar fields wrong: %+v", got)
	}
	if len(got.Steps) != 2 || got.Steps[0].ID != "game" || got.Steps[0].State != StateOK ||
		got.Steps[1].State != StateRunning {
		t.Fatalf("steps wrong: %+v", got.Steps)
	}
	if !got.Phone.Connected || got.Phone.Remote != "192.168.1.30:51234" || got.Phone.UserAgent != "Safari" {
		t.Fatalf("phone wrong: %+v", got.Phone)
	}
	if got.Stream.Kbps != 8000 || got.Stream.FPS != 59.9 || got.Stream.EncodeMs != 4.2 ||
		got.Stream.FramesCaptured != 1200 || got.Stream.FramesSent != 1199 ||
		got.Stream.LastKeyframeAgeMs != 350 {
		t.Fatalf("stream wrong: %+v", got.Stream)
	}
	if got.PairingURL != "https://192.168.1.20:8443/?token=abc" {
		t.Fatalf("pairingUrl wrong: %q", got.PairingURL)
	}
}

// Stats are only reported while a phone is connected — a dashboard open with
// no phone must show zeros, not stale rates.
func TestStatsOnlyWhenConnected(t *testing.T) {
	s := New("dev")
	s.SetConnectedFunc(func() bool { return false })
	s.SetStatsFunc(func() Stream { t.Fatal("stats probed while disconnected"); return Stream{} })
	var got struct {
		Stream Stream `json:"stream"`
	}
	if err := json.Unmarshal(s.JSON(), &got); err != nil {
		t.Fatal(err)
	}
	if got.Stream != (Stream{}) {
		t.Fatalf("expected zero stream, got %+v", got.Stream)
	}
}

// A nil *Status is a valid no-op receiver: the wizard runs identically with
// no dashboard attached.
func TestNilReceiverSafe(t *testing.T) {
	var s *Status
	s.SetStep("x", StateOK, "")
	s.SetEncoder("e")
	s.SetResolution("1080x1920")
	s.SetClientType("legacy")
	s.SetAddonNote("n")
	s.SetPairingURL("u")
	s.SetRunning(true)
	s.SetPhoneInfo("r", "ua")
	s.SetConnectedFunc(nil)
	s.SetStatsFunc(nil)
	if s.PairingURL() != "" {
		t.Fatal("nil PairingURL must be empty")
	}
	if string(s.JSON()) != "{}" {
		t.Fatalf("nil JSON: %s", s.JSON())
	}
}
