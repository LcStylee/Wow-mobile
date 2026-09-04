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
// Closure-limit analysis (Lua 5.0 per-function hard limits)
//
// Lua 5.0 caps a single function at 32 UPVALUES (MAXUPVALUES; 5.1 raised it
// to 60) and 200 active LOCALS (MAXVARS). Exceeding either is a COMPILE
// error ("too many upvalues" / "too many local variables") that kills the
// whole chunk — the crash guard's pcall never even runs, so the module is
// silently dead (field failure: Mail.lua:686). The syntax gate (luaparse,
// 5.1 grammar) does not model 5.0's limits, so we count them here.
//
// Semantics (mirrors lparser.c singlevaraux): a function's upvalue count is
// the number of DISTINCT locals declared in strictly-enclosing functions
// that are referenced anywhere inside it — including references made only by
// functions nested deeper (every intermediate function gets a pass-through
// upvalue slot). Locals count is the maximum number of simultaneously active
// local slots (params + declarations, block-scoped; per lparser.c a numeric
// `for` occupies its variable plus 2 hidden slots — "(for limit)" and
// "(for step)" — and a generic `for` its names plus 2 hidden — "(for
// generator)" and "(for state)").
//
// We flag at >=30 upvalues / >=190 locals to leave headroom below the hard
// limits. The idiomatic fix for upvalue overflow: move shared closure state
// into one module-level table so closures capture a single table reference.
//
// Declaration order mirrors Lua 5.0's declare-after-evaluate rule: the names
// of `local x, y = <exprs>` — and for-loop control variables — are NOT in
// scope while their initializer/bound expressions are scanned (declarations
// are buffered until the expression list ends), so a shadowing `local x = x`
// counts the RHS as a capture of the OUTER x, exactly like the real
// compiler.
//
// repeat/until scoping: a `repeat ... until <cond>` block's locals go out of
// scope at the `until` token here, so condition references to them resolve
// outward. This is NOT an approximation — it matches Lua 5.0's parser
// exactly: lparser.c's repeatstat parses the body via block(), whose
// leaveblock() removes the body's locals BEFORE cond() reads the condition,
// so on 5.0 the condition cannot see body locals (and a closure in the
// condition can never capture one). The condition seeing body locals is a
// Lua 5.1 change — do NOT "fix" this by extending body scope into the
// condition: that would introduce 5.1 semantics and produce real miscounts
// against the 1.12 client's 5.0 compiler. The 4/10-slot flag headroom below
// exists to absorb other residual modeling drift, not this.
// ---------------------------------------------------------------------------

const UPVALUE_LIMIT = 32;  // Lua 5.0 MAXUPVALUES
const UPVALUE_FLAG = 28;   // headroom threshold (4 slots under the limit)
const LOCALS_LIMIT = 200;  // Lua 5.0 MAXVARS
const LOCALS_FLAG = 190;   // headroom threshold

