// Package embedded carries the phone client PWA and the WowMobile addon
// inside the wowstreamd binary, so a single downloaded .exe is the whole
// distribution: the signaling server serves the client from ClientFS and the
// first-run wizard installs the addon from AddonFS.
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
var ClientFS embed.FS

// AddonFS holds the WoW addon under the "addon/WowMobile/" prefix. The
// installer strips the prefix with fs.Sub before copying files into
// <wow>\Interface\AddOns\WowMobile.
//
//go:embed all:addon/WowMobile
var AddonFS embed.FS
