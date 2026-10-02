// Layout tests for js/layout.js. Since v0.6.1 there is one layout (video
// box from below the top inset to the bottom edge); what is left to test is
// the stream-aspect bookkeeping.

import { test } from 'node:test';
import assert from 'node:assert/strict';

import { DEFAULT_VIDEO_RATIO, setVideoAspect, videoAspect } from '../js/layout.js';

test('the aspect starts at 16:9 and follows portrait hellos only', () => {
  assert.equal(videoAspect(), DEFAULT_VIDEO_RATIO);
  setVideoAspect(1179, 2379);
  assert.equal(videoAspect(), 2379 / 1179);
  setVideoAspect(1920, 1080); // landscape: ignored
  assert.equal(videoAspect(), 2379 / 1179);
  setVideoAspect(0, 100); // degenerate: ignored
  assert.equal(videoAspect(), 2379 / 1179);
});
