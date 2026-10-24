/** The server side (wa-bridge function): one POST per action, authenticated by the branch's bridge key. */
export class ApiError extends Error {
  constructor(message, status) { super(message); this.status = status; }
}

export function createApi({ server, key }, { fetchImpl = globalThis.fetch, timeoutMs = 60_000 } = {}) {
  async function call(action, body, timeout = timeoutMs) {
    let res;
    try {
      res = await fetchImpl(server, {
        method: "POST",
        headers: { "content-type": "application/json", "x-bridge-key": key },
        body: JSON.stringify({ action, ...body }),
        signal: AbortSignal.timeout(timeout),
      });
    } catch (e) {
      throw new ApiError(e?.name === "TimeoutError" ? "timeout" : `network: ${e?.message ?? e}`, 0);
    }
    let data = {};
    try { data = await res.json(); } catch { data = {}; }
    if (!res.ok) throw new ApiError(String(data?.error ?? `http_${res.status}`), res.status);
    return data;
  }
  return {
    message: (b) => call("message", b),
    human: (b) => call("human", b, 30_000),
    poll: (b) => call("poll", b, ((b?.wait ?? 0) + 20) * 1000),
    ack: (b) => call("ack", b, 30_000),
    undelivered: (b) => call("undelivered", b, 30_000),
  };
}
