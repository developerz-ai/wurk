"""End-to-end: wurk_client.Client against a real `exe/wurk api` and Redis.

Skipped unless WURK_E2E_REDIS_URL names a Redis this test may write to. The
URL must select a database other than 0 (`redis://host:port/<db>`), because
DB 0 is where real data lives. The server runs under the repo's test/dummy
bundle, which carries a web server (puma); WURK_E2E_BUNDLE_GEMFILE overrides
which Gemfile that is.

Nothing here reads Redis directly: every assertion goes back through the API,
so what is proved is the client and the server agreeing over a real socket.
"""

from __future__ import annotations

import os
import secrets
import socket
import subprocess
import sys
import tempfile
import time
import unittest
import urllib.error
import urllib.parse
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "src"))

from wurk_client import Client, WurkAPIError  # noqa: E402

REPO = Path(__file__).resolve().parents[3]
REDIS_URL = os.environ.get("WURK_E2E_REDIS_URL")
BOOT_TIMEOUT = 60.0


def _database(url: str) -> int:
    path = urllib.parse.urlparse(url).path.strip("/")
    return int(path) if path.isdigit() else 0


def _free_port() -> int:
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        return sock.getsockname()[1]


@unittest.skipUnless(REDIS_URL, "set WURK_E2E_REDIS_URL to a throwaway Redis DB to run")
class EndToEndTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        if _database(REDIS_URL) == 0:
            raise unittest.SkipTest("WURK_E2E_REDIS_URL must select a database other than 0")

        token = secrets.token_hex(16)
        port = _free_port()
        env = {
            **os.environ,
            "REDIS_URL": REDIS_URL,
            "WURK_E2E_TOKEN": token,
            "BUNDLE_GEMFILE": os.environ.get("WURK_E2E_BUNDLE_GEMFILE", str(REPO / "test/dummy/Gemfile")),
        }
        command = [
            "bundle", "exec", "ruby", str(REPO / "exe/wurk"), "api",
            "-r", str(Path(__file__).with_name("e2e_app.rb")),
            "--bind", "127.0.0.1", "--port", str(port),
        ]
        # A file, not a pipe: nothing drains a pipe while tests run, and a server
        # that fills one blocks on its next log line.
        cls.log = tempfile.TemporaryFile()
        cls.server = subprocess.Popen(command, env=env, stdout=cls.log, stderr=subprocess.STDOUT)
        cls.client = Client(f"http://127.0.0.1:{port}", token=token)
        cls.base_url = f"http://127.0.0.1:{port}"
        cls._wait_for_boot()

    @classmethod
    def tearDownClass(cls):
        cls.server.terminate()
        try:
            cls.server.wait(timeout=10)
        except subprocess.TimeoutExpired:
            cls.server.kill()
            cls.server.wait()
        cls.log.close()

    @classmethod
    def _wait_for_boot(cls):
        deadline = time.monotonic() + BOOT_TIMEOUT
        while time.monotonic() < deadline:
            if cls.server.poll() is not None:
                cls.log.seek(0)
                output = cls.log.read().decode("utf-8", errors="replace")
                raise RuntimeError(f"wurk api exited with {cls.server.returncode}:\n{output}")
            try:
                cls.client.discover()
                return
            except (urllib.error.URLError, ConnectionError):
                time.sleep(0.2)
        cls.tearDownClass()
        raise RuntimeError(f"wurk api did not answer within {BOOT_TIMEOUT}s")

    def setUp(self):
        self.queue = f"e2e-{secrets.token_hex(6)}"
        self.addCleanup(self.client.clear_queue, self.queue)

    def test_discovery_names_the_contract(self):
        document = self.client.discover()

        self.assertEqual("v1", document["api_version"])
        self.assertEqual("/v1", document["url"])
        self.assertFalse(document["read_only"])

    def test_an_enqueued_job_is_listed_on_its_queue_as_sent(self):
        jid = self.client.enqueue("E2EWorker", args=[9_007_199_254_740_993, "naïve", {"k": [1]}], queue=self.queue)

        listing = self.client.queue(self.queue)

        self.assertEqual(1, listing["size"])
        self.assertEqual(jid, listing["jobs"][0]["jid"])
        self.assertEqual("E2EWorker", listing["jobs"][0]["class"])
        self.assertEqual([9_007_199_254_740_993, "naïve", {"k": [1]}], listing["jobs"][0]["args"])
        self.assertIn(self.queue, [queue["name"] for queue in self.client.queues()])

    def test_bulk_enqueues_one_job_per_args_array(self):
        jids = self.client.bulk("E2EWorker", [[1], [2], [3]], queue=self.queue)

        self.assertEqual(3, len(jids))
        self.assertEqual(3, self.client.queue(self.queue)["size"])

    def test_a_resent_enqueue_under_one_key_enqueues_once(self):
        key = f"e2e-{secrets.token_hex(6)}"
        first = self.client.enqueue("E2EWorker", args=[1], queue=self.queue, idempotency_key=key)
        second = self.client.enqueue("E2EWorker", args=[1], queue=self.queue, idempotency_key=key)

        self.assertEqual(first, second)
        self.assertEqual(1, self.client.queue(self.queue)["size"])

    def test_a_scheduled_job_can_be_cancelled_once(self):
        jid = self.client.enqueue("E2EWorker", args=[], queue=self.queue, at=time.time() + 3600)

        self.assertEqual({"jid": jid, "set": "schedule"}, self.client.cancel(jid))
        with self.assertRaises(WurkAPIError) as ctx:
            self.client.cancel(jid)
        self.assertEqual("job_not_found", ctx.exception.type)

    def test_pause_and_unpause_report_the_resulting_state(self):
        self.assertTrue(self.client.pause_queue(self.queue)["paused"])
        self.assertTrue(self.client.queue(self.queue)["paused"])
        self.assertFalse(self.client.unpause_queue(self.queue)["paused"])

    def test_clear_empties_the_queue(self):
        self.client.bulk("E2EWorker", [[1], [2]], queue=self.queue)

        self.assertEqual({"name": self.queue, "cleared": True}, self.client.clear_queue(self.queue))
        self.assertEqual(0, self.client.queue(self.queue)["size"])

    def test_retrying_a_job_that_is_not_in_the_set_is_job_not_found(self):
        for retry in (self.client.retry_retrying, self.client.retry_dead):
            with self.assertRaises(WurkAPIError) as ctx:
                retry(secrets.token_hex(12))
            self.assertEqual(404, ctx.exception.status)
            self.assertEqual("job_not_found", ctx.exception.type)

    def test_batches_and_stats_answer(self):
        self.client.enqueue("E2EWorker", args=[], queue=self.queue)

        self.assertIn("batches", self.client.batches())
        self.assertGreaterEqual(self.client.stats()["enqueued"], 1)

    def test_a_wrong_token_is_unauthorized(self):
        with self.assertRaises(WurkAPIError) as ctx:
            Client(self.base_url, token="not-the-token").queues()

        self.assertEqual(401, ctx.exception.status)
        self.assertEqual("unauthorized", ctx.exception.type)


if __name__ == "__main__":
    unittest.main()
