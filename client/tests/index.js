// Aggregate entry so `node --test tests/` works everywhere. Stock Node scans
// a directory argument for *.test.js itself, but some builds resolve the
// positional path as a single entry module (CJS directory resolution →
// tests/index.js) — importing every suite here makes both behaviors run the
// exact same tests. Add new suites to this list.

import './geometry.test.js';
import './net.test.js';
import './protocol.test.js';
import './qrscan.test.js';
import './vk.test.js';
