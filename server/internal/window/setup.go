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
// the exact Config.wtf lines for the resolved layout and where the WowMobile
// addon goes. band selects the band-layout instructions (native landscape
// window, no portrait sizing — the default for 1.12-engine clients, which
// reject portrait render resolutions outright); otherwise the classic
// portrait-window instructions are printed, sized to width x height. Paths
// assume the layout's usual client (a private-server directory for band, a
// default Classic Era install for portrait); the wizard writes equivalent
// settings automatically, per client type (install.BandSettingsFor /
// PortraitSettingsFor are the source of truth these instructions mirror).
func PrintSetup(w io.Writer, width, height int, band bool) {
	if band {
		fmt.Fprint(w, `wowstreamd setup — configure WoW for band streaming (native landscape window)

Band layout keeps the game's normal LANDSCAPE window and streams the centered
9:16 portrait band cropped out of it. The window is never forced portrait —
there is no capture resolution to match; the server recomputes the band from
the live window and follows resizes automatically.

1. Quit WoW completely (Config.wtf is rewritten on exit).

2. Edit  <your game directory>\WTF\Config.wtf  (for a 1.12-era private-server
   client that is the folder holding Wow.exe, e.g. C:\Games\TurtleWoW) and
   add (or replace) these lines:

     SET gxWindow "1"
     SET gxResolution "<your desktop resolution, e.g. 1920x1080>"
     SET checkAddonVersion "0"

   Do NOT set a portrait resolution like 1080x1920: 1.12-engine clients
   reject portrait render resolutions and stretch instead. gxResolution set
   to the desktop resolution keeps a native landscape window every client
   accepts, and the server streams its centered 9:16 band whatever size the
   window ends up — a maximized window is fine too, so leave any gxMaximize
   line you already have alone. Do NOT add gxWindowedResolution: custom
   builds that honor it would pin a window too large to fit above the
   taskbar. checkAddonVersion "0" = "Load out of date AddOns", so a game
   patch never silently disables the addon.

   (On a Classic Era client with band layout the wizard writes gxMaximize
   "1" and no resolution CVar at all instead — a maximized window is already
   native landscape at full size.)

3. Install the WowMobile addon (portrait touch UI). The first-run wizard does
   this automatically — rerun wowstreamd without --skip-setup. From a source
   checkout you can instead copy the repo's addon/WowMobile_Vanilla directory
   (the 1.12 port — band's usual client) to:

     <your game directory>\Interface\AddOns\WowMobile_Vanilla

   (Classic Era uses the addon/WowMobile directory copied to
   Interface\AddOns\WowMobile instead; the wizard picks the right variant.)

4. Launch WoW, log in, and enable "WoW Mobile (Vanilla)" ("WoW Mobile" on
   Classic Era) on the AddOns screen of the character select if it is not
   already checked.

5. Run wowstreamd and open the printed URL on your phone.
`)
		return
	}
	fmt.Fprintf(w, `wowstreamd setup — configure WoW Classic Era for portrait streaming

1. Quit WoW completely (Config.wtf is rewritten on exit).

2. Edit  C:\Program Files (x86)\World of Warcraft\_classic_era_\WTF\Config.wtf
   and add (or replace) these lines:

     SET gxWindow "1"
     SET gxMaximize "0"
     SET gxWindowedResolution "%dx%d"
     SET checkAddonVersion "0"

   %dx%d must equal wowstreamd's capture resolution so touch coordinates map
   1:1 — the default --resolution fit computed it as the largest 9:16 window
   fitting your primary monitor, capped at the 1080x1920 design size (a
   window taller than the monitor cannot be captured; one larger than the
   design size only costs encode time for pixels the phone downscales).
   checkAddonVersion "0" = "Load out of date AddOns", so a game patch never
   silently disables the addon.
   (1.12-era private-server clients run BAND layout by default instead — the
   game keeps a native LANDSCAPE window and the server streams its centered
   9:16 band, with no portrait sizing at all; run
   wowstreamd --setup --layout band for those instructions. The wizard
   writes the right settings for either mode, and --layout band|portrait
   overrides the default.)

3. Install the WowMobile addon (portrait touch UI). The first-run wizard does
   this automatically — rerun wowstreamd without --skip-setup. From a source
   checkout you can instead copy the repo's addon/WowMobile directory to:

     C:\Program Files (x86)\World of Warcraft\_classic_era_\Interface\AddOns\WowMobile

   (1.12-era private-server clients use the addon/WowMobile_Vanilla directory
   — the 1.12 port — copied to Interface\AddOns\WowMobile_Vanilla instead;
   the wizard picks the right variant.)

4. Launch WoW, log in, and enable "WoW Mobile" ("WoW Mobile (Vanilla)" on a
   1.12 client) on the AddOns screen of the character select if it is not
   already checked.

5. Run wowstreamd and open the printed URL on your phone.
`, width, height, width, height)
}
