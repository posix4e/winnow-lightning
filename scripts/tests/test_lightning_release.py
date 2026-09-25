"""Release evidence must identify the source and survive independent readback."""
import copy
import hashlib
import runpy
from pathlib import Path
import json
import tempfile
import unittest
import subprocess
import sys

RELEASE = runpy.run_path(str(Path(__file__).resolve().parents[1] / 'release-lightning'))
SOURCE = 'a' * 40


class LightningReleaseTests(unittest.TestCase):
    def test_optimized_python_cannot_disable_release_validation(self):
        script = Path(__file__).resolve().parents[1] / 'release-lightning'
        result = subprocess.run([sys.executable, '-O', str(script), '--help'], text=True, capture_output=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('Release validation requires Python assertions', result.stderr)

    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        self.proof = self.root / 'proof.txt'
        self.proof.write_text('independent device and classification evidence')
        self.evidence = dict(source=SOURCE, bundle=RELEASE['BUNDLE'], physical_device=True,
            checks={name: 'passed' for name in ('owner_authentication', 'cancelled_authentication',
                'file_protection', 'exact_share', 'ipad', 'large_text')},
            artifacts=[dict(path='proof.txt', sha256=hashlib.sha256(self.proof.read_bytes()).hexdigest())],
            encryption=dict(mode='exempt', reviewed_by='test reviewer', rationale='test determination', artifact='proof.txt'))

    def verify(self, evidence):
        path = self.root / 'evidence.json'
        path.write_text(json.dumps(evidence))
        return RELEASE['check_evidence'](path, SOURCE)

    def test_reviewed_exemption_and_declaration_are_distinct(self):
        self.verify(self.evidence)
        self.evidence['encryption'].update(mode='declaration', declaration_id='approved-id')
        self.verify(self.evidence)

    def test_wrong_source_bundle_or_simulator_cannot_release(self):
        for field, value in [('source', 'b' * 40), ('bundle', 'com.btcswift.app'), ('physical_device', False)]:
            evidence = dict(self.evidence, **{field: value})
            with self.subTest(field=field), self.assertRaises(AssertionError):
                self.verify(evidence)

    def test_each_device_check_is_required(self):
        for name in self.evidence['checks']:
            evidence = copy.deepcopy(self.evidence)
            evidence['checks'][name] = 'pending'
            with self.subTest(name=name), self.assertRaises(AssertionError):
                self.verify(evidence)

    def test_changed_or_escaping_evidence_is_rejected(self):
        self.proof.write_text('changed')
        with self.assertRaises(AssertionError):
            self.verify(self.evidence)
        self.evidence['artifacts'][0]['path'] = '../elsewhere.txt'
        with self.assertRaises(AssertionError):
            self.verify(self.evidence)

    def test_encryption_cannot_default_to_exempt_or_unrecorded_claim(self):
        for field, value in [('mode', 'unknown'), ('reviewed_by', ''), ('rationale', ''), ('artifact', 'missing.txt')]:
            evidence = copy.deepcopy(self.evidence)
            evidence['encryption'][field] = value
            with self.subTest(field=field), self.assertRaises(AssertionError):
                self.verify(evidence)
