#!/bin/bash
# SPDX-FileCopyrightText: 2026 Maiko BOSSUYT
# SPDX-License-Identifier: GPL-3.0-or-later
# Package the exact committed corresponding source of every enabled copyleft core.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
python3 - "$ROOT" "${1:-$ROOT/build/source-bundle}" <<'PY'
import gzip,hashlib,io,json,pathlib,subprocess,sys,tarfile
root=pathlib.Path(sys.argv[1]); out=pathlib.Path(sys.argv[2]).resolve(); out.parent.mkdir(parents=True,exist_ok=True)
revision=subprocess.check_output(['git','rev-parse','HEAD'],cwd=root,text=True).strip()
manifest=json.loads((root/'Resources/CoreManifest.json').read_text())
entries={}; modes={}
for core in manifest['cores']:
 if core['relayStatus']!='enabled' or not core['sourceOfferRequired']:continue
 path=core['build']['path']; prefix='corresponding-cores/'+core['id']+'/'
 data=subprocess.check_output(['git','archive','--format=tar',revision,'--',path],cwd=root)
 with tarfile.open(fileobj=io.BytesIO(data)) as archive:
  for entry in archive:
   if entry.isfile():entries[prefix+entry.name]=archive.extractfile(entry).read();modes[prefix+entry.name]=entry.mode
   elif entry.issym():entries[prefix+entry.name]=('symlink',entry.linkname);modes[prefix+entry.name]=entry.mode
 entries[prefix+'SOURCE.txt']=(f"Core: {core['id']}\nLicence: {core['license']}\nUpstream: {core['upstream']}\nPinned revision: {core['revision']}\nVendored path: {path}\nPublic client revision: {revision}\nComplete modified source, integration bridges and build definitions are included.\n").encode()
entries['corresponding-cores/README.txt']=(f'Relay Release V1 corresponding source\nPublic client revision: {revision}\nhttps://github.com/relayemu/client\nCore licences, pins and complete modified source are included.\n').encode()
target=pathlib.Path(str(out)+'.tar.gz')
with target.open('wb') as stream,gzip.GzipFile(fileobj=stream,mode='wb',mtime=0) as gz,tarfile.open(fileobj=gz,mode='w') as archive:
 for name,data in sorted(entries.items()):
  info=tarfile.TarInfo(name);info.mtime=0;info.mode=modes.get(name,0o644)
  if isinstance(data,tuple):info.type=tarfile.SYMTYPE;info.linkname=data[1];archive.addfile(info)
  else:info.size=len(data);archive.addfile(info,io.BytesIO(data))
hash=hashlib.sha256(target.read_bytes()).hexdigest()
pathlib.Path(str(target)+'.sha256').write_text(hash+'  '+target.name+'\n')
print(hash+'  '+str(target))
PY
