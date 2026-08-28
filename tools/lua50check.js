#!/usr/bin/env node
// Lua 5.0 conformance gate for the vanilla-WoW addon (WoW 1.12 embeds Lua
// 5.0). The syntax gate (luaparse, Lua 5.1 grammar) accepts several
// constructs that COMPILE under 5.1 but crash or misbehave at runtime on the
// 1.12 client; this tool rejects them:
//
//   * '#'  unary length operator            -> table.getn / string.len
//   * '%'  binary modulo operator           -> math.mod
//   * string.match / string.gmatch /        -> string.find / string.gfind
//     string.reverse (dot form; flagged as member ACCESS, so aliased calls
//     like `local m = string.match` are caught too)
//   * table.pack / table.unpack             -> arg table / unpack
//   * math.fmod                             -> math.mod
//   * select(...)                           -> arg.n / arg[i]
//   * '...' used inside a function BODY     -> the implicit `arg` table
//     (legal only in the parameter list)
//   * _G                                    -> getglobal / setglobal
//   * [=[ ... ]=] leveled long brackets     -> [[ ... ]] (5.1-only syntax)
//   * COLON-FORM string method calls: s:sub(), s:format(), s:gsub(),
//     s:len(), s:match() and every other string-library method. Lua 5.0 has
//     no string metatable AT ALL — string values carry no methods, so every
//     one of these is a fatal runtime error on the 1.12 client, not just the
//     5.1-only match/gmatch pair. Use string.<fn>(s, ...) instead. None of
//     the 1.12 widget APIs use these method names, so flagging any
//     ':'-indexed call to them is safe.
//
// Self-contained tokenizer (no npm dependencies): comments and strings are
// lexed away first, so '%' inside patterns/format strings never
// false-positives.
//
// Usage: node lua50check.js file1.lua file2.lua ...

"use strict";

const fs = require("fs");

const KEYWORDS = new Set([
  "and", "break", "do", "else", "elseif", "end", "false", "for", "function",
  "if", "in", "local", "nil", "not", "or", "repeat", "return", "then",
  "true", "until", "while",
]);

// Every method name the 5.1 string metatable would provide; on 5.0 a
// ':'-indexed call to any of these on a string is a runtime error.
const STRING_METHODS = new Set([
  "sub", "gsub", "find", "format", "len", "rep", "byte", "char", "upper",
  "lower", "match", "gmatch", "gfind", "reverse", "dump",
]);

// <library> . <member> pairs that do not exist in Lua 5.0.
const BANNED_MEMBERS = {
  string: { match: "string.find captures", gmatch: "string.gfind", reverse: "manual loop" },
  table: { pack: "the implicit arg table", unpack: "unpack" },
  math: { fmod: "math.mod" },
};

// ---------------------------------------------------------------------------
// Tokenizer
// ---------------------------------------------------------------------------

function tokenize(src, report) {
  const tokens = [];
  let i = 0;
  let line = 1;
  const n = src.length;

  // Skip a shebang line.
  if (src.charAt(0) === "#") {
    while (i < n && src.charAt(i) !== "\n") i++;
  }

  function longBracketLevel(pos) {
    // Returns the '=' count if src[pos..] starts a long bracket, else -1.
    if (src.charAt(pos) !== "[") return -1;
    let j = pos + 1;
    while (src.charAt(j) === "=") j++;
    return src.charAt(j) === "[" ? j - pos - 1 : -1;
  }

  function skipLongBracket(pos, level, what) {
    if (level > 0) {
      report(line, "5.1-only leveled long bracket [" + "=".repeat(level) +
        "[ in " + what + " — Lua 5.0 supports only [[ ]]");
    }
    const close = "]" + "=".repeat(level) + "]";
    let j = pos + level + 2; // past the opening bracket
    const end = src.indexOf(close, j);
    const stop = end === -1 ? n : end + close.length;
    for (let k = pos; k < stop; k++) {
      if (src.charAt(k) === "\n") line++;
    }
    return stop;
  }

  while (i < n) {
    const c = src.charAt(i);

    if (c === "\n") { line++; i++; continue; }
    if (c === " " || c === "\t" || c === "\r") { i++; continue; }

    // Comments.
    if (c === "-" && src.charAt(i + 1) === "-") {
      const lvl = longBracketLevel(i + 2);
      if (lvl >= 0) {
        i = skipLongBracket(i + 2, lvl, "comment");
      } else {
        while (i < n && src.charAt(i) !== "\n") i++;
      }
      continue;
    }

    // Long-bracket strings.
    const strLvl = longBracketLevel(i);
    if (strLvl >= 0) {
      const startLine = line;
      i = skipLongBracket(i, strLvl, "string");
      tokens.push({ type: "string", value: "", line: startLine });
      continue;
    }

    // Quoted strings.
    if (c === "'" || c === '"') {
      const startLine = line;
      i++;
      while (i < n) {
        const d = src.charAt(i);
        if (d === "\\") { i += 2; continue; }
        if (d === "\n") { line++; i++; continue; } // unterminated; syntax gate catches it
        if (d === c) { i++; break; }
        i++;
      }
      tokens.push({ type: "string", value: "", line: startLine });
      continue;
    }

    // Numbers (don't swallow the dots of a following '..').
    if (/[0-9]/.test(c) || (c === "." && /[0-9]/.test(src.charAt(i + 1)))) {
      const m = /^(0[xX][0-9a-fA-F]+|[0-9]*\.?[0-9]+([eE][+-]?[0-9]+)?)/.exec(src.slice(i, i + 64));
      const text = m ? m[0] : c;
      tokens.push({ type: "number", value: text, line: line });
      i += text.length;
      continue;
    }

    // Names / keywords.
    if (/[A-Za-z_]/.test(c)) {
      let j = i + 1;
      while (j < n && /[A-Za-z0-9_]/.test(src.charAt(j))) j++;
      const word = src.slice(i, j);
      tokens.push({ type: KEYWORDS.has(word) ? "keyword" : "name", value: word, line: line });
      i = j;
      continue;
    }

    // Operators / punctuation (longest munch).
    const three = src.substr(i, 3);
    if (three === "...") {
      tokens.push({ type: "op", value: "...", line: line });
      i += 3;
      continue;
    }
    const two = src.substr(i, 2);
    if (two === ".." || two === "==" || two === "~=" || two === "<=" || two === ">=") {
      tokens.push({ type: "op", value: two, line: line });
      i += 2;
      continue;
    }
    tokens.push({ type: "op", value: c, line: line });
    i++;
  }
  return tokens;
}

