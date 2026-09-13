"""Exercise release metadata reporting against sparse-field ASC fixtures."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / 'testflight.sh'
API_FIXTURE = r'''
import json, sys, urllib.parse
method, path = sys.argv[1:3]
assert method == 'GET', 'status must be read-only'
url = urllib.parse.urlsplit(path)
q = urllib.parse.parse_qs(url.query)
def resource(kind, id, attrs=None, relationships=None):
    return dict(type=kind, id=id, attributes=attrs or {}, relationships=relationships or {})
def link(kind, id): return dict(data=dict(type=kind, id=id))
if url.path == '/apps':
    result = {'data': [resource('apps', 'app')]}
elif url.path == '/apps/app/appStoreVersions':
    assert q['filter[versionString]'] == ['0.6.3']
    result = {'data': [resource('appStoreVersions', 'current')]}
elif url.path == '/appStoreVersions/current':
    fields = q.get('fields[appStoreVersions]', [''])[0].split(',')
    relations = {'build': link('builds', 'build')} if 'build' in fields else {}
    result = {'data': resource('appStoreVersions', 'current', dict(versionString='0.6.3', appVersionState='PREPARE_FOR_SUBMISSION', releaseType='MANUAL'), relations),
              'included': [resource('builds', 'build', dict(version='24', processingState='VALID'))]}
elif url.path == '/appStoreVersions/current/appStoreVersionLocalizations':
    result = {'data': [resource('appStoreVersionLocalizations', 'locale', dict(locale='en-US', whatsNew='Changes', description='Description', keywords='bitcoin', supportUrl='https://example.com/support'))]}
elif url.path == '/apps/app/appInfos':
    fields = q.get('fields[appInfos]', [''])[0].split(',')
    relations = {}
    if 'primaryCategory' in fields: relations['primaryCategory'] = link('appCategories', 'FINANCE')
    if 'appInfoLocalizations' in fields: relations['appInfoLocalizations'] = {'data': [{'type':'appInfoLocalizations', 'id':'name'}]}
    result = {'data': [resource('appInfos', 'released', dict(state='READY_FOR_DISTRIBUTION')),
                       resource('appInfos', 'editable', dict(state='PREPARE_FOR_SUBMISSION', appStoreAgeRating='FOUR_PLUS'), relations)],
              'included': [resource('appInfoLocalizations', 'name', dict(locale='en-US', name='Winnow', privacyPolicyUrl='https://example.com/privacy'))]}
elif url.path == '/reviewSubmissions': result = {'data': []}
else: raise SystemExit('Unexpected API request: ' + path)
print(json.dumps(result))
'''

class AppStoreStatusTests(unittest.TestCase):
    def test_status_resolves_requested_version_and_relationships(self):
        with tempfile.TemporaryDirectory() as temp:
            api = Path(temp) / 'api.py'
            api.write_text(API_FIXTURE)
            prefix = SCRIPT.read_text().split('\ncase "${1:-all}" in')[0]
            code = prefix + '\nasc() { python3 "$FIXTURE_API" "$@"; }\nstep_appstore_status\n'
            env = {**os.environ, 'ASC_KEY_ID':'fixture', 'ASC_ISSUER_ID':'fixture',
                   'APPSTORE_VERSION_ID':'', 'APPSTORE_VERSION_STRING':'0.6.3', 'FIXTURE_API':str(api)}
            result = subprocess.run(['bash', '-c', code, str(SCRIPT)], env=env, capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertIn('version=current string=0.6.3', result.stdout)
            self.assertIn('primaryCategory=FINANCE', result.stdout)
            self.assertIn('name=Winnow', result.stdout)
            self.assertIn('metadata complete', result.stdout)

if __name__ == '__main__': unittest.main()
