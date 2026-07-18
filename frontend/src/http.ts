// Shared HTTP helpers for the dashboard's mutating endpoints. `fetch` only
// rejects on a network failure — a 4xx/5xx still resolves — so `post` throws a
// RequestError on non-2xx to drive solid-query's onError (and skip onSuccess /
// cache invalidation). The status rides on the error so callers can surface a
// status-aware message (see notifyError in ./toast).
export class RequestError extends Error {
  readonly status: number;

  constructor(status: number) {
    super(`Request failed (${status})`);
    this.name = 'RequestError';
    this.status = status;
  }
}

// POST to `url`, JSON-encoding `body` when present. Throws RequestError on a
// non-2xx response; resolves to the Response otherwise.
export async function post(url: string, body?: unknown): Promise<Response> {
  const res = await fetch(url, {
    method: 'POST',
    headers: body === undefined ? {} : { 'Content-Type': 'application/json' },
    body: body === undefined ? undefined : JSON.stringify(body),
  });
  if (!res.ok) throw new RequestError(res.status);
  return res;
}