// ---------------------------------------------------------------------------
// Token-stream checks
// ---------------------------------------------------------------------------

// Is tokens[i] (a '...') a function PARAMETER (legal in 5.0) rather than a
// body expression (5.1-only)? Legal shape, read right to left from '...':
//   [names/commas]* '(' [Name (('.'|':') Name)*]? 'function'
function isVarargParam(tokens, i) {
  let j = i - 1;
  while (j >= 0 && (tokens[j].type === "name" || tokens[j].value === ",")) j--;
  if (j < 0 || tokens[j].value !== "(") return false;
  j--;
  if (j >= 0 && tokens[j].type === "name") {
    j--;
    while (j >= 1 && (tokens[j].value === "." || tokens[j].value === ":") &&
        tokens[j - 1].type === "name") {
      j -= 2;
    }
  }
  return j >= 0 && tokens[j].type === "keyword" && tokens[j].value === "function";
}

// Is the ':' at tokens[i] part of a method DEFINITION header
// (`function Obj:name(...)`) rather than a call?
function isMethodDefColon(tokens, i) {
  let j = i - 1;
  if (j < 0 || tokens[j].type !== "name") return false;
  j--;
  while (j >= 1 && tokens[j].value === "." && tokens[j - 1].type === "name") j -= 2;
  return j >= 0 && tokens[j].type === "keyword" && tokens[j].value === "function";
}

function checkFile(file) {
  const src = fs.readFileSync(file, "utf8");
  const errors = [];
  const report = (ln, msg) => errors.push(file + ":" + ln + ": " + msg);
  const tokens = tokenize(src, report);

  for (let i = 0; i < tokens.length; i++) {
    const t = tokens[i];
    const prev = tokens[i - 1];
    const next = tokens[i + 1];

    if (t.type !== "op" && t.type !== "name") continue;

    if (t.type === "op") {
      if (t.value === "#") {
        report(t.line, "5.1-only '#' length operator — use table.getn(t) / string.len(s)");
      } else if (t.value === "%") {
        report(t.line, "5.1-only '%' modulo operator — use math.mod(a, b)");
      } else if (t.value === "...") {
        if (!isVarargParam(tokens, i)) {
          report(t.line, "5.1-only '...' in a function body — Lua 5.0 exposes varargs only via the implicit `arg` table");
        }
      } else if (t.value === ":") {
        // Colon-form string method calls: fatal on 5.0's metatable-less
        // strings regardless of receiver type in practice (no 1.12 widget
        // API uses these names).
        if (next && next.type === "name" && STRING_METHODS.has(next.value) &&
            !isMethodDefColon(tokens, i)) {
          report(t.line, "5.1-only string method syntax ':" + next.value +
            "(...)' — Lua 5.0 strings have no metatable; use string." +
            next.value + "(s, ...)");
        }
      }
      continue;
    }

    // Bare-name checks (skip members like foo.select / foo._G).
    const isMember = prev && prev.type === "op" && (prev.value === "." || prev.value === ":");
    if (!isMember) {
      if (t.value === "select" && next && next.value === "(") {
        report(t.line, "5.1-only select() — use the implicit arg table (arg.n, arg[i])");
      } else if (t.value === "_G") {
        report(t.line, "no _G table in WoW 1.12's Lua 5.0 — use getglobal()/setglobal()");
      } else if (BANNED_MEMBERS[t.value] && next && next.value === "." &&
          tokens[i + 2] && tokens[i + 2].type === "name") {
        const member = tokens[i + 2].value;
        const alt = BANNED_MEMBERS[t.value][member];
        if (alt) {
          report(t.line, "5.1-only " + t.value + "." + member + " — use " + alt);
        }
      }
    }
  }
  return errors;
}

// ---------------------------------------------------------------------------

const files = process.argv.slice(2);
if (files.length === 0) {
  console.error("usage: node lua50check.js <files.lua...>");
  process.exit(2);
}

let allErrors = [];
for (const f of files) {
  try {
    allErrors = allErrors.concat(checkFile(f));
  } catch (e) {
    allErrors.push(f + ": " + e.message);
  }
}

if (allErrors.length > 0) {
  for (const e of allErrors) console.error(e);
  process.exit(1);
}
console.log(files.length + " Lua files pass the Lua 5.0 conformance checks");
