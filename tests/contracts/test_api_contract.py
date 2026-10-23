"""P0 contract integrity checks; not substitutes for P2 execution tests."""
import hashlib
import json
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[2]


class ApiContractTests(unittest.TestCase):
    def test_canonical_fixture_digest(self):
        sample = json.loads((ROOT / 'contracts/fixtures/api/canonical-operation.json').read_text(encoding='utf-8'))
        encoded = json.dumps(sample['hash_input'], ensure_ascii=False, sort_keys=True, separators=(',', ':'))
        self.assertEqual(encoded, sample['canonical_utf8'])
        self.assertEqual(hashlib.sha256(encoded.encode()).hexdigest(), sample['sha256'])
        changed = json.loads(encoded)
        changed['operation']['payload']['money']['amount_minor'] = '1231'
        changed_bytes = json.dumps(changed, ensure_ascii=False, sort_keys=True, separators=(',', ':')).encode()
        self.assertNotEqual(hashlib.sha256(changed_bytes).hexdigest(), sample['sha256'])

    def test_openapi_references_resolve(self):
        # Once P1 exports implemented routes, retain the candidate as a design baseline.
        path = ROOT / 'contracts/openapi-p0.json'
        if not path.exists():
            path = ROOT / 'contracts/openapi.json'
        schema = json.loads(path.read_text(encoding='utf-8'))
        def visit(node):
            if isinstance(node, dict):
                if '$ref' in node:
                    target = schema
                    self.assertTrue(node['$ref'].startswith('#/'))
                    for key in node['$ref'][2:].split('/'):
                        target = target[key.replace('~1','/').replace('~0','~')]
                for value in node.values():
                    visit(value)
            elif isinstance(node, list):
                for value in node:
                    visit(value)
        visit(schema)
        self.assertEqual(schema['components']['schemas']['Money']['properties']['amount_minor']['type'], 'string')

    def test_error_samples_do_not_embed_secret_input(self):
        samples = json.loads((ROOT / 'contracts/fixtures/api/errors.json').read_text(encoding='utf-8'))
        for item in samples['cases']:
            error = item['response']['error']
            self.assertEqual(set(error), {'code','message','request_id','details'})
            self.assertEqual(error['details'], {})


if __name__ == '__main__':
    unittest.main()
