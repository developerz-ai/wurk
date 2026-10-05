// The dashboard's only network entry points — pages never call `fetch`
// directly. `fetch` only rejects on a network failure (a 4xx/5xx still
// resolves), so `post`/`getJSON` throw a RequestError on non-2xx to drive
// solid-query's error path instead of casting an error payload to the success
// shape. The status (and, for `post`, any JSON error body) rides on the error
// so callers can surface a status-aware message (see notifyError in ./toast).
export class RequestError extends Error {
  readonly status: number;
  readonly body: unknown;

  constructor(status: number, body?: unknown) {
    super(`Request failed (${status})`);
    this.name = 'RequestError';
    this.status = status;
    this.body = body;
  }
}

// Body of a 422 from a job-set action (ApiController#render_applied): some
// entries applied, the listed keys failed and were put back in their set.
export interface PartialFailure {
  ok: false;
  count: number;
  failed: { key: string; error: string }[];
}

export function partialFailure(err: unknown): PartialFailure | null {
  if (!(err instanceof RequestError) || err.status !== 422) return null;
  const body = err.body as Partial<PartialFailure> | null | undefined;
  return body && Array.isArray(body.failed) && typeof body.count === 'number' ? (body as PartialFailure) : null;
}

// POST to `url`, JSON-encoding `body` when present. Throws RequestError
// (carrying the parsed JSON error body, when there is one) on a non-2xx
// response; resolves to the Response otherwise.
export async function post(url: string, body?: unknown): Promise<Response> {
  const res = await fetch(url, {
    method: 'POST',
    headers: body === undefined ? {} : { 'Content-Type': 'application/json' },
    body: body === undefined ? undefined : JSON.stringify(body),
  });
  if (!res.ok) throw new RequestError(res.status, await res.json().catch(() => undefined));
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

// Fetch `url` as text without throwing on a non-2xx status. Server-rendered
// extension views hand back an HTML body worth showing even on a 404, so the
// caller decides what a status means.
export async function fetchText(url: string, init?: RequestInit): Promise<{ ok: boolean; status: number; text: string }> {
  const res = await fetch(url, init);
  return { ok: res.ok, status: res.status, text: await res.text() };
}
