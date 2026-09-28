"""Offline replay must not outrun the initialized release-response route."""
from pathlib import Path
import runpy
from types import SimpleNamespace
import unittest
from unittest.mock import patch


DRIVER = Path(__file__).parents[1] / 'ci-lightning-async'


class Recipient:
    """Model distinct TCP acceptance, Init, and notification replay events."""
    def __init__(self, return_provider, notification_provider, init_after=None, status_error=None):
        self.return_provider, self.notification_provider = return_provider, notification_provider
        self.init_after, self.status_error = init_after, status_error
        self.started, self.stopped = 0, 5
        self.starts, self.status_reads = 0, 0
        self.connections = []
        self.initialized = False
        self.notification_replayed = False

    def start(self):
        self.starts += 1
        self.started, self.stopped = 10, None

    def call(self, command, **values):
        if command == 'connect':
            self.connections.append(values['peer'])
            if values['peer'] == self.notification_provider.node:
                if not self.initialized:
                    raise AssertionError('Held notification replayed before its return route completed Init')
                self.notification_replayed = True
            # Successful TCP acceptance deliberately does not set initialized.
            return {'connected': True}
        if command != 'status':
            raise AssertionError('Unexpected protocol or financial command')
        self.status_reads += 1
        if self.status_error is not None:
            raise self.status_error
        self.initialized = self.init_after is not None and self.status_reads >= self.init_after
        peers = [self.return_provider.node] if self.initialized else [self.notification_provider.node]
        return {'peers': peers}


class AsyncRecipientReadinessTests(unittest.TestCase):
    def setUp(self):
        self.module = runpy.run_path(str(DRIVER))
        self.reconnect = self.module['reconnect_async_recipient']
        self.return_provider = SimpleNamespace(node='holding-provider-a', initial={'port': 21001})
        self.notification_provider = SimpleNamespace(node='receiving-provider-b', initial={'port': 22001})

    def test_notification_replay_waits_for_init_not_successful_tcp_connect(self):
        recipient = Recipient(self.return_provider, self.notification_provider, init_after=3)
        stopped = recipient.stopped
        with patch.object(self.module['time'], 'sleep'):
            self.reconnect(recipient, self.return_provider, self.notification_provider)
        self.assertTrue(recipient.notification_replayed)
        self.assertEqual(recipient.status_reads, 3)
        self.assertEqual(recipient.connections, [self.return_provider.node, self.notification_provider.node])
        self.assertEqual(recipient.starts, 1)
        self.assertEqual((stopped, recipient.started), (5, 10))

    def test_tcp_acceptance_without_init_hits_original_deadline_without_replay(self):
        recipient = Recipient(self.return_provider, self.notification_provider)
        # Use the real wait with its original 45-second deadline, advancing a
        # monotonic clock after one non-ready status response without sleeping.
        with patch.object(self.module['time'], 'monotonic', side_effect=[0, 0, 45]), \
             patch.object(self.module['time'], 'sleep'):
            with self.assertRaisesRegex(TimeoutError, 'Async peer condition did not become true'):
                self.reconnect(recipient, self.return_provider, self.notification_provider)
        self.assertEqual(recipient.connections, [self.return_provider.node])
        self.assertEqual(recipient.status_reads, 1)
        self.assertFalse(recipient.notification_replayed)
        self.assertEqual(recipient.starts, 1)

    def test_failed_init_observation_is_fatal_without_notification_connect_or_retry(self):
        failure = RuntimeError('peer exited during Init')
        recipient = Recipient(self.return_provider, self.notification_provider, status_error=failure)
        with self.assertRaises(RuntimeError) as caught:
            self.reconnect(recipient, self.return_provider, self.notification_provider)
        self.assertIs(caught.exception, failure)
        self.assertEqual(recipient.connections, [self.return_provider.node])
        self.assertFalse(recipient.notification_replayed)
        self.assertEqual((recipient.starts, recipient.status_reads), (1, 1))


if __name__ == '__main__':
    unittest.main()
