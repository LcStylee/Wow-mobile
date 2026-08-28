// Windows resources for wowstreamd.exe. The checked-in
// rsrc_windows_amd64.syso in this directory carries the app icon
// (assets/wowmobile.ico) and the application manifest (wowstreamd.manifest:
// Common Controls v6 + per-monitor-v2 DPI awareness). rsrc assigns resource
// ids manifest-first regardless of flag order, so in this .syso the
// RT_MANIFEST is id 1 and the RT_GROUP_ICON is id 2 (RT_ICON frames 3-6);
// the tray (winui.appIcon) therefore scans a small id range for the group
// icon instead of assuming id 1.
// The GOOS/GOARCH suffix in the filename makes the Go linker include it only
// for windows/amd64 builds, so Linux CI and tests are untouched and no build
// step is needed anywhere.
//
// Regenerate after changing the icon or the manifest (rsrc is a go.mod tool
// dependency; run from the repo root):
//
//	python3 assets/gen_icon.py   # only if the artwork changed
//	go tool rsrc -manifest server/cmd/wowstreamd/wowstreamd.manifest \
//	    -ico assets/wowmobile.ico -arch amd64 \
//	    -o server/cmd/wowstreamd/rsrc_windows_amd64.syso
//
// and commit the regenerated .syso.
package main
