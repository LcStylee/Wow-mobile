// Package embedded carries the phone client PWA and both WowMobile addon
// variants inside the wowstreamd binary, so a single downloaded .exe is the
// whole distribution: the signaling server serves the client from ClientFS
// and the first-run wizard installs the addon matching the detected client
// from AddonFS (Classic Era) or VanillaAddonFS (1.12 private servers).
//
// This file must live at the repository root: go:embed cannot climb out of
// its own package directory, and client/ and addon/ deliberately stay where
// they are — they remain the canonical, unmoved sources. A drift-guard test
// (embed_test.go) asserts the embedded trees match the on-disk trees
// byte-for-byte (minus the dev-only client files excluded below).
package embedded

import "embed"

// ClientFS holds the phone client PWA under the "client/" prefix. The signal
// server strips the prefix with fs.Sub before serving.
//
// The embed is deliberately scoped to the files the PWA needs — NOT
// all:client — because http.FileServerFS serves everything in the FS:
// embedding the whole directory would ship and publicly serve the dev-only
// client/tests/ and client/package.json from every released binary. The
// drift-guard test asserts those stay out.
//
//go:embed client/index.html client/styles.css client/sw.js
//go:embed client/manifest.webmanifest all:client/js all:client/icons
//go:embed all:client/vendor
var ClientFS embed.FS

// HostFS holds the loopback-only host dashboard under the "client/host/"
// prefix. It is deliberately a SEPARATE embed from ClientFS: ClientFS is
// served publicly at "/" to any LAN device, while the dashboard (which
// displays the pairing token and offers a quit control) must only ever be
// reachable through the signal server's loopback-guarded /host routes.
//
//go:embed all:client/host
var HostFS embed.FS

// AddonFS holds the Classic Era (1.15) WoW addon under the "addon/WowMobile/"
// prefix. The installer strips the prefix with fs.Sub before copying files
// into <wow>\Interface\AddOns\WowMobile.
//
//go:embed all:addon/WowMobile
var AddonFS embed.FS

// VanillaAddonFS holds the 1.12 (Lua 5.0) port of the addon under the
// "addon/WowMobile_Vanilla/" prefix. The wizard installs it instead of the
// Classic Era addon when the located client is a 1.12-era private-server
// client, into <wow>\Interface\AddOns\WowMobile_Vanilla.
//
//go:embed all:addon/WowMobile_Vanilla
var VanillaAddonFS embed.FS
