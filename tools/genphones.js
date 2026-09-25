#!/usr/bin/env node
// Phone-table generator (docs/PHONE_FRAME.md §2). phones/phones.json is the
// single source of truth for the phone-model selector; this script derives
// every per-phone number ONCE (the only place floating-point dpr values are
// touched) and writes byte-deterministic copies for each component:
//
//   server/internal/phones/phones_gen.go   Go
//   client/js/phones.js                    JS (ES module)
//   addon/WowMobile/Phones.lua             Lua 5.1 (Classic Era / Forever)
//   addon/WowMobile_Vanilla/Phones.lua     Lua 5.0 (1.12)
//   phones/contract_vectors.json           shared frame-placement vectors
//
// Usage: node tools/genphones.js           regenerate
//        node tools/genphones.js --check   exit 1 when any file is stale (CI)
//
// Adding a phone = one JSON entry + a rerun. Never edit the outputs by hand.

"use strict";

const fs = require("fs");
const path = require("path");

const ROOT = path.resolve(__dirname, "..");
const SRC = path.join(ROOT, "phones", "phones.json");

// Contract constants (PHONE_FRAME.md §3–§5). Changing any of these is a
// cross-component contract change: every generated file carries them.
const DECK_LOGICAL_PX = 60; // phone client's control strip below the video (CSS px)
const RING_OUTER_PX = 4; // red part of the outline (physical px)
const RING_INNER_PX = 2; // cyan machine tag (physical px)
const RING_PX = RING_OUTER_PX + RING_INNER_PX;
const ENC_MAX_W = 1080; // encode cap (the design space)
const ENC_MAX_H = 1920;
const DEFAULT_PHONE_ID = "iphone-17";
const MIN_DIM = 16;

// roundHalfToEven(num, den) — integer banker's rounding, the shared snap of
// the band/frame contract (num >= 0, den > 0).
function rhe(num, den) {
  if (!(Number.isInteger(num) && Number.isInteger(den)) || num < 0 || den <= 0) {
    throw new Error(`rhe(${num}, ${den}) out of contract`);
  }
  const q = Math.floor(num / den);
  const r = num - q * den;
  if (2 * r > den) return q + 1;
  if (2 * r < den) return q;
  return q + (q % 2);
}

// dpr as an exact integer thousandth (2.625 -> 2625); every table value is a
// multiple of 1/1000, which the validator enforces.
function dprMilli(dpr) {
  const m = Math.round(dpr * 1000);
  if (Math.abs(m / 1000 - dpr) > 1e-9) throw new Error(`dpr ${dpr} is not a multiple of 0.001`);
  return m;
}

function streamSize(p) {
  if (p.stream) return { w: p.stream.w, h: p.stream.h };
  const reserved = rhe((p.insetTop + p.insetBottom + DECK_LOGICAL_PX) * dprMilli(p.dpr), 1000);
  return { w: p.physW, h: p.physH - reserved };
}

// Frame placement (PHONE_FRAME.md §4) — ported verbatim to Go
// (window.ComputePhoneFrame) and both Lua Band.lua files; the vectors below
// pin all of them to this implementation.
function frameRect(clientW, clientH, sw, sh) {
  const availW = clientW - 2 * RING_PX;
  const availH = clientH - 2 * RING_PX;
  if (availW < MIN_DIM || availH < MIN_DIM) return null;
  let h = availH;
  let w = rhe(availH * sw, sh);
  if (w > availW) {
    w = availW;
    h = rhe(availW * sh, sw);
  }
  if (w < MIN_DIM || h < MIN_DIM) return null;
  return { x: rhe(clientW - w, 2), y: rhe(clientH - h, 2), w, h };
}

function encodeSize(w, h) {
  if (w <= ENC_MAX_W && h <= ENC_MAX_H) return { w: w & ~1, h: h & ~1 };
  if (w * ENC_MAX_H >= h * ENC_MAX_W) {
    return { w: ENC_MAX_W, h: rhe(h * ENC_MAX_W, w) & ~1 };
  }
  return { w: rhe(w * ENC_MAX_H, h) & ~1, h: ENC_MAX_H };
}

