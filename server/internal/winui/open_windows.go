//go:build windows

package winui

import "golang.org/x/sys/windows"

// OpenURL opens url in the user's default browser via ShellExecuteW "open".
// Best-effort: the dashboard URL is also in the tray menu and (console mode)
// the banner, so a failure here is recoverable by the user.
func OpenURL(url string) error {
	return windows.ShellExecute(0, utf16Ptr("open"), utf16Ptr(url), nil, nil, windows.SW_SHOWNORMAL)
}
