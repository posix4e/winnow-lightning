"""Reference startup recovery must never turn a protocol failure into a pass."""
import json
from pathlib import Path
import runpy
import tempfile
import unittest
from unittest.mock import Mock, patch

SCRIPT = Path(__file__).resolve().parents[1] / 'ci-lightning-peer'
CRASH = '''DEBUG chan#1: Got opening_fundee_finish_response
INFO chan#1: Peer transient failure in CHANNELD_AWAITING_LOCKIN: channeld: Owning subdaemon channeld died (0)
'''


class PeerStartupTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.log = self.root / 'cln.log'
        self.log.write_text(CRASH)
        self.module = runpy.run_path(str(SCRIPT))
        self.failure = self.module['ReferenceStartupFailure']

    def test_only_known_pre_signature_macos_crash_is_classified(self):
        receive = self.module['funding_signature']
        peer = Mock()
        peer.receive.side_effect = TimeoutError('no response')
        with patch('sys.platform', 'darwin'):
            with self.assertRaises(self.failure):
                receive(peer, self.log)
            for transcript in ('', CRASH.replace('(0)', '(9)'),
                               CRASH.replace('CHANNELD_AWAITING_LOCKIN', 'CHANNELD_NORMAL'),
                               CRASH.replace('Got opening_fundee_finish_response', ''),
                               CRASH + 'peer_out WIRE_FUNDING_SIGNED',
                               CRASH + 'peer_out WIRE_ERROR', CRASH + '**BROKEN** hsmd'):
                with self.subTest(transcript=transcript):
                    self.log.write_text(transcript)
                    with self.assertRaises(TimeoutError):
                        receive(peer, self.log)
        self.log.write_text(CRASH)
        with patch('sys.platform', 'linux'), self.assertRaises(TimeoutError):
            receive(peer, self.log)

    def test_protocol_rejection_and_success_are_not_reclassified(self):
        peer = Mock()
        peer.receive.side_effect = AssertionError('peer rejected protocol')
        with patch('sys.platform', 'darwin'), self.assertRaises(AssertionError):
            self.module['funding_signature'](peer, self.log)
        peer.receive.side_effect = None
        peer.receive.return_value = {'event': 'broadcast_funding', 'transaction': 'verified'}
        self.assertEqual(self.module['funding_signature'](peer, self.log), peer.receive.return_value)

    def test_retry_uses_fresh_fixture_and_retains_both_attempts(self):
        check = self.module['check_peer']
        directories = []

        def run(mode, evidence):
            directories.append(evidence)
            (evidence / 'cln.log').write_text(CRASH if len(directories) == 1 else 'passed')
            if len(directories) == 1:
                raise self.failure('reference startup')
            (evidence / 'opening-receipt.json').write_text(json.dumps({'result': 'passed', 'close_mode': mode}))

        evidence = self.root / 'results'
        with patch.dict(check.__globals__, run_peer=run):
            check('cooperative', evidence)
        self.assertEqual(directories, [evidence / 'attempt-1', evidence / 'attempt-2'])
        self.assertEqual((directories[0] / 'cln.log').read_text(), CRASH)
        receipt = json.loads((evidence / 'opening-receipt.json').read_text())
        self.assertEqual([item['result'] for item in receipt['attempts']], ['reference-startup-failure', 'passed'])

    def test_second_crash_or_any_other_failure_remains_fatal(self):
        check = self.module['check_peer']
        for index, (error, calls) in enumerate(((self.failure('startup'), 2),
                                              (AssertionError('bad signature or balance'), 1),
                                              (TimeoutError('payment stalled'), 1))):
            with self.subTest(error=error):
                evidence = self.root / str(index)
                run = Mock(side_effect=error)
                with patch.dict(check.__globals__, run_peer=run), self.assertRaises(type(error)):
                    check('force', evidence)
                self.assertEqual(run.call_count, calls)
                self.assertFalse((evidence / 'opening-receipt.json').exists())


if __name__ == '__main__':
    unittest.main()
