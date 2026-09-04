// Package wininput implements input.Injector with Win32 SendInput, mapping
// the protocol's normalized 0..65535 coordinates onto the WoW window's client
// rectangle — or, under the band contract (docs/ARCHITECTURE.md), onto the
// centered 9:16 band inside a landscape window. The injection itself is
// Windows-only; the coordinate mapping (mapping.go) is portable and shared
// with the --capture test log injector so it is unit-tested on every OS.
package wininput
