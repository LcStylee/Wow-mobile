// Package wininput implements input.Injector with Win32 SendInput, mapping
// the protocol's normalized 0..65535 coordinates onto the WoW window's client
// rectangle. All functionality is Windows-only; this file exists so the
// package remains buildable (empty) on other platforms.
package wininput
