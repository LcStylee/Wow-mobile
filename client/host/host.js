// WoW Mobile — host dashboard logic. Polls GET /host/api/status once per
// second and renders the checklist, pairing URL, phone state, and stream
// stats. Everything is served loopback-only by the signal server; no token is
// needed to open this page.
"use strict";

(() => {
  const $ = (id) => document.getElementById(id);

  const STEP_ICONS = {
    pending: "○",
    running: "◌",
    ok: "✓",
    skipped: "–",
    failed: "✕",
  };

  const CLIENT_TYPE_LABELS = {
    classicEra: "WoW Classic Era (1.15)",
    forever: "WoW: Forever (1.60)",
    legacy: "1.12-era client (private server)",
  };

  let quitRequested = false;
  // Phone picker state (frame layout): the table from /host/api/phones and
  // the server's current choice.
  let phoneTable = null;
  let currentPhone = "";
  let missedPolls = 0;

  function renderSteps(steps) {
    const ul = $("steps");
    // Rebuild only when the shape changed; otherwise update in place so
    // text selection survives the 1 s polling.
    if (ul.childElementCount !== steps.length) {
      ul.textContent = "";
      for (const step of steps) {
        const li = document.createElement("li");
        li.dataset.id = step.id;
        const icon = document.createElement("span");
        icon.className = "step-icon";
        const label = document.createElement("span");
        label.className = "step-label";
        const detail = document.createElement("span");
        detail.className = "step-detail";
        li.append(icon, label, detail);
        ul.append(li);
      }
    }
    steps.forEach((step, i) => {
      const li = ul.children[i];
      li.dataset.state = step.state;
      li.children[0].textContent = STEP_ICONS[step.state] || "○";
      li.children[1].textContent = step.label;
      li.children[2].textContent = step.detail || "";
    });
  }

  function render(st) {
    $("version").textContent = st.version || "";

    renderSteps(st.steps || []);

    // Live misconfiguration warning (e.g. WoW window vs. configured
    // resolution). The stream keeps running — capture adapts to the real
    // window — so this is a call to action, not a failure state.
    const warning = $("warning");
    warning.hidden = !st.warning;
    warning.textContent = st.warning || "";

    // Live capture-health banner: the running capture yields no frames;
    // carries ffmpeg's stderr tail so the black stream explains itself.
    const capWarning = $("capture-warning");
    capWarning.hidden = !st.captureWarning;
    capWarning.textContent = st.captureWarning || "";

    // Startup pipeline self-check verdict.
    const selfCheck = $("self-check");
    selfCheck.textContent = st.selfCheck || "checking…";
    selfCheck.classList.toggle("bad", Boolean(st.selfCheck) && !st.selfCheckOk);

    const note = $("addon-note");
    note.hidden = !st.addonNote;
    note.textContent = st.addonNote || "";

    const url = st.pairingUrl || "";
    if (url && $("pair-url").textContent !== url) {
      $("pair-url").textContent = url;
    }

    $("encoder").textContent = st.encoder || "probing…";
    $("resolution").textContent = st.resolution || "–";
    // Live stream framing (phone-frame contract): e.g. "phone frame
    // 1203x2148 of 3840x2160 (encoded at 1074x1920) — frame: addon outline".
    $("layout").textContent = st.layout || "–";
    $("client-type").textContent = CLIENT_TYPE_LABELS[st.clientType] || "–";
    // The change-game affordance only makes sense once a game was chosen.
    $("game-hint").hidden = !st.clientType;

    // Phone picker: only in frame layout (the server reports phoneModel).
    $("phone-picker").hidden = !st.phoneModel;
    if (st.phoneModel && st.phoneModel !== currentPhone) {
      currentPhone = st.phoneModel;
      if (!phoneTable) loadPhones();
      else renderPhones();
    }

    const phone = st.phone || {};
    const phoneEl = $("phone");
    if (phone.connected) {
      phoneEl.textContent =
        "connected" + (phone.remote ? " — " + phone.remote : "");
      phoneEl.classList.add("on");
      phoneEl.title = phone.userAgent || "";
    } else {
      phoneEl.textContent = st.running
        ? "waiting for phone — scan the QR code"
        : "not connected";
      phoneEl.classList.remove("on");
      phoneEl.title = "";
    }

    const stream = st.stream || {};
    $("stream").hidden = !phone.connected;
    if (phone.connected) {
      $("s-kbps").textContent = Math.round(stream.kbps || 0);
      $("s-fps").textContent = Math.round(stream.fps || 0);
      $("s-enc").textContent = (stream.encodeMs || 0).toFixed(1);
      // Capture diagnostics: total access units captured vs. handed to the
      // WebRTC track, and how stale the newest keyframe is (healthy 2 s GOP
      // keeps it under ~2 s; "–" until the first IDR).
      $("s-frames").textContent =
        (stream.framesCaptured || 0) + "/" + (stream.framesSent || 0);
      const idrMs = stream.lastKeyframeAgeMs;
      $("s-idr").textContent =
        idrMs == null || idrMs < 0 ? "–" : (idrMs / 1000).toFixed(1) + "s";
    }
  }

  async function poll() {
    try {
      const res = await fetch("/host/api/status", { cache: "no-store" });
      if (!res.ok) throw new Error("status " + res.status);
      render(await res.json());
      missedPolls = 0;
      if (!quitRequested) $("offline").hidden = true;
    } catch {
      // One blip is a refresh race; three misses (or an explicit quit)
      // means the server is really gone.
      missedPolls += 1;
      if (quitRequested || missedPolls >= 3) $("offline").hidden = false;
    }
  }

  async function loadPhones() {
    try {
      const res = await fetch("/host/api/phones", { cache: "no-store" });
      if (!res.ok) return;
      phoneTable = await res.json();
      renderPhones();
    } catch {
      // Next status change retries.
    }
  }

  // Substring search over "name id", every term must match; ranked phones
  // first (the table arrives in selector order).
  function renderPhones() {
    const list = $("phone-list");
    const terms = $("phone-search").value.toLowerCase().split(/\s+/).filter(Boolean);
    list.textContent = "";
    for (const p of phoneTable || []) {
      const hay = (p.name + " " + p.id).toLowerCase();
      if (!terms.every((t) => hay.includes(t))) continue;
      const li = document.createElement("li");
      li.role = "option";
      li.dataset.id = p.id;
      li.setAttribute("aria-selected", String(p.id === currentPhone));
      const name = document.createElement("span");
      name.textContent = (p.popularity ? p.popularity + ". " : "") + p.name;
      const dims = document.createElement("small");
      dims.textContent = p.streamW + "×" + p.streamH;
      li.append(name, dims);
      li.addEventListener("click", () => pickPhone(p.id));
      list.append(li);
    }
  }

  async function pickPhone(id) {
    try {
      // Custom header = the server's CSRF guard (see quit()).
      const res = await fetch("/host/api/phone", {
        method: "POST",
        headers: { "Content-Type": "application/json", "X-Wowmobile-Phone": "1" },
        body: JSON.stringify({ id }),
      });
      if (res.ok) {
        currentPhone = id;
        renderPhones();
      }
    } catch {
      // Server gone: the offline overlay covers it.
    }
  }

  function copyPairingURL() {
    const url = $("pair-url").textContent;
    const done = () => {
      const btn = $("copy");
      btn.textContent = "Copied";
      btn.classList.add("done");
      setTimeout(() => {
        btn.textContent = "Copy";
        btn.classList.remove("done");
      }, 1500);
    };
    if (navigator.clipboard && navigator.clipboard.writeText) {
      navigator.clipboard.writeText(url).then(done, () => fallbackCopy(url, done));
    } else {
      fallbackCopy(url, done);
    }
  }

  // execCommand fallback for non-secure contexts (--no-tls debugging).
  function fallbackCopy(text, done) {
    const ta = document.createElement("textarea");
    ta.value = text;
    ta.style.position = "fixed";
    ta.style.opacity = "0";
    document.body.append(ta);
    ta.select();
    try {
      document.execCommand("copy");
      done();
    } finally {
      ta.remove();
    }
  }

  async function quit() {
    if (!window.confirm("Quit WoW Mobile? Streaming stops; WoW keeps running.")) {
      return;
    }
    quitRequested = true;
    try {
      // The custom header is the server's CSRF guard: a malicious website in
      // a browser on this PC can send a no-cors POST from a loopback peer,
      // but it cannot attach this header.
      await fetch("/host/api/quit", {
        method: "POST",
        headers: { "X-Wowmobile-Quit": "1" },
      });
    } catch {
      // Already gone — the overlay below covers it.
    }
    $("offline").hidden = false;
  }

  $("copy").addEventListener("click", copyPairingURL);
  $("quit").addEventListener("click", quit);
  $("phone-search").addEventListener("input", renderPhones);

  poll();
  setInterval(poll, 1000);
})();
