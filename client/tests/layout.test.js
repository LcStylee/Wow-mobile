// Layout tests for js/layout.js. Since v0.6.1 there is one layout (video
// box from below the top inset to the bottom edge); what is left to test is
// the stream-aspect bookkeeping.

import { test } from 'node:test';
import assert from 'node:assert/strict';

import { DEFAULT_VIDEO_RATIO, setVideoAspect, videoAspect, videoBoxHeight } from '../js/layout.js';

test('the aspect starts at 16:9 and follows portrait hellos only', () => {
  assert.equal(videoAspect(), DEFAULT_VIDEO_RATIO);
  setVideoAspect(1179, 2379);
  assert.equal(videoAspect(), 2379 / 1179);
  setVideoAspect(1920, 1080); // landscape: ignored
  assert.equal(videoAspect(), 2379 / 1179);
  setVideoAspect(0, 100); // degenerate: ignored
  assert.equal(videoAspect(), 2379 / 1179);
});

test('video box reaches the real screen bottom on iOS home-screen apps', () => {
  // iPhone 16 PWA (black-translucent): viewport reported 793 = 852 - 59.
  assert.equal(videoBoxHeight(793, 852, 59), 793);
  // An honest full-height viewport (Android fullscreen with a cutout inset,
  // or a fixed iOS): minus the inset.
  assert.equal(videoBoxHeight(891, 891, 24), 867);
  // Browser tab: no inset, the viewport is the box.
  assert.equal(videoBoxHeight(659, 852, 0), 659);
  assert.equal(videoBoxHeight(0, 852, 59), 0);
});
