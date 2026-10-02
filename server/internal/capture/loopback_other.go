//go:build !windows

package capture

import (
	"context"
	"io"
)

// ProbeLoopback reports the loopback format; unsupported off Windows.
func ProbeLoopback() (LoopbackFormat, error) {
	return LoopbackFormat{}, ErrLoopbackUnsupported
}

// StreamLoopback streams system audio; unsupported off Windows.
func StreamLoopback(ctx context.Context, w io.Writer, want LoopbackFormat) error {
	return ErrLoopbackUnsupported
}
