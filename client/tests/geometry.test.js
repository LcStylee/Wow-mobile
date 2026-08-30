// Letterbox / world-region math tests for js/geometry.js — the client half of
// the geometry chain contract with the addon (ARCHITECTURE.md §1/§5): the
// world region is `viewportPx` design px tall in a 1080-wide window, anchored
// top, an exact square at the default 1080.

import { test } from 'node:test';
import assert from 'node:assert/strict';

import { DESIGN_WIDTH, clamp, fitContain, worldSquareFrac } from '../js/geometry.js';

test('fitContain letterboxes portrait content in a taller box', () => {
  // 1080x1920 content in a 390x900 box: width-limited, vertical bars split.
  const r = fitContain(390, 900, 1080, 1920);
  assert.equal(r.x, 0);
  assert.equal(r.w, 390);
  const h = (1920 / 1080) * 390;
  assert.ok(Math.abs(r.h - h) < 1e-9);
  assert.ok(Math.abs(r.y - (900 - h) / 2) < 1e-9);
});

test('fitContain pillarboxes when the box is wider than the content', () => {
  const r = fitContain(2000, 960, 1080, 1920);
  assert.equal(r.y, 0);
  assert.equal(r.h, 960);
  const w = (1080 / 1920) * 960;
  assert.ok(Math.abs(r.w - w) < 1e-9);
  assert.ok(Math.abs(r.x - (2000 - w) / 2) < 1e-9);
});

test('worldSquareFrac defaults to the full-width square', () => {
  assert.equal(DESIGN_WIDTH, 1080);
  // ARCHITECTURE.md §1: default viewport on a 1080x1920 capture = 0.5625.
  assert.equal(worldSquareFrac(1080, 1920), 0.5625);
  assert.equal(worldSquareFrac(1080, 1920, DESIGN_WIDTH), 0.5625);
});

test('worldSquareFrac scales with the addon viewport height', () => {
  // /wm viewport 648 (the addon's minimum) on a 1080x1920 capture.
  assert.ok(Math.abs(worldSquareFrac(1080, 1920, 648) - 648 / 1920) < 1e-12);
  // /wm viewport 1296 (the addon's 1.20 ratio cap).
  assert.ok(Math.abs(worldSquareFrac(1080, 1920, 1296) - 1296 / 1920) < 1e-12);
  // Viewport px are design px of a 1080-wide window: the fraction is
  // resolution-independent (same window at half capture resolution).
  assert.equal(worldSquareFrac(540, 960, 648), worldSquareFrac(1080, 1920, 648));
});

test('worldSquareFrac clamps the degenerate over-tall viewport', () => {
  // A viewport taller than the capture can never exceed the frame.
  assert.equal(worldSquareFrac(1080, 1920, 4000), 1);
  assert.equal(worldSquareFrac(1920, 1080), 1); // landscape capture
});

test('worldSquareFrac tracks a monitor-fitted capture resolution', () => {
  // --resolution fit on a 1920x1032 work area yields 552x984 (server
  // window.FitPortraitClient): the world region at the default viewport is
  // the top width x width square of THAT frame — no 1080/1920 hardcoding.
  const frac = worldSquareFrac(552, 984);
  assert.ok(Math.abs(frac - 552 / 984) < 1e-12);
  // On-screen: square height equals the video content width after fitContain.
  const r = fitContain(390, 900, 552, 984);
  assert.ok(Math.abs(frac * r.h - r.w) < 1e-9);
});

test('clamp pins to the interval bounds', () => {
  assert.equal(clamp(5, 0, 10), 5);
  assert.equal(clamp(-1, 0, 10), 0);
  assert.equal(clamp(11, 0, 10), 10);
});