function validate(doc) {
  const seen = new Set();
  const ranks = [];
  for (const p of doc.phones) {
    for (const k of ["id", "brand", "model"]) {
      if (typeof p[k] !== "string" || !p[k]) throw new Error(`phone ${JSON.stringify(p)}: ${k} required`);
    }
    if (!/^[a-z0-9][a-z0-9-]*$/.test(p.id)) throw new Error(`${p.id}: id must be lowercase [a-z0-9-]`);
    if (seen.has(p.id)) throw new Error(`${p.id}: duplicate id`);
    seen.add(p.id);
    for (const k of ["physW", "physH", "insetTop", "insetBottom", "year"]) {
      if (!Number.isInteger(p[k]) || p[k] < 0) throw new Error(`${p.id}: ${k} must be a non-negative integer`);
    }
    if (p.physW >= p.physH) throw new Error(`${p.id}: physW/physH must be portrait`);
    dprMilli(p.dpr);
    if (p.popularity !== null && !(Number.isInteger(p.popularity) && p.popularity > 0)) {
      throw new Error(`${p.id}: popularity must be null or a positive integer`);
    }
    if (p.popularity !== null) ranks.push(p.popularity);
    const s = streamSize(p);
    if (s.w < MIN_DIM || s.h <= s.w) throw new Error(`${p.id}: derived stream ${s.w}x${s.h} is not portrait`);
    for (const ch of [p.brand, p.model]) {
      if (/["\\\n]/.test(ch)) throw new Error(`${p.id}: brand/model must not contain quotes, backslashes or newlines`);
    }
  }
  ranks.sort((a, b) => a - b);
  ranks.forEach((r, i) => {
    if (r !== i + 1) throw new Error(`popularity ranks must be 1..N without gaps (got ${ranks.join(",")})`);
  });
  if (!seen.has(DEFAULT_PHONE_ID)) throw new Error(`default phone ${DEFAULT_PHONE_ID} missing`);
  if (!seen.has("generic-9-16")) throw new Error("generic-9-16 (legacy band alias) missing");
}

// Selector order: ranked phones by popularity, then the extras by brand/model.
function ordered(phones) {
  return phones.slice().sort((a, b) => {
    const pa = a.popularity === null ? Infinity : a.popularity;
    const pb = b.popularity === null ? Infinity : b.popularity;
    if (pa !== pb) return pa - pb;
    const ka = `${a.brand} ${a.model}`.toLowerCase();
    const kb = `${b.brand} ${b.model}`.toLowerCase();
    return ka < kb ? -1 : ka > kb ? 1 : 0;
  });
}

// Shared contract vectors: every component asserts these against its own
// port of frameRect/encodeSize.
const VECTOR_CLIENTS = [
  [3840, 2160], [2560, 1440], [1920, 1080], [1280, 720], [1366, 768],
  [3440, 1440], [1920, 1200], [1281, 719], [1600, 1000], [1080, 1920],
];
const VECTOR_PHONES = ["iphone-17", "galaxy-a07", "galaxy-s26-ultra", "generic-9-16", "iphone-se-3"];

function buildVectors(byId) {
  const out = [];
  for (const id of VECTOR_PHONES) {
    const s = streamSize(byId.get(id));
    for (const [cw, ch] of VECTOR_CLIENTS) {
      const f = frameRect(cw, ch, s.w, s.h);
      const e = encodeSize(f.w, f.h);
      out.push({ phone: id, clientW: cw, clientH: ch, x: f.x, y: f.y, w: f.w, h: f.h, encW: e.w, encH: e.h });
    }
  }
  return out;
}

const HEADER = "Code generated by tools/genphones.js from phones/phones.json. DO NOT EDIT.";

function genGo(list, vectors) {
  const L = [];
  L.push(`// ${HEADER}`, "", "package phones", "");
  L.push("// Contract constants (docs/PHONE_FRAME.md).");
  L.push("const (");
  L.push(`\tDeckLogicalPx = ${DECK_LOGICAL_PX}`);
  L.push(`\tRingOuterPx   = ${RING_OUTER_PX}`);
  L.push(`\tRingInnerPx   = ${RING_INNER_PX}`);
  L.push(`\tRingPx        = ${RING_PX}`);
  L.push(`\tEncMaxW       = ${ENC_MAX_W}`);
  L.push(`\tEncMaxH       = ${ENC_MAX_H}`);
  L.push(`\tDefaultID     = ${JSON.stringify(DEFAULT_PHONE_ID)}`);
  L.push(")", "");
  L.push("// All is the selector-ordered table (popularity rank, then brand/model).");
  L.push("var All = []Phone{");
  for (const p of list) {
    const s = streamSize(p);
    L.push(`\t{ID: ${JSON.stringify(p.id)}, Brand: ${JSON.stringify(p.brand)}, Model: ${JSON.stringify(p.model)}, Year: ${p.year}, PhysW: ${p.physW}, PhysH: ${p.physH}, DPRMilli: ${dprMilli(p.dpr)}, InsetTop: ${p.insetTop}, InsetBottom: ${p.insetBottom}, Popularity: ${p.popularity === null ? 0 : p.popularity}, StreamW: ${s.w}, StreamH: ${s.h}},`);
  }
  L.push("}", "");
  L.push("// ContractVectors mirrors phones/contract_vectors.json.");
  L.push("var ContractVectors = []Vector{");
  for (const v of vectors) {
    L.push(`\t{Phone: ${JSON.stringify(v.phone)}, ClientW: ${v.clientW}, ClientH: ${v.clientH}, X: ${v.x}, Y: ${v.y}, W: ${v.w}, H: ${v.h}, EncW: ${v.encW}, EncH: ${v.encH}},`);
  }
  L.push("}", "");
  return L.join("\n");
}

function genJS(list, vectors) {
  const L = [];
  L.push(`// ${HEADER}`, "");
  L.push(`export const DECK_LOGICAL_PX = ${DECK_LOGICAL_PX};`);
  L.push(`export const RING_PX = ${RING_PX};`);
  L.push(`export const ENC_MAX_W = ${ENC_MAX_W};`);
  L.push(`export const ENC_MAX_H = ${ENC_MAX_H};`);
  L.push(`export const DEFAULT_PHONE_ID = ${JSON.stringify(DEFAULT_PHONE_ID)};`, "");
  L.push("// Selector-ordered (popularity rank, then brand/model). popularity 0 = extra.");
  L.push("export const PHONES = Object.freeze([");
  for (const p of list) {
    const s = streamSize(p);
    L.push(`  { id: ${JSON.stringify(p.id)}, brand: ${JSON.stringify(p.brand)}, model: ${JSON.stringify(p.model)}, physW: ${p.physW}, physH: ${p.physH}, dprMilli: ${dprMilli(p.dpr)}, insetTop: ${p.insetTop}, insetBottom: ${p.insetBottom}, popularity: ${p.popularity === null ? 0 : p.popularity}, streamW: ${s.w}, streamH: ${s.h} },`);
  }
  L.push("]);", "");
  L.push("export const CONTRACT_VECTORS = Object.freeze([");
  for (const v of vectors) {
    L.push(`  { phone: ${JSON.stringify(v.phone)}, clientW: ${v.clientW}, clientH: ${v.clientH}, x: ${v.x}, y: ${v.y}, w: ${v.w}, h: ${v.h}, encW: ${v.encW}, encH: ${v.encH} },`);
  }
  L.push("]);", "");
  return L.join("\n");
}

// Lua: identical data for 5.1 and 5.0; only the namespace access differs
// (5.1 addons get it from the file vararg, 1.12 uses the WowMobile global).
function genLua(list, vectors, vanilla) {
  const L = [];
  L.push(`-- ${HEADER}`);
  L.push(vanilla ? "local WM = WowMobile" : "local _, WM = ...");
  L.push("");
  L.push("WM.PhoneData = {");
  L.push(`\tdeckLogicalPx = ${DECK_LOGICAL_PX},`);
  L.push(`\tringOuterPx = ${RING_OUTER_PX},`);
  L.push(`\tringInnerPx = ${RING_INNER_PX},`);
  L.push(`\tringPx = ${RING_PX},`);
  L.push(`\tencMaxW = ${ENC_MAX_W},`);
  L.push(`\tencMaxH = ${ENC_MAX_H},`);
  L.push(`\tdefaultId = ${JSON.stringify(DEFAULT_PHONE_ID)},`);
  L.push("\t-- { id, brand, model, streamW, streamH, popularity (0 = extra), physW, physH }");
  L.push("\tlist = {");
  for (const p of list) {
    const s = streamSize(p);
    L.push(`\t\t{ id = ${JSON.stringify(p.id)}, brand = ${JSON.stringify(p.brand)}, model = ${JSON.stringify(p.model)}, streamW = ${s.w}, streamH = ${s.h}, popularity = ${p.popularity === null ? 0 : p.popularity}, physW = ${p.physW}, physH = ${p.physH} },`);
  }
  L.push("\t},");
  L.push("\t-- { phone, clientW, clientH, x, y, w, h, encW, encH }");
  L.push("\tvectors = {");
  for (const v of vectors) {
    L.push(`\t\t{ ${JSON.stringify(v.phone)}, ${v.clientW}, ${v.clientH}, ${v.x}, ${v.y}, ${v.w}, ${v.h}, ${v.encW}, ${v.encH} },`);
  }
  L.push("\t},");
  L.push("}");
  L.push("");
  return L.join("\n");
}

function main() {
  const check = process.argv.includes("--check");
  const doc = JSON.parse(fs.readFileSync(SRC, "utf8"));
  validate(doc);
  const list = ordered(doc.phones);
  const byId = new Map(list.map((p) => [p.id, p]));
  const vectors = buildVectors(byId);

  const outputs = {
    "server/internal/phones/phones_gen.go": genGo(list, vectors),
    "client/js/phones.js": genJS(list, vectors),
    "addon/WowMobile/Phones.lua": genLua(list, vectors, false),
    "addon/WowMobile_Vanilla/Phones.lua": genLua(list, vectors, true),
    "phones/contract_vectors.json": JSON.stringify({ note: HEADER, ringPx: RING_PX, vectors }, null, 1) + "\n",
  };

  let stale = 0;
  for (const [rel, content] of Object.entries(outputs)) {
    const file = path.join(ROOT, rel);
    const cur = fs.existsSync(file) ? fs.readFileSync(file, "utf8") : null;
    if (cur === content) continue;
    if (check) {
      console.error(`stale: ${rel} (run node tools/genphones.js)`);
      stale++;
    } else {
      fs.mkdirSync(path.dirname(file), { recursive: true });
      fs.writeFileSync(file, content);
      console.log(`wrote ${rel}`);
    }
  }
  if (stale) process.exit(1);
  if (check) console.log(`${Object.keys(outputs).length} generated phone files are up to date`);
}

if (require.main === module) main();

module.exports = { rhe, streamSize, frameRect, encodeSize };