// Analyzes the token stream of one chunk; returns an array of per-function
// records { name, line, upvals, maxLocals } (main chunk included, upvals
// always 0 there). `report` gets called for threshold violations.
function analyzeClosures(tokens, report) {
  const results = [];
  let varCounter = 0;

  // Function records. funcStack[0] is the main chunk.
  const funcStack = [{ name: "main chunk", line: 0, upvals: new Set(), active: 0, maxActive: 0 }];
  // Scope records: { fnDepth, locals: Map(name -> id), nslots, kind }.
  const scopeStack = [{ fnDepth: 0, locals: new Map(), nslots: 0, kind: "function" }];
  // Innermost grouping context for table-key detection: real brackets
  // ('(', '{', '[') plus an 'fn' sentinel pushed when a function body opens,
  // so statements inside a function literal embedded in a table constructor
  // are never mistaken for table-key positions.
  const groupStack = [];
  let pendingForDo = false; // the next `do` belongs to a `for` header
  // Deferred declarations (Lua 5.0 declare-after-evaluate): the names of
  // `local x, y = <exprs>` and of for-loop control variables enter scope only
  // AFTER their initializer/bound expressions, so they are buffered here and
  // declared when the statement's expression list ends. Entries:
  // { names, baseGroup, baseFn } — flushed when depths return to base and a
  // statement boundary is seen.
  const pendingDecls = [];

  function flushPending() {
    const p = pendingDecls.pop();
    for (let k = 0; k < p.names.length; k++) declareLocal(p.names[k]);
  }

  // Keywords that can appear inside an expression list (plus 'in', which
  // never starts a statement) — anything else at base depth ends it.
  const EXPR_KEYWORDS = new Set(["and", "or", "not", "nil", "true", "false", "function", "in"]);

  // Can tok be the LAST token of a complete expression? Used to tell a new
  // statement's leading name/`function` from a continuation of the current
  // expression list.
  function endsExpression(tok) {
    if (!tok) return false;
    if (tok.type === "name" || tok.type === "number" || tok.type === "string") return true;
    if (tok.type === "op") return tok.value === ")" || tok.value === "}" || tok.value === "]";
    return tok.value === "nil" || tok.value === "true" || tok.value === "false" ||
      tok.value === "end";
  }

  function declareLocal(name) {
    const scope = scopeStack[scopeStack.length - 1];
    varCounter++;
    scope.locals.set(name, varCounter);
    scope.nslots++;
    const fn = funcStack[scope.fnDepth];
    fn.active++;
    if (fn.active > fn.maxActive) fn.maxActive = fn.active;
  }

  function declareHidden(count) {
    const scope = scopeStack[scopeStack.length - 1];
    scope.nslots += count;
    const fn = funcStack[scope.fnDepth];
    fn.active += count;
    if (fn.active > fn.maxActive) fn.maxActive = fn.active;
  }

  function pushScope(kind) {
    scopeStack.push({ fnDepth: funcStack.length - 1, locals: new Map(), nslots: 0, kind: kind });
  }

  function finalizeFn(fn) {
    const rec = { name: fn.name, line: fn.line, upvals: fn.upvals.size, maxLocals: fn.maxActive };
    results.push(rec);
    if (fn.upvals.size >= UPVALUE_FLAG) {
      report(fn.line, "function '" + fn.name + "' captures " + fn.upvals.size +
        " upvalues (Lua 5.0 COMPILE limit " + UPVALUE_LIMIT + "; flagged at >=" +
        UPVALUE_FLAG + ") — move shared closure state into a module-level table");
    }
    if (fn.maxActive >= LOCALS_FLAG) {
      report(fn.line, "function '" + fn.name + "' has " + fn.maxActive +
        " active locals (Lua 5.0 COMPILE limit " + LOCALS_LIMIT + "; flagged at >=" +
        LOCALS_FLAG + ") — split the function or hoist state into tables");
    }
  }

  function popScope() {
    if (scopeStack.length <= 1) return; // defensive; syntax gate owns real errors
    const scope = scopeStack.pop();
    funcStack[scope.fnDepth].active -= scope.nslots;
    if (scope.kind === "function" && funcStack.length > 1) {
      const fn = funcStack.pop();
      // A for-header `do` pending from OUTSIDE this function literal must
      // survive any `do` blocks inside it (see the function-header branch).
      pendingForDo = fn.savedPendingForDo;
      if (groupStack[groupStack.length - 1] === "fn") groupStack.pop();
      finalizeFn(fn);
    }
  }

  // Resolve a name reference: find its declaring scope; if declared in an
  // outer FUNCTION, add it to the upvalue set of every function level between
  // the declaration and the current function (pass-through slots included).
  function resolve(name) {
    for (let s = scopeStack.length - 1; s >= 0; s--) {
      const id = scopeStack[s].locals.get(name);
      if (id !== undefined) {
        const declDepth = scopeStack[s].fnDepth;
        for (let f = declDepth + 1; f < funcStack.length; f++) {
          funcStack[f].upvals.add(id);
        }
        return;
      }
    }
    // Not found: global — no cost.
  }

  let i = 0;
  const n = tokens.length;
  while (i < n) {
    const t = tokens[i];

    // Flush deferred declarations once their statement's expression list has
    // ended: the current token starts a new statement (or closes the
    // enclosing block / opens the for body) at the depth of the declaration.
    if (pendingDecls.length > 0) {
      const p = pendingDecls[pendingDecls.length - 1];
      if (groupStack.length === p.baseGroup && funcStack.length === p.baseFn) {
        const startsStatement =
          (t.type === "keyword" && !EXPR_KEYWORDS.has(t.value)) ||
          (t.type === "op" && t.value === ";") ||
          ((t.type === "name" || t.value === "function") && endsExpression(tokens[i - 1]));
        if (startsStatement) flushPending();
      }
    }

    if (t.type === "keyword") {
      if (t.value === "function") {
        // Header: function [Name ('.' Name)* (':' Name)?] '(' params ')'
        let j = i + 1;
        let isMethod = false;
        let headerName = "anonymous";
        if (tokens[j] && tokens[j].type === "name") {
          headerName = tokens[j].value;
          resolve(tokens[j].value); // the base name is a real read/write
          j++;
          while (tokens[j] && (tokens[j].value === "." || tokens[j].value === ":") &&
              tokens[j + 1] && tokens[j + 1].type === "name") {
            if (tokens[j].value === ":") isMethod = true;
            headerName += tokens[j].value + tokens[j + 1].value;
            j += 2;
          }
        }
        funcStack.push({ name: headerName, line: t.line, upvals: new Set(), active: 0,
          maxActive: 0, savedPendingForDo: pendingForDo });
        // A `do` inside this body must never consume a for-header's pending
        // `do` from the enclosing function (restored in popScope).
        pendingForDo = false;
        pushScope("function");
        // Sentinel: statements in this body are not table-constructor
        // context even when the literal sits directly inside '{ }'.
        groupStack.push("fn");
        if (isMethod) declareLocal("self");
        if (tokens[j] && tokens[j].value === "(") {
          j++;
          while (j < n && tokens[j].value !== ")") {
            if (tokens[j].type === "name") declareLocal(tokens[j].value);
            else if (tokens[j].value === "...") declareLocal("arg"); // 5.0 implicit arg table
            j++;
          }
        }
        i = j + 1;
        continue;
      }
      if (t.value === "local") {
        if (tokens[i + 1] && tokens[i + 1].value === "function" &&
            tokens[i + 2] && tokens[i + 2].type === "name") {
          // `local function f` == `local f; f = function...`: declare f
          // first so it is visible inside its own body (recursion).
          declareLocal(tokens[i + 2].value);
          // Let the `function` branch parse the header; its base-name resolve
          // hits the local we just declared (same function level: no upvalue).
          i++;
          continue;
        }
        let j = i + 1;
        const names = [];
        while (tokens[j] && tokens[j].type === "name") {
          names.push(tokens[j].value);
          j++;
          if (tokens[j] && tokens[j].value === ",") j++;
          else break;
        }
        if (tokens[j] && tokens[j].value === "=") {
          // Lua 5.0 evaluates the initializer list BEFORE the names come
          // into scope (`local x = x` reads the OUTER x): buffer the
          // declarations until the expression list ends.
          pendingDecls.push({ names: names, baseGroup: groupStack.length, baseFn: funcStack.length });
        } else {
          for (let k = 0; k < names.length; k++) declareLocal(names[k]);
        }
        i = j;
        continue;
      }
      if (t.value === "for") {
        pushScope("for");
        pendingForDo = true;
        // 2 hidden control slots — numeric: "(for limit)"/"(for step)",
        // generic: "(for generator)"/"(for state)" (lparser.c) — the visible
        // loop names are declared separately via pendingDecls below.
        declareHidden(2);
        let j = i + 1;
        const names = [];
        while (tokens[j] && tokens[j].type === "name") {
          names.push(tokens[j].value);
          j++;
          if (tokens[j] && tokens[j].value === ",") j++;
          else break;
        }
        // Control variables enter scope only at the loop BODY — the bound
        // expressions are evaluated outside them (`for i = i, n` reads the
        // outer i) — so their declaration is buffered until the `do` (or,
        // for `for ... in`, until the first statement boundary, which is
        // that same `do`).
        pendingDecls.push({ names: names, baseGroup: groupStack.length, baseFn: funcStack.length });
        i = j; // resume at '=' / 'in'; bound expressions scan as references
        continue;
      }
      if (t.value === "do") {
        if (pendingForDo) pendingForDo = false; // for-header scope already pushed
        else pushScope("block");
        i++;
        continue;
      }
      if (t.value === "then") { pushScope("block"); i++; continue; }
      if (t.value === "elseif") { popScope(); i++; continue; } // its `then` re-pushes
      if (t.value === "else") { popScope(); pushScope("block"); i++; continue; }
      if (t.value === "repeat") { pushScope("block"); i++; continue; }
      if (t.value === "until") { popScope(); i++; continue; }
      if (t.value === "end") { popScope(); i++; continue; }
      i++;
      continue;
    }

    if (t.type === "op") {
      if (t.value === "(" || t.value === "{" || t.value === "[") groupStack.push(t.value);
      else if (t.value === ")" || t.value === "}" || t.value === "]") groupStack.pop();
      i++;
      continue;
    }

    if (t.type === "name") {
      const prev = tokens[i - 1];
      const next = tokens[i + 1];
      const isMember = prev && prev.type === "op" && (prev.value === "." || prev.value === ":");
      // `{ key = v }` table-constructor keys are not variable references:
      // only when the innermost grouping context is '{' (an 'fn' sentinel
      // shields statements inside function literals embedded in tables).
      // Lua 5.0 fieldsep is ',' OR ';' (lua50 grammar), so both separators
      // put the following name in key position.
      const isTableKey = groupStack[groupStack.length - 1] === "{" &&
        prev && (prev.value === "{" || prev.value === "," || prev.value === ";") &&
        next && next.value === "=";
      if (!isMember && !isTableKey) resolve(t.value);
      i++;
      continue;
    }

    i++; // strings / numbers
  }

  // EOF: flush any dangling deferred declarations (innermost first, while
  // their scopes are still open), then close remaining scopes (main chunk
  // last).
  while (pendingDecls.length > 0) flushPending();
  while (scopeStack.length > 1) popScope();
  finalizeFn(funcStack[0]);
  return results;
}

