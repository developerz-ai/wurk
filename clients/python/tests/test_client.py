"""Unit tests for wurk_client.Client — mocks urllib at the socket boundary
(urlopen) so every test exercises the client's real request-building and
response-parsing code, not a stubbed method on the client itself.
"""

from __future__ import annotations

import io
import json
import sys
import unittest
import unittest.mock
import urllib.error
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "src"))

from wurk_client import Client, RateLimitedError, WurkAPIError  # noqa: E402


class _FakeHTTPResponse(io.BytesIO):
    def __init__(self, status: int, payload: bytes):
        super().__init__(payload)
        self.status = status

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        return False


def _json_response(status: int, body: dict) -> _FakeHTTPResponse:
    return _FakeHTTPResponse(status, json.dumps(body).encode("utf-8"))


class ClientTest(unittest.TestCase):
    def setUp(self):
        self.client = Client("https://wurk.example.com/wurk/api", token="test-token-0123456789")

    # -- enqueue -----------------------------------------------------

    def test_enqueue_posts_the_job_hash_verbatim_and_returns_the_jid(self):
        with unittest.mock.patch("urllib.request.urlopen") as urlopen:
            urlopen.return_value = _json_response(201, {"jid": "abc123"})

            jid = self.client.enqueue("HardWorker", args=[1, "two"], queue="critical", retry=5)

            request = urlopen.call_args[0][0]
            sent = json.loads(request.data)

            self.assertEqual("abc123", jid)
            self.assertEqual("POST", request.get_method())
            self.assertEqual("https://wurk.example.com/wurk/api/v1/jobs", request.full_url)
            self.assertEqual("Bearer test-token-0123456789", request.get_header("Authorization"))
            self.assertEqual(
                {"class": "HardWorker", "args": [1, "two"], "queue": "critical", "retry": 5}, sent
            )

    def test_enqueue_returns_none_when_the_server_reports_no_jid(self):
        # A collapse:/unique_for: drop on the server answers 200 with jid: null
        # — the producer's own policy working, not a failure.
        with unittest.mock.patch("urllib.request.urlopen") as urlopen:
            urlopen.return_value = _json_response(200, {"jid": None})

            self.assertIsNone(self.client.enqueue("HardWorker", args=[1]))

    def test_enqueue_sends_the_idempotency_key_header_when_given(self):
        with unittest.mock.patch("urllib.request.urlopen") as urlopen:
            urlopen.return_value = _json_response(201, {"jid": "abc123"})

            self.client.enqueue("HardWorker", args=[1], idempotency_key="retry-1")

            request = urlopen.call_args[0][0]
            self.assertEqual("retry-1", request.get_header("Idempotency-key"))

    # -- bulk ----------------------------------------------------------

    def test_bulk_sends_one_args_array_per_job_and_returns_index_aligned_jids(self):
        with unittest.mock.patch("urllib.request.urlopen") as urlopen:
            urlopen.return_value = _json_response(201, {"jids": ["a", None, "c"]})

            jids = self.client.bulk("HardWorker", [[1], [2], [3]], batch_size=100)

            request = urlopen.call_args[0][0]
            sent = json.loads(request.data)

            self.assertEqual(["a", None, "c"], jids)
            self.assertEqual([[1], [2], [3]], sent["args"])
            self.assertEqual(100, sent["batch_size"])
            self.assertEqual("https://wurk.example.com/wurk/api/v1/jobs/bulk", request.full_url)

    # -- status ----------------------------------------------------------

    def test_status_returns_the_record(self):
        record = {"jid": "abc123", "state": "complete", "result": {"ok": True}}
        with unittest.mock.patch("urllib.request.urlopen") as urlopen:
            urlopen.return_value = _json_response(200, record)

            self.assertEqual(record, self.client.status("abc123"))
            request = urlopen.call_args[0][0]
            self.assertEqual("GET", request.get_method())
            self.assertEqual("https://wurk.example.com/wurk/api/v1/jobs/abc123", request.full_url)

    def test_status_raises_a_typed_error_for_an_untracked_or_unknown_jid(self):
        problem = {
            "type": "job_not_found",
            "title": "Job Not Found",
            "status": 404,
            "detail": "No status is recorded for jid abc123.",
        }
        with unittest.mock.patch("urllib.request.urlopen") as urlopen:
            urlopen.side_effect = urllib.error.HTTPError(
                "url", 404, "Not Found", {}, io.BytesIO(json.dumps(problem).encode("utf-8"))
            )

            with self.assertRaises(WurkAPIError) as ctx:
                self.client.status("abc123")

            self.assertEqual(404, ctx.exception.status)
            self.assertEqual("job_not_found", ctx.exception.type)

    # -- queues ----------------------------------------------------------

    def test_queues_returns_the_listing(self):
        with unittest.mock.patch("urllib.request.urlopen") as urlopen:
            urlopen.return_value = _json_response(
                200, {"queues": [{"name": "default", "size": 3, "latency": 0.1, "paused": False}]}
            )

            queues = self.client.queues()

            self.assertEqual(1, len(queues))
            self.assertEqual("default", queues[0]["name"])

    def test_queue_pages_by_name_with_query_params(self):
        with unittest.mock.patch("urllib.request.urlopen") as urlopen:
            urlopen.return_value = _json_response(
                200, {"name": "default", "size": 1, "latency": 0.0, "paused": False, "page": 1, "count": 10,
                      "jobs": []}
            )

            self.client.queue("default", page=1, count=10)

            request = urlopen.call_args[0][0]
            self.assertIn("page=1", request.full_url)
            self.assertIn("count=10", request.full_url)

    # A queue name is an opaque Redis string, so `/`, `?` and `#` are all legal
    # in one. Interpolated raw they would re-address the request — a `/` splits
    # into two segments and misses the route, a `?` starts a query string.
    def test_a_queue_name_with_reserved_characters_is_encoded_as_one_segment(self):
        with unittest.mock.patch("urllib.request.urlopen") as urlopen:
            urlopen.return_value = _json_response(200, {"name": "a/b?c#d", "jobs": []})

            self.client.queue("a/b?c#d")

            request = urlopen.call_args[0][0]
            self.assertIn("/v1/queues/a%2Fb%3Fc%23d?", request.full_url)

    def test_reserved_characters_are_encoded_in_every_dynamic_segment(self):
        calls = [
            (lambda: self.client.status("a/b"), "/v1/jobs/a%2Fb"),
            (lambda: self.client.cancel("a/b"), "/v1/jobs/a%2Fb"),
            (lambda: self.client.pause_queue("a/b"), "/v1/queues/a%2Fb/pause"),
            (lambda: self.client.unpause_queue("a/b"), "/v1/queues/a%2Fb/unpause"),
        ]
        for call, expected_path in calls:
            with unittest.mock.patch("urllib.request.urlopen") as urlopen:
                urlopen.return_value = _json_response(200, {})

                call()

                self.assertEqual(
                    f"https://wurk.example.com/wurk/api{expected_path}",
                    urlopen.call_args[0][0].full_url,
                )

    # -- serialization -----------------------------------------------------

    # Python's json.dumps emits the JavaScript literals NaN/Infinity by
    # default, which are not JSON: the server's parser rejects them and answers
    # 400 invalid_request. Fail here instead, before the round trip.
    def test_a_non_finite_argument_raises_before_a_request_is_sent(self):
        for value in (float("nan"), float("inf"), float("-inf")):
            with unittest.mock.patch("urllib.request.urlopen") as urlopen:
                with self.assertRaises(ValueError):
                    self.client.enqueue("HardWorker", args=[value])

                urlopen.assert_not_called()

    # -- errors ------------------------------------------------------------

    def test_rate_limited_raises_with_retry_after(self):
        problem = {
            "type": "rate_limited",
            "title": "Too Many Requests",
            "status": 429,
            "detail": "This token is limited to 10 requests per minute.",
            "retry_after": 7,
        }
        with unittest.mock.patch("urllib.request.urlopen") as urlopen:
            urlopen.side_effect = urllib.error.HTTPError(
                "url", 429, "Too Many Requests", {}, io.BytesIO(json.dumps(problem).encode("utf-8"))
            )

            with self.assertRaises(RateLimitedError) as ctx:
                self.client.enqueue("HardWorker", args=[])

            self.assertEqual(7, ctx.exception.retry_after)


if __name__ == "__main__":
    unittest.main()
