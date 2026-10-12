"""Download one official AISHELL-4 test meeting, pinned and checksum-verified."""
import argparse
import hashlib
import json
from pathlib import Path
import re

import httpx

REVISION = 'aada72727856313b19d4a030383c426364931dbf'
REPO = 'AISHELL/AISHELL-4'


def download(client, entry, target):
    size = entry['size']
    lfs = entry.get('lfs')
    def digest(path):
        h = hashlib.sha256() if lfs else hashlib.sha1(f'blob {size}\0'.encode())
        with path.open('rb') as file:
            for block in iter(lambda: file.read(1024*1024), b''): h.update(block)
        return h.hexdigest()
    expected = lfs['oid'] if lfs else entry['oid']
    if target.exists() and target.stat().st_size == size and digest(target) == expected:
        print('Verified existing:', target.name, flush=True)
        return
    target.parent.mkdir(parents=True, exist_ok=True)
    partial = target.with_suffix(target.suffix+'.part')
    url = f'https://huggingface.co/datasets/{REPO}/resolve/{REVISION}/{entry["path"]}'
    print(f'Downloading {target.name} ({size / 1_000_000:.1f} MB)', flush=True)
    try:
        count = 0
        with client.stream('GET', url) as response:
            response.raise_for_status()
            with partial.open('wb') as file:
                for block in response.iter_bytes(1024*1024):
                    count += len(block)
                    if count > size: raise ValueError('Download exceeds expected size')
                    file.write(block)
        if count != size or digest(partial) != expected: raise ValueError('Dataset checksum mismatch')
        partial.replace(target)
    finally:
        partial.unlink(missing_ok=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--meeting', default='S_R004S03C01')
    parser.add_argument('--output', type=Path, default=Path('.build/aishell4/source'))
    args = parser.parse_args()
    if not re.fullmatch(r'[LMS]_R\d+S\d+C\d+', args.meeting): parser.error('Invalid meeting ID')
    provenance = {'dataset': REPO, 'revision': REVISION, 'split': 'test', 'files': [],
                  'license_reference': 'https://www.openslr.org/111/'}
    with httpx.Client(timeout=httpx.Timeout(45, connect=15), follow_redirects=True) as client:
        for folder, suffixes in [('TextGrid', ['.TextGrid', '.rttm']), ('wav', ['.flac'])]:
            listing = client.get(f'https://huggingface.co/api/datasets/{REPO}/tree/{REVISION}/test/{folder}')
            listing.raise_for_status()
            entries = {e['path']: e for e in listing.json()}
            for suffix in suffixes:
                relative = f'test/{folder}/{args.meeting}{suffix}'
                entry = entries[relative]
                download(client, entry, args.output/relative)
                provenance['files'].append({'path': relative, 'size': entry['size'],
                    'git_blob': entry['oid'], 'sha256': entry.get('lfs', {}).get('oid')})
    (args.output/(args.meeting+'-source.json')).write_text(json.dumps(provenance, ensure_ascii=False, indent=2)+'\n')
    print('Dataset ready:', args.output, flush=True)


if __name__ == '__main__': main()
