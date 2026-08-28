// Persisted wizard state: config.json in the same per-user directory that
// already holds the TLS key pair (%APPDATA%\wowstreamd on Windows, the
// os.UserConfigDir equivalent elsewhere). The file is read into a raw map so
// keys this version does not know about survive a load/save round trip —
// future versions can extend the file without breaking older ones.
package install

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
)

// Persisted config.json keys.
const (
	// KeyWowPath is the pre-game_exe key (a validated _classic_era_
	// directory). Still read for migration — an existing install upgrades
	// without re-detecting — but no longer written.
	KeyWowPath    = "wow_path"
	KeyFFmpegPath = "ffmpeg_path" // located ffmpeg.exe (e.g. after winget install)
	// KeyGameExe is the recorded game executable; every later wizard step
	// (addon dir, Config.wtf, launch) derives from its directory.
	KeyGameExe = "game_exe"
	// KeyClientType caches the answer to "Classic Era or 1.12?" for the
	// recorded game exe ("classicEra"/"legacy"); only trusted while it still
	// matches KeyGameExe, so switching installs re-detects.
	KeyClientType = "client_type"
	// KeyLegacyNoticeShown records that the one-time "addon not installed on
	// 1.12 clients" GUI notice was already shown (the dashboard note and the
	// console print repeat every run; the modal dialog must not).
	KeyLegacyNoticeShown = "legacy_addon_notice_shown"
)

// StoreFileName is the persisted settings file inside the wowstreamd config
// directory.
const StoreFileName = "config.json"

// Store is the persisted key/value state. Zero value is unusable; call
// LoadStore.
type Store struct {
	path string
	raw  map[string]json.RawMessage
}

// LoadStore reads dir/config.json. A missing or unreadable/corrupt file
// yields an empty store (the wizard re-detects and re-persists) — first runs
// must not fail on absent state.
func LoadStore(dir string) *Store {
	s := &Store{
		path: filepath.Join(dir, StoreFileName),
		raw:  map[string]json.RawMessage{},
	}
	data, err := os.ReadFile(s.path)
	if err != nil {
		return s
	}
	var raw map[string]json.RawMessage
	if err := json.Unmarshal(data, &raw); err != nil {
		return s
	}
	s.raw = raw
	return s
}

// Get returns the string value for key, or "" when absent or not a string.
func (s *Store) Get(key string) string {
	var v string
	if raw, ok := s.raw[key]; ok && json.Unmarshal(raw, &v) == nil {
		return v
	}
	return ""
}

// Set stores a string value for key (in memory; Save persists).
func (s *Store) Set(key, value string) {
	raw, err := json.Marshal(value)
	if err != nil {
		return // cannot happen for a string
	}
	s.raw[key] = raw
}

// Save writes the store back to disk, creating the directory if needed.
// Unknown keys read by LoadStore are written back untouched.
func (s *Store) Save() error {
	if err := os.MkdirAll(filepath.Dir(s.path), 0o700); err != nil {
		return err
	}
	data, err := json.MarshalIndent(s.raw, "", "  ")
	if err != nil {
		return err
	}
	if err := os.WriteFile(s.path, append(data, '\n'), 0o600); err != nil {
		return fmt.Errorf("persisting %s: %w", s.path, err)
	}
	return nil
}
