from pathlib import Path
import json
import runpy
import tempfile
import unittest

TOOL = runpy.run_path(str(Path(__file__).resolve().parents[1] / 'ci-crap'))


class CoverageCollectorTests(unittest.TestCase):
    def file(self, root, name):
        path = root / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(b'evidence')
        return path.resolve()

    def test_package_requires_one_profile_and_compiled_tests(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            with self.assertRaises(ValueError):
                TOOL['package_inputs'](root)
            profile = self.file(root, 'debug/codecov/default.profdata')
            with self.assertRaises(ValueError):
                TOOL['package_inputs'](root)
            binary = self.file(root, 'debug/CoreTests.xctest/Contents/MacOS/CoreTests')
            self.assertEqual(TOOL['package_inputs'](root), (profile, [binary]))
            self.file(root, 'other/codecov/default.profdata')
            with self.assertRaises(ValueError):
                TOOL['package_inputs'](root)

    def test_flat_bundle_and_symlinks_are_deduplicated(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            profile = self.file(root, 'actual/codecov/default.profdata')
            binary = self.file(root, 'actual/CoreTests.xctest/CoreTests')
            (root / 'alias').symlink_to(root / 'actual', target_is_directory=True)
            self.assertEqual(TOOL['package_inputs'](root), (profile, [binary]))

    def test_app_includes_debug_library_and_test_binary(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            profile = self.file(root, 'Build/ProfileData/device/Coverage.profdata')
            app = self.file(root, 'Build/Products/ResearchDebug-iphonesimulator/WinnowApp.app/WinnowApp')
            dylib = self.file(root, 'Build/Products/ResearchDebug-iphonesimulator/WinnowApp.app/WinnowApp.debug.dylib')
            tests = self.file(root, 'Build/Products/ResearchDebug-iphonesimulator/WinnowApp.app/PlugIns/WinnowAppTests.xctest/WinnowAppTests')
            self.assertEqual(TOOL['app_inputs'](root, 'ResearchDebug'), ([profile], sorted([app, dylib, tests])))
            with self.assertRaises(ValueError):
                TOOL['app_inputs'](root, 'Debug')

    def test_app_missing_profile_cannot_supply_coverage(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self.file(root, 'Build/Products/ResearchDebug-iphonesimulator/WinnowApp.app/WinnowApp')
            with self.assertRaises(ValueError):
                TOOL['app_inputs'](root, 'ResearchDebug')

    def test_tests_alone_cannot_impersonate_a_compiled_app(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self.file(root, 'Build/ProfileData/device/Coverage.profdata')
            self.file(root, 'Build/Products/ResearchDebug-iphonesimulator/WinnowAppTests.xctest/WinnowAppTests')
            with self.assertRaises(ValueError):
                TOOL['app_inputs'](root, 'ResearchDebug')

    def test_app_only_edits_preserve_package_evidence_but_compiled_edits_fail(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            original = {'Sources/WalletCore/Wallet.swift': 'wallet-a', 'Sources/WinnowApp/App.swift': 'app-a'}
            current = dict(original, **{'Sources/WinnowApp/App.swift': 'app-b'})
            compiled = root / 'compiled.json'; final = root / 'final.json'; lines = root / 'package.lcov'
            compiled.write_text(json.dumps({'files': original}))
            final.write_text(json.dumps({'files': current}))
            lines.write_text('SF:/repo/Sources/WalletCore/Wallet.swift\nDA:1,0\nend_of_record\n')
            self.assertEqual(TOOL['validate_package_sources'](lines, compiled, final),
                             ['Sources/WalletCore/Wallet.swift'])
            current['Sources/WalletCore/Wallet.swift'] = 'wallet-b'
            final.write_text(json.dumps({'files': current}))
            with self.assertRaisesRegex(ValueError, 'source manifest mismatch'):
                TOOL['validate_package_sources'](lines, compiled, final)

    def test_empty_package_source_evidence_fails(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            manifest = root / 'manifest.json'; lines = root / 'package.lcov'
            manifest.write_text(json.dumps({'files': {'Sources/WalletCore/Wallet.swift': 'hash'}}))
            lines.write_text('SF:/SDK/External.swift\nDA:1,1\nend_of_record\n')
            with self.assertRaisesRegex(ValueError, 'no first-party Sources evidence'):
                TOOL['validate_package_sources'](lines, manifest, manifest)


if __name__ == '__main__':
    unittest.main()