// ---------------------------------------------------------------------------
// Self-test for the closure counter (run with --selftest). Synthetic chunks
// with known upvalue/local counts verify the counter before it judges the
// addon.
// ---------------------------------------------------------------------------

function selftest() {
  function analyze(src) {
    const flagged = [];
    const tokens = tokenize(src, function () {});
    const recs = analyzeClosures(tokens, function (ln, msg) { flagged.push(msg); });
    return { recs: recs, flagged: flagged };
  }
  function fnRec(r, name) {
    for (let k = 0; k < r.recs.length; k++) {
      if (r.recs[k].name === name) return r.recs[k];
    }
    return null;
  }
  function genUpvalChunk(count) {
    const decls = [];
    const refs = [];
    for (let k = 1; k <= count; k++) {
      decls.push("local u" + k + " = " + k);
      refs.push("u" + k);
    }
    return decls.join("\n") + "\nlocal function f()\n  return " +
      refs.join(" + ") + "\nend\n";
  }
  let failures = 0;
  function expect(cond, what) {
    if (!cond) { failures++; console.error("selftest FAIL: " + what); }
    else console.log("selftest ok: " + what);
  }

  // 27 upvalues: under threshold, exact count, no flag.
  let r = analyze(genUpvalChunk(27));
  expect(fnRec(r, "f") && fnRec(r, "f").upvals === 27, "27 upvalues counted as 27");
  expect(r.flagged.length === 0, "27 upvalues not flagged");

  // 28 upvalues: exactly AT the flag threshold — pins the >=28 boundary so a
  // regression that silently moves it (eroding headroom below the compile
  // limit) fails the suite.
  r = analyze(genUpvalChunk(28));
  expect(fnRec(r, "f") && fnRec(r, "f").upvals === 28, "28 upvalues counted as 28");
  expect(r.flagged.length === 1, "28 upvalues flagged (threshold boundary pinned)");

  // 29 upvalues: one past the threshold, still under the hard limit.
  r = analyze(genUpvalChunk(29));
  expect(fnRec(r, "f") && fnRec(r, "f").upvals === 29, "29 upvalues counted as 29");
  expect(r.flagged.length === 1, "29 upvalues flagged");

  // 32 upvalues: at the hard limit, flagged.
  r = analyze(genUpvalChunk(32));
  expect(fnRec(r, "f") && fnRec(r, "f").upvals === 32, "32 upvalues counted as 32");
  expect(r.flagged.length === 1, "32 upvalues flagged");

  // 33 upvalues: over the hard limit (would not even compile), flagged.
  r = analyze(genUpvalChunk(33));
  expect(fnRec(r, "f") && fnRec(r, "f").upvals === 33, "33 upvalues counted as 33");
  expect(r.flagged.length === 1, "33 upvalues flagged");

  // Pass-through capture: a local referenced only by an inner-inner closure
  // still occupies an upvalue slot in the intermediate function.
  r = analyze(
    "local x = 1\nlocal y = 2\n" +
    "local function outer()\n" +
    "  local function inner() return x + y end\n" +
    "  return inner\nend\n");
  expect(fnRec(r, "outer") && fnRec(r, "outer").upvals === 2,
    "intermediate function gets pass-through upvalue slots");
  expect(fnRec(r, "inner") && fnRec(r, "inner").upvals === 2,
    "innermost closure counts outer-outer captures");

  // Locals declared inside the same function are NOT upvalues.
  r = analyze("local function g()\n  local a = 1\n  local h = function() return a end\n  return h\nend\n");
  expect(fnRec(r, "g") && fnRec(r, "g").upvals === 0, "own locals are not upvalues");
  expect(fnRec(r, "anonymous").upvals === 1, "nested closure captures one upvalue");

  // Table-key names and member accesses are not references.
  r = analyze("local t = 1\nlocal function k()\n  local m = { t = 1, u = 2 }\n  return m.t\nend\n");
  expect(fnRec(r, "k") && fnRec(r, "k").upvals === 0, "table keys / members not counted");

  // Lua 5.0 also allows ';' as a table fieldsep: `{ a = 1; b = 2 }` keys are
  // key positions too, not variable references.
  r = analyze("local t = 1\nlocal u = 2\nlocal function sk()\n  local m = { t = 1; u = 2 }\n  return m.t\nend\n");
  expect(fnRec(r, "sk") && fnRec(r, "sk").upvals === 0,
    "semicolon-separated table keys not counted");

  // Block scoping frees local slots; max simultaneous is what counts.
  r = analyze(
    "local function b()\n" +
    "  do local a1, a2, a3 = 1, 2, 3 end\n" +
    "  do local b1, b2 = 1, 2 end\n" +
    "end\n");
  expect(fnRec(r, "b") && fnRec(r, "b").maxLocals === 3, "block locals freed on scope exit");

  // Locals threshold: 195 simultaneously-active locals flags.
  {
    const decls = [];
    for (let k = 1; k <= 195; k++) decls.push("local v" + k + " = 0");
    r = analyze("local function big()\n" + decls.join("\n") + "\nend\n");
    expect(fnRec(r, "big") && fnRec(r, "big").maxLocals === 195, "195 locals counted");
    expect(r.flagged.length === 1, "195 locals flagged");
  }

  // for-loop control vars: 2 hidden ("(for limit)"/"(for step)") + visible,
  // scoped to the loop — 4 total here, matching lparser.c's fornum layout.
  r = analyze("local function fl()\n  for i = 1, 10 do local q = i end\nend\n");
  expect(fnRec(r, "fl") && fnRec(r, "fl").maxLocals === 4, "for loop = 2 hidden + i + q");

  // Method definitions declare an implicit self (no upvalue for it).
  r = analyze("local T = {}\nfunction T:m()\n  return self\nend\n");
  expect(fnRec(r, "T:m") && fnRec(r, "T:m").upvals === 0, "method self is a param, not an upvalue");

  // Declare-after-evaluate: a shadowing `local x = x` inside a nested
  // function captures the OUTER x — one upvalue, like the real 5.0 compiler.
  r = analyze("local x = 1\nlocal function sh()\n  local x = x\n  return x\nend\n");
  expect(fnRec(r, "sh") && fnRec(r, "sh").upvals === 1,
    "shadowing local x = x captures the outer x");

  // Same rule for for-loop control variables: bound expressions read the
  // outer binding.
  r = analyze("local i = 1\nlocal function fb()\n  for i = i, 10 do end\nend\n");
  expect(fnRec(r, "fb") && fnRec(r, "fb").upvals === 1,
    "for bound `i = i` reads the outer i");

  // Multi-assignment inside a function literal placed directly in a table
  // constructor: the non-first LHS names are references, not table keys.
  r = analyze("local a = 1\nlocal b = 2\nlocal t = { h = function() a, b = 1, 2 end }\n");
  expect(fnRec(r, "anonymous") && fnRec(r, "anonymous").upvals === 2,
    "multi-assign inside table-embedded function counts both upvalues");

  // A `do ... end` inside a function literal embedded in a for-header bound
  // must not consume the loop's own `do` (pendingForDo nests per function).
  r = analyze("local function fd()\n  for i = 1, (function() do end return 1 end)() do local q = i end\nend\n");
  expect(fnRec(r, "fd") && fnRec(r, "fd").maxLocals === 4,
    "for-header function do-block does not eat the loop's do (2 hidden + i + q)");

  if (failures > 0) {
    console.error(failures + " selftest failure(s)");
    process.exit(1);
  }
  console.log("closure-counter selftests pass");
  process.exit(0);
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

  // Per-function closure limits (upvalues / locals) — see analyzeClosures.
  analyzeClosures(tokens, report);

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

if (process.argv.indexOf("--selftest") !== -1) {
  selftest();
}

const files = process.argv.slice(2);
if (files.length === 0) {
  console.error("usage: node lua50check.js <files.lua...> | node lua50check.js --selftest");
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
