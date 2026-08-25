// WHEP-style same-origin signaling per PROTOCOL.md "Transports".
//
// Auth: PROTOCOL.md contracts only {"sessionId"} in the POST /api/session
// response body and says the server "sets an auth cookie/bearer" — the
// `bearer` JSON field itself is a wowstreamd extension, not spec-guaranteed.
// When present we send it as an Authorization header (immune to cookie
// policy quirks in installed PWAs); when absent we send no header and rely
// on the auth cookie, which same-origin fetch attaches by default
// (credentials: 'same-origin'). Either way a spec-conforming server works.

/** Thrown for a 401 on POST /api/session: the pairing token is wrong/rotated. */
export class AuthError extends Error {
  constructor() {
    super('pairing token rejected');
    this.name = 'AuthError';
  }
}

/** Any other non-OK signaling response. */
export class SignalError extends Error {
  constructor(step, status, detail) {
    super(`${step} failed: HTTP ${status}${detail ? ` — ${detail}` : ''}`);
    this.name = 'SignalError';
    this.status = status;
  }
}

async function errDetail(res) {
  try {
    return (await res.text()).trim().slice(0, 200);
  } catch {
    return '';
  }
}

/** Authorization header for a session, or nothing when cookie auth applies. */
function authHeaders(session) {
  return session.bearer ? { Authorization: `Bearer ${session.bearer}` } : {};
}

/**
 * POST /api/session
 * @returns {Promise<{sessionId:string, bearer?:string}>} `bearer` only when
 *   the server returns it (see the auth note in the file header).
 */
export async function createSession(token) {
  const res = await fetch('/api/session', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ token }),
  });
  if (res.status === 401) throw new AuthError();
  if (res.status !== 201) throw new SignalError('session create', res.status, await errDetail(res));
  return res.json();
}

/**
 * POST /api/session/{id}/offer — SDP in, SDP answer out.
 * @returns {Promise<string>} the answer SDP
 */
export async function sendOffer(session, sdp) {
  const res = await fetch(`/api/session/${encodeURIComponent(session.sessionId)}/offer`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/sdp', ...authHeaders(session) },
    body: sdp,
  });
  if (res.status !== 201) throw new SignalError('SDP offer', res.status, await errDetail(res));
  return res.text();
}

/**
 * DELETE /api/session/{id} — fire-and-forget teardown. keepalive lets the
 * request survive pagehide. Failures are ignored: the server's replace-on-new
 * -session and dead-man rules make cleanup best-effort by design.
 */
export function deleteSession(session, { keepalive = false } = {}) {
  fetch(`/api/session/${encodeURIComponent(session.sessionId)}`, {
    method: 'DELETE',
    headers: authHeaders(session),
    keepalive,
  }).catch(() => {});
}
