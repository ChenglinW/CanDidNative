"""Package the local showcase and a self-contained HTML; no third-party libraries."""
from pathlib import Path
import base64,json,mimetypes,zipfile,hashlib
ROOT=Path(__file__).resolve().parent
OUT=ROOT.parents[3]/'output'/'candid-showcase'
OUT.mkdir(parents=True,exist_ok=True)
html=(ROOT/'index.html').read_text()
js=(ROOT/'app.js').read_text()
css=(ROOT/'style.css').read_text()
def data(path):
 p=ROOT/path
 return 'data:'+str(mimetypes.guess_type(str(p))[0] or 'application/octet-stream')+';base64,'+base64.b64encode(p.read_bytes()).decode()
for path in ['assets/mascot.png','assets/showroom.png','evidence/native-review.png','evidence/native-transcript.png']:
 html=html.replace(path,data(path))
 js=js.replace(path,data(path))
js=js.replace("evidence/native-${review?'review':'transcript'}.png",'${review?'+json.dumps(data('evidence/native-review.png'))+':'+json.dumps(data('evidence/native-transcript.png'))+'}')
for path in ['evidence/roleplay-acceptance.json','evidence/roleplay-deployment.json']:
 html=html.replace('href="'+path+'"','download="'+Path(path).name+'" href="'+data(path)+'"')
html=html.replace('<link rel="stylesheet" href="style.css">','<style>'+css+'</style>')
html=html.replace('<script src="app.js"></script>','<script>'+js.replace('</script','<\\/script')+'</script>')
standalone=OUT/'CanDid-Showcase.html';standalone.write_text(html)
zip_path=OUT/'CanDid-Showcase.zip'
with zipfile.ZipFile(zip_path,'w',zipfile.ZIP_DEFLATED) as z:
 for p in sorted(ROOT.rglob('*')):
  if not p.is_file() or 'screenshots' in p.parts or '__pycache__' in p.parts:continue
  z.write(p,Path('CanDid-Showcase')/p.relative_to(ROOT))
result={'standalone':str(standalone),'zip':str(zip_path),'html_bytes':standalone.stat().st_size,'zip_bytes':zip_path.stat().st_size,'sha256':hashlib.sha256(standalone.read_bytes()).hexdigest()}
(OUT/'package.json').write_text(json.dumps(result,indent=2)+'\n')
print(json.dumps(result,ensure_ascii=False))
