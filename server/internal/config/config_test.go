package config

import (
	"io"
	"strings"
	"testing"
)

func TestParseDefaults(t *testing.T) {
	cfg, err := Parse(nil, io.Discard)
	if err != nil {
		t.Fatal(err)
	}
	if cfg.Addr != ":8443" || cfg.Width != 1080 || cfg.Height != 1920 ||
		cfg.FPS != 60 || cfg.BitrateKbps != 8000 || cfg.Encoder != EncoderAuto ||
		cfg.WindowTitle != "World of Warcraft" || cfg.NoTLS || cfg.Audio || cfg.Setup {
		t.Fatalf("unexpected defaults: %+v", cfg)
	}
	if !cfg.TokenIsGenerated || len(cfg.Token) != 32 {
		t.Fatalf("expected generated 32-hex-char token, got %q", cfg.Token)
	}
	cfg2, err := Parse(nil, io.Discard)
	if err != nil {
		t.Fatal(err)
	}
	if cfg2.Token == cfg.Token {
		t.Fatal("generated tokens must be unique per run")
	}
}

func TestParseExplicit(t *testing.T) {
	cfg, err := Parse(strings.Fields(
		"--addr :9000 --token secret --resolution 720x1280 --fps 30 --bitrate-kbps 4000 --encoder x264 --no-tls --audio"),
		io.Discard)
	if err != nil {
		t.Fatal(err)
	}
	if cfg.Addr != ":9000" || cfg.Token != "secret" || cfg.TokenIsGenerated ||
		cfg.Width != 720 || cfg.Height != 1280 || cfg.FPS != 30 ||
		cfg.BitrateKbps != 4000 || cfg.Encoder != EncoderX264 || !cfg.NoTLS || !cfg.Audio {
		t.Fatalf("unexpected parse: %+v", cfg)
	}
}

func TestParseRejects(t *testing.T) {
	bad := [][]string{
		{"--resolution", "1080"},
		{"--resolution", "0x0"},
		{"--resolution", "1081x1920"}, // odd width
		{"--resolution", "axb"},
		{"--fps", "0"},
		{"--fps", "1000"},
		{"--bitrate-kbps", "10"},
		{"--encoder", "vp9"},
		{"--window-title", ""},
		{"positional"},
	}
	for _, args := range bad {
		if _, err := Parse(args, io.Discard); err == nil {
			t.Errorf("Parse(%v) accepted invalid input", args)
		}
	}
}
