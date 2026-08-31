// tokenFromScan: turning whatever a QR camera decoded into a pairing token —
// full pairing URLs, bare tokens, and garbage that must be rejected so the
// scanner keeps scanning instead of "pairing" with a Wi-Fi QR code.

import { test } from 'node:test';
import assert from 'node:assert/strict';

import { tokenFromScan } from '../js/qrscan.js';

test('full pairing URL yields its token', () => {
  assert.equal(tokenFromScan('https://192.168.1.20:8443/?token=3f9c00aa'), '3f9c00aa');
  assert.equal(tokenFromScan('http://pc.local:8443/?token=abc123&x=1'), 'abc123');
  // Whitespace from odd QR encoders is tolerated.
  assert.equal(tokenFromScan('  https://10.0.0.2:8443/?token=tok  '), 'tok');
});

test('bare token passes through', () => {
  assert.equal(tokenFromScan('3f9c1b2a4d5e6f70'), '3f9c1b2a4d5e6f70');
  assert.equal(tokenFromScan('  padded-token  '), 'padded-token');
});

test('non-pairing payloads are rejected (keep scanning)', () => {
  // An http(s) URL without a token parameter is some other QR code.
  assert.equal(tokenFromScan('https://example.com/'), null);
  assert.equal(tokenFromScan('https://192.168.1.20:8443/?other=1'), null);
  // Free text with spaces is clearly not a token.
  assert.equal(tokenFromScan('WIFI:S:MyNet;T:WPA;P:pass;;junk with spaces'), null);
  assert.equal(tokenFromScan(''), null);
  assert.equal(tokenFromScan('   '), null);
  assert.equal(tokenFromScan(null), null);
});

test('well-known non-pairing QR schemes are rejected even without spaces', () => {
  // A wrong scan must NEVER become a bogus token that destroys a working
  // saved pairing — Wi-Fi share cards, contacts, phone numbers, and friends
  // are all spaceless and would otherwise pass as "bare tokens".
  assert.equal(tokenFromScan('WIFI:S:Net;T:WPA;P:pw;;'), null);
  assert.equal(tokenFromScan('mailto:a@b.c'), null);
  assert.equal(tokenFromScan('tel:+3161234'), null);
  assert.equal(tokenFromScan('sms:+31612345678'), null);
  assert.equal(tokenFromScan('geo:52.37,4.89'), null);
  assert.equal(tokenFromScan('MECARD:N:Doe,John;;'), null);
  // vCard/vEvent payloads: the URL parser strips internal newlines, so the
  // whole card parses as one "begin:" URL.
  assert.equal(tokenFromScan('BEGIN:VCARD\nVERSION:3.0\nN:Doe;J\nEND:VCARD'), null);
  assert.equal(tokenFromScan('otpauth://totp/x?secret=ABC'), null);
});

test('non-http URL-ish payloads still work as bare tokens', () => {
  // A token that happens to parse as a URL scheme (e.g. "abc:def") is not an
  // http(s) URL — treat it as a bare token rather than rejecting it.
  assert.equal(tokenFromScan('abc:def'), 'abc:def');
});
