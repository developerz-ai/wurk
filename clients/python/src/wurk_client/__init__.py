"""Reference client for the Wurk HTTP API (`/v1`).

Thin on purpose: enqueue, bulk, status, queues — the four things
`docs/api-http.md` calls the producer surface, plumbed straight over
``urllib.request`` with zero third-party dependencies. It does not retry,
pool connections, or hide the wire format; a job you enqueue here is the
literal Sidekiq job hash the HTTP API documents, sent as JSON with no
reshaping on either end.

    from wurk_client import Client

    wurk = Client("https://jobs.example.com/wurk/api", token="...")
    jid = wurk.enqueue("HardWorker", args=[1, "two"], queue="default")
    wurk.status(jid)  # -> {"jid": ..., "state": "running", ...} (track: True jobs only)

``base_url`` is whatever prefix the deployment mounted the API under — see
"Mounting" in docs/api-http.md for the three shapes. This client always
appends the frozen ``/v1`` version prefix itself; never bake it into
``base_url``.
"""

from __future__ import annotations

import json
import urllib.error
import urllib.parse
import urllib.request
from dataclasses import dataclass
from typing import Any, Mapping, Sequence

__all__ = [
    "Client",
    "WurkError",
    "WurkAPIError",
    "RateLimitedError",
]

__version__ = "0.1.0"

_VERSION_PREFIX = "/v1"


class WurkError(Exception):
    """Base class for everything this client raises."""


class WurkAPIError(WurkError):
    """The server answered with an RFC-9457 problem+json document.

    `type` is the stable slug documented in docs/api-http.md's error table
    (e.g. ``"job_not_found"``, ``"read_only"``) — the field a caller should
    branch on, never `detail`, which is prose for a human.
    """

    def __init__(self, status: int, problem: Mapping[str, Any]):
        self.status = status
        self.type = problem.get("type", "unknown")
        self.title = problem.get("title", "")
        self.detail = problem.get("detail", "")
        self.problem = dict(problem)
        super().__init__(f"{status} {self.type}: {self.detail}")


class RateLimitedError(WurkAPIError):
    """A 429. `retry_after` mirrors the `Retry-After` header, in seconds."""

    def __init__(self, status: int, problem: Mapping[str, Any]):
        super().__init__(status, problem)
        self.retry_after = problem.get("retry_after")


@dataclass
class _Response:
    status: int
    body: Any


