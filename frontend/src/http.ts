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

// GET `url` and parse the JSON body as `T`. Throws RequestError on a non-2xx
// response so solid-query routes it to the error state — otherwise a 4xx/5xx
// error payload is cast to the success shape and the render path dereferences
// fields that aren't there.
export async function getJSON<T>(url: string): Promise<T> {
  const res = await fetch(url);
  if (!res.ok) throw new RequestError(res.status);
  return res.json() as Promise<T>;
}
