// QR rendering shared by the console banner (ASCII half-blocks) and the host
// dashboard (an SVG image at GET /host/qr.svg). Both draw the same module
// matrix from the same library, so a code that scans in the terminal scans on
// the dashboard.
package signal

import (
	"bytes"
	"fmt"

	qrcode "github.com/skip2/go-qrcode"
)

// qrModules returns the QR module matrix (true = dark) for content, including
// the library's 4-module quiet-zone border. This is the single source both
// emitters render from.
func qrModules(content string) ([][]bool, error) {
	code, err := qrcode.New(content, qrcode.Medium)
	if err != nil {
		return nil, err
	}
	return code.Bitmap(), nil
}

// qrSVG renders content as a standalone SVG QR code: one 1x1 <rect> per dark
// module on a white background (the quiet zone), viewBox in module units so
// the page can scale it losslessly to any size. Dark modules are near-black
// for maximum scanner contrast regardless of the page theme behind the image.
func qrSVG(content string) ([]byte, error) {
	modules, err := qrModules(content)
	if err != nil {
		return nil, err
	}
	n := len(modules)
	var b bytes.Buffer
	fmt.Fprintf(&b, `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 %d %d" shape-rendering="crispEdges" role="img" aria-label="pairing QR code">`, n, n)
	fmt.Fprintf(&b, `<rect width="%d" height="%d" fill="#ffffff"/>`, n, n)
	b.WriteString(`<g fill="#111111">`)
	for y, row := range modules {
		for x, dark := range row {
			if dark {
				fmt.Fprintf(&b, `<rect x="%d" y="%d" width="1" height="1"/>`, x, y)
			}
		}
	}
	b.WriteString(`</g></svg>`)
	return b.Bytes(), nil
}
