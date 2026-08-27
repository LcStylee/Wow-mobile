// Package window locates and tracks the WoW game window. The Win32 half is
// build-tagged; this file is portable so --setup works everywhere.
package window

import (
	"fmt"
	"io"
)

// Rect is a window client rectangle in virtual-desktop screen coordinates.
type Rect struct {
	X, Y int // screen position of the client area's top-left corner
	W, H int // client area size in pixels
}

// PrintSetup writes the one-time WoW configuration instructions for --setup:
// the exact Config.wtf lines for the portrait window and where the WowMobile
// addon goes. Paths assume a default Classic Era install; the drive letter is
// the only part that commonly differs.
func PrintSetup(w io.Writer, width, height int) {
	fmt.Fprintf(w, `wowstreamd setup — configure WoW Classic Era for portrait streaming

1. Quit WoW completely (Config.wtf is rewritten on exit).

2. Edit  C:\Program Files (x86)\World of Warcraft\_classic_era_\WTF\Config.wtf
   and add (or replace) these lines:

     SET gxWindow "1"
     SET gxMaximize "0"
     SET gxWindowedResolution "%dx%d"

   %dx%d must equal wowstreamd's --resolution so touch coordinates map 1:1.

3. Install the WowMobile addon (portrait touch UI). The first-run wizard does
   this automatically — rerun wowstreamd without --skip-setup. From a source
   checkout you can instead copy the repo's addon/WowMobile directory to:

     C:\Program Files (x86)\World of Warcraft\_classic_era_\Interface\AddOns\WowMobile

4. Launch WoW, log in, and enable "WoW Mobile" on the AddOns screen of the
   character select if it is not already checked.

5. Run wowstreamd and open the printed URL on your phone.
`, width, height, width, height)
}
