"""A new or unverified group member must not silently widen beta distribution."""
from pathlib import Path
import runpy
import unittest

VERIFY = runpy.run_path(str(Path(__file__).resolve().parents[1] / 'lightning-testflight'))['verify_tester_countries']


class TesterScopeTests(unittest.TestCase):
    def test_exact_confirmed_members_pass(self):
        VERIFY(['alice', 'bob'], {'alice': 'US', 'bob': 'CA'})

    def test_new_or_unconfirmed_members_are_rejected(self):
        for members, countries in [([], {}), (['alice'], {}),
                                   (['alice', 'new'], {'alice': 'US'}),
                                   (['alice'], {'alice': 'US', 'removed': 'CA'})]:
            with self.subTest(members=members, countries=countries), self.assertRaises(AssertionError):
                VERIFY(members, countries)

    def test_excluded_or_malformed_countries_are_rejected(self):
        for country in ['CN', 'FR', 'us', '', 'USA', None, ['US'], '12']:
            with self.subTest(country=country), self.assertRaises(AssertionError):
                VERIFY(['alice'], {'alice': country})
