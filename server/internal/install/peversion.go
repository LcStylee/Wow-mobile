// PE version-stamp probing: the strongest client-type signal is the
// FileVersion Windows stamps into the game executable's version resource
// (official 1.12.1 clients carry 1.12.1.5875, Classic Era carries 1.15.x),
// which survives arbitrary renames private-server launchers are fond of.
// debug/pe is portable, so the probe and its parsing are unit-tested on
// every OS against synthetic resource bytes.
package install

import (
	"debug/pe"
	"encoding/binary"
)

// fixedFileInfoSignature marks the VS_FIXEDFILEINFO struct inside an
// RT_VERSION resource.
const fixedFileInfoSignature = 0xFEEF04BD

// GameVersion is the file version stamped into the game executable.
type GameVersion struct {
	Major, Minor uint16
}

// PEFileVersion reads the FileVersion from a Windows executable. It scans the
// .rsrc section for the VS_FIXEDFILEINFO signature instead of walking the
// resource directory tree: the struct's layout and DWORD alignment are
// contractual (verinfo.h), the signature cannot appear in the tree's metadata
// by construction, and the scan needs no offset bookkeeping across the
// directory/data-entry indirections. ok is false for a non-PE file, a PE
// without resources, or a stripped version resource — callers fall back to
// name/path heuristics.
func PEFileVersion(path string) (GameVersion, bool) {
	f, err := pe.Open(path)
	if err != nil {
		return GameVersion{}, false
	}
	defer f.Close()
	sec := f.Section(".rsrc")
	if sec == nil {
		return GameVersion{}, false
	}
	data, err := sec.Data()
	if err != nil {
		return GameVersion{}, false
	}
	return fixedFileVersion(data)
}

// fixedFileVersion scans raw resource bytes for VS_FIXEDFILEINFO. Layout from
// the signature: dwSignature, dwStrucVersion, dwFileVersionMS (HIWORD major,
// LOWORD minor), dwFileVersionLS — so 16 bytes must remain at a match.
func fixedFileVersion(data []byte) (GameVersion, bool) {
	// The struct is embedded DWORD-aligned in the resource data.
	for i := 0; i+16 <= len(data); i += 4 {
		if binary.LittleEndian.Uint32(data[i:]) != fixedFileInfoSignature {
			continue
		}
		ms := binary.LittleEndian.Uint32(data[i+8:])
		return GameVersion{Major: uint16(ms >> 16), Minor: uint16(ms)}, true
	}
	return GameVersion{}, false
}

// ClientTypeFromVersion maps a stamped version to a client type: 1.13+ is the
// Classic(-Era) lineage, 1.0–1.12 the vanilla client. Other majors (2.x/3.x
// private clients, or a launcher's own version stamp outside those ranges)
// are not classified — the name/path heuristics and, finally, the user
// decide. Note this still classifies VanillaFixes.exe correctly by accident
// AND by design: its own version stamps are 1.x < 1.13, and its name is in
// the legacy heuristic table anyway.
func ClientTypeFromVersion(v GameVersion) (ClientType, bool) {
	if v.Major != 1 {
		return "", false
	}
	if v.Minor >= 13 {
		return ClientTypeClassicEra, true
	}
	return ClientTypeLegacy, true
}
