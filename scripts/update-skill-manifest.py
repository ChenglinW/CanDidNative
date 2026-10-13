"""After editing an approved SKILL.md, update its declared version and body fingerprint."""
import argparse
import hashlib
import json
from pathlib import Path

NAMES = ['communication_prep', 'communication_review', 'memory_draft', 'company_research']
parser = argparse.ArgumentParser()
parser.add_argument('name', choices=NAMES)
parser.add_argument('--version', required=True)
args = parser.parse_args()
if not 1 <= len(args.version) <= 40:
    parser.error('version must contain 1–40 characters')
folder = Path(__file__).resolve().parents[1] / 'backend/skills' / args.name
manifest_path = folder / 'skill.json'
manifest = json.loads(manifest_path.read_text('utf8'))
body = (folder / 'SKILL.md').read_text('utf8')
digest = hashlib.sha256(body.encode()).hexdigest()
if manifest['body_sha256'] != digest and args.version == manifest['version']:
    parser.error('正文已变更，请使用新的版本号')
manifest.update(version=args.version, body_sha256=digest)
manifest_path.write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + '\n')
print(args.name + '@' + args.version + ' manifest updated')
