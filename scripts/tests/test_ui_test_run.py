"""Validate runner environment injection against both Xcode plist schemas."""
import copy
from pathlib import Path
import runpy
import unittest

configure = runpy.run_path(str(Path(__file__).resolve().parents[1] / 'configure-ui-test-run'))['configure']


class UITestRunTests(unittest.TestCase):
    def test_both_formats_preserve_other_targets_and_build_paths(self):
        target = {'BlueprintName': 'Lightning', 'EnvironmentVariables': {'existing': 'yes'},
                  'TestHostPath': '__TESTROOT__/App.app'}
        other = {'BlueprintName': 'Winnow', 'EnvironmentVariables': {'ordinary': 'yes'}}
        for modern in (False, True):
            with self.subTest(modern=modern):
                targets = copy.deepcopy([target, other])
                spec = {'TestConfigurations': [{'TestTargets': targets}]} if modern else dict(zip(('Lightning', 'Winnow'), targets))
                configure(spec, {'WINNOW_DATADIR': '/tmp/disposable'}, 'Lightning')
                self.assertEqual(targets[0]['EnvironmentVariables'], {'existing': 'yes', 'WINNOW_DATADIR': '/tmp/disposable'})
                self.assertEqual(targets[0]['TestHostPath'], target['TestHostPath'])
                self.assertEqual(targets[1], other)

    def test_missing_target_and_non_string_values_fail_closed(self):
        for values, target in [({'port': '1'}, 'Absent'), ({'port': 1}, 'Lightning'), ([], 'Lightning')]:
            with self.subTest(values=values, target=target), self.assertRaises(ValueError):
                configure({'Lightning': {'BlueprintName': 'Lightning'}}, values, target)