class Client:
    """One credential, one deployment.

    :param base_url: scheme + host + mount prefix, **without** ``/v1``
        (e.g. ``"https://host/wurk/api"``, ``"https://host/wurk-api"``, or
        ``"http://host:7433"`` for standalone mode).
    :param token: a bearer token registered on the server via
        ``config.api_token``. Its granted scopes (``enqueue`` / ``read`` /
        ``admin``) bound which methods below will succeed.
    :param timeout: socket timeout in seconds for every request.
    """

    def __init__(self, base_url: str, token: str, timeout: float = 10.0):
        self._base_url = base_url.rstrip("/")
        self._token = token
        self._timeout = timeout

    # -- discovery -----------------------------------------------------

    def discover(self) -> dict:
        """`GET /v1` — api_version, wurk_version, read_only, rate_limit."""
        return self._call("GET", "")

    # -- produce ---------------------------------------------------------

    def enqueue(
        self,
        job_class: str,
        args: Sequence[Any] = (),
        *,
        queue: str = "default",
        idempotency_key: str | None = None,
        **job_options: Any,
    ) -> str | None:
        """`POST /jobs`. Returns the jid, or None if client-side middleware on
        the server (`collapse:`, `unique_for:`) dropped the push — the same
        distinction `Wurk::Client#push` makes.

        Extra Sidekiq job options (``at``, ``retry``, ``tags``, ``timeout``,
        ``deadline``, ``track``, ...) pass straight through as keyword
        arguments; see docs/api-http.md's job-key table for the full set.
        """
        payload = {"class": job_class, "args": list(args), "queue": queue, **job_options}
        response = self._call("POST", "/jobs", body=payload, idempotency_key=idempotency_key)
        return response.get("jid")

    def bulk(
        self,
        job_class: str,
        args_list: Sequence[Sequence[Any]],
        *,
        queue: str = "default",
        idempotency_key: str | None = None,
        **envelope_options: Any,
    ) -> list[str | None]:
        """`POST /jobs/bulk`. Returns one jid per entry in `args_list`, in
        order, with None marking a push that a server-side hook dropped —
        never a shorter list, so the two stay index-aligned.
        """
        payload = {
            "class": job_class,
            "args": [list(args) for args in args_list],
            "queue": queue,
            **envelope_options,
        }
        response = self._call("POST", "/jobs/bulk", body=payload, idempotency_key=idempotency_key)
        return response.get("jids", [])

    def cancel(self, jid: str) -> dict:
        """`DELETE /jobs/:jid`. Removes a not-yet-run job from `schedule` or
        `retry` — not a cancel of one already handed to a processor.
        Requires the `admin` scope. Raises WurkAPIError(type="job_not_found")
        if it already ran, already died, or never existed.
        """
        return self._call("DELETE", f"/jobs/{_path_segment(jid)}")

    # -- status ------------------------------------------------------------

    def status(self, jid: str) -> dict:
        """`GET /jobs/:jid`. Only answers for a class that opted in with
        `track: True`; raises WurkAPIError(type="job_not_found") for an
        untracked, unknown, or expired jid — Redis holds nothing that tells
        those apart.
        """
        return self._call("GET", f"/jobs/{_path_segment(jid)}")

    # -- queues --------------------------------------------------------

    def queues(self) -> list[dict]:
        """`GET /queues` — every queue's name, size, latency, paused state."""
        return self._call("GET", "/queues").get("queues", [])

    def queue(self, name: str, *, page: int = 0, count: int = 25) -> dict:
        """`GET /queues/:name` — gauges plus a page of the jobs waiting in it."""
        return self._call("GET", f"/queues/{_path_segment(name)}", query={"page": page, "count": count})

    def pause_queue(self, name: str) -> dict:
        """`POST /queues/:name/pause`. Requires the `admin` scope."""
        return self._call("POST", f"/queues/{_path_segment(name)}/pause")

    def unpause_queue(self, name: str) -> dict:
        """`POST /queues/:name/unpause`. Requires the `admin` scope."""
        return self._call("POST", f"/queues/{_path_segment(name)}/unpause")

    def stats(self) -> dict:
        """`GET /stats` — the same counters `Wurk::Stats` feeds the dashboard."""
        return self._call("GET", "/stats")

    # -- transport -------------------------------------------------------

    def _call(
        self,
        method: str,
        path: str,
        *,
        body: Any = None,
        query: Mapping[str, Any] | None = None,
        idempotency_key: str | None = None,
    ) -> Any:
        response = self._request(method, f"{_VERSION_PREFIX}{path}", body=body, query=query,
                                  idempotency_key=idempotency_key)
        if response.status >= 400:
            problem = response.body if isinstance(response.body, dict) else {"detail": str(response.body)}
            error_cls = RateLimitedError if response.status == 429 else WurkAPIError
            raise error_cls(response.status, problem)
        return response.body

    def _request(
        self,
        method: str,
        path: str,
        *,
        body: Any,
        query: Mapping[str, Any] | None,
        idempotency_key: str | None,
    ) -> _Response:
        url = f"{self._base_url}{path}"
        if query:
            url += "?" + urllib.parse.urlencode({k: v for k, v in query.items() if v is not None})

        headers = {"Authorization": f"Bearer {self._token}", "Accept": "application/json"}
        data = None
        if body is not None:
            # `allow_nan=False` because Python's default emits the JavaScript
            # literals NaN/Infinity, which are not JSON — Ruby's parser rejects
            # them, so the server would answer 400 invalid_request. Better a
            # ValueError here, naming the argument, than a round trip to learn
            # the payload was never JSON in the first place.
            data = json.dumps(body, allow_nan=False).encode("utf-8")
            headers["Content-Type"] = "application/json"
        if idempotency_key is not None:
            headers["Idempotency-Key"] = idempotency_key

        request = urllib.request.Request(url, data=data, headers=headers, method=method)
        try:
            with urllib.request.urlopen(request, timeout=self._timeout) as raw:
                return _Response(status=raw.status, body=_parse(raw.read()))
        except urllib.error.HTTPError as error:
            return _Response(status=error.code, body=_parse(error.read()))


def _path_segment(value: str) -> str:
    """Percent-encode `value` as exactly one path segment.

    A jid is hex and a queue name usually isn't exotic, but neither is
    constrained to be: `/`, `?`, and `#` are all legal in a Sidekiq queue name
    and each would silently re-address the request. `safe=""` escapes them,
    and the server's router unescapes per segment (`lib/wurk/api/router.rb`),
    so the name it binds is the one that was passed in here.
    """
    return urllib.parse.quote(str(value), safe="")


def _parse(raw_bytes: bytes) -> Any:
    if not raw_bytes:
        return {}
    try:
        return json.loads(raw_bytes)
    except json.JSONDecodeError:
        return raw_bytes.decode("utf-8", errors="replace")
