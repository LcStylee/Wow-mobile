// Package winui wraps the small set of native Windows UI primitives
// wowstreamd's GUI mode needs: message boxes, the folder browser, the
// open-file dialog, ShellExecute ("open a URL in the default browser"), and a
// notification-area (tray) icon with its own message loop.
//
// Everything is pure syscall via golang.org/x/sys/windows — no cgo, no UI
// framework. All functionality is Windows-only (build-tagged); this file
// exists so the package remains buildable (empty) on other platforms, where
// wowstreamd only runs in console mode anyway.
package winui
