"""Create reproducible authored material and synthetic system-TTS acceptance fixtures.
Run with Python + reportlab; ffmpeg and macOS say generate audio. No cloud request.
Text scenarios are authored for this project (CC0). Audio provenance is macOS built-in TTS;
it is synthetic test input, not a human-speaker/diarization benchmark.
"""
import argparse,array,hashlib,io,json,random,subprocess,wave,zipfile
from pathlib import Path

parser=argparse.ArgumentParser();parser.add_argument('--output',default='.build/v2-fixtures');args=parser.parse_args()
out=Path(args.output);out.mkdir(parents=True,exist_ok=True)
materials={
 '客户甲-服务范围.txt':'客户甲为华味餐饮。产品代号 CANDID-A73。预算18万元。试点三家门店。基础服务包含一次培训，不承诺两周上线。接口清单由王总提供。',
 '客户乙-需求.md':'# 晴川零售\n客户乙预算80万元，验收代号 CANDID-B29。计划十二家门店，尚未确定合同与上线日期。',
 '面试-JD.txt':'公司为测试公司北辰。招聘产品经理。要求 Python 和 SQL，关注实验设计。岗位代号 INTERVIEW-K51。用户未提供过往业绩，不能编造。',
}
for name,text in materials.items():(out/name).write_text(text,encoding='utf8')
with zipfile.ZipFile(out/'产品介绍.docx','w') as z:
 z.writestr('word/document.xml','<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:body><w:p><w:r><w:t>基础服务包含一次培训，资料代号 DOCX-K82。</w:t></w:r></w:p></w:body></w:document>')
with zipfile.ZipFile(out/'试点方案.pptx','w') as z:
 for n,text in [(1,'三家门店试点，范围以接口清单为准。'),(2,'资料代号 PPTX-R64。交付日期尚未核实。')]:
  z.writestr(f'ppt/slides/slide{n}.xml',f'<p:sld xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main" xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main"><a:p><a:r><a:t>{text}</a:t></a:r></a:p></p:sld>')
from reportlab.pdfgen import canvas
from reportlab.pdfbase import pdfmetrics
from reportlab.pdfbase.cidfonts import UnicodeCIDFont
pdfmetrics.registerFont(UnicodeCIDFont('STSong-Light'))
c=canvas.Canvas(str(out/'报价与服务范围.pdf'))
for page,text in enumerate(['客户甲预算十八万元。PDF-A73。基础服务包含培训。','客户乙预算八十万元。PDF-B29。上线排期未知。'],1):
 c.setFont('STSong-Light',14);c.drawString(35,760,text);c.drawString(35,720,'页码 '+str(page));c.showPage()
c.save()
(out/'损坏.pdf').write_bytes(b'%PDF-invalid-fixture')
blank=canvas.Canvas(str(out/'扫描件无文字.pdf'));blank.rect(30,30,200,200,fill=1);blank.save()
utterances=[
 ('mandarin','Tingting','我们先确认三家门店的接口和服务范围，再讨论试点排期。'),
 ('english','Samantha','Please confirm the service scope before we discuss the delivery date.'),
 ('cantonese','Sinji','我哋先确认三间分店嘅服务范围，唔好咁快承诺上线时间。'),
]
audio=[];pcm=[]
def write(name,data):
 with wave.open(str(out/name),'wb') as f:f.setnchannels(1);f.setsampwidth(2);f.setframerate(16000);f.writeframes(data)
for label,voice,text in utterances:
 aiff=out/(label+'.aiff');wav=out/(label+'.wav')
 subprocess.run(['say','-v',voice,'-r','165','-o',str(aiff),text],check=True)
 subprocess.run(['ffmpeg','-nostdin','-v','error','-y','-i',str(aiff),'-ac','1','-ar','16000','-c:a','pcm_s16le',str(wav)],check=True)
 with wave.open(str(wav),'rb') as f:data=f.readframes(f.getnframes())
 pcm.append(data);audio.append({'file':wav.name,'reference':text,'voice':voice,'duration_seconds':len(data)/32000,'synthetic':True})
 aiff.unlink()
gap=b'\0'*(32000*2);mixed=gap.join(pcm);write('mixed-turns.wav',mixed)
audio.append({'file':'mixed-turns.wav','reference':' '.join(t[2] for t in utterances),'synthetic':True,'scenario':'three synthetic voices, Mandarin-English-Cantonese, 2s turn gaps'})
samples=array.array('h');samples.frombytes(mixed);rng=random.Random(73)
noisy=array.array('h',(max(-32768,min(32767,s+rng.randint(-140,140))) for s in samples));write('mixed-noise.wav',noisy.tobytes())
overlap=array.array('h');a=array.array('h');a.frombytes(pcm[0]);b=array.array('h');b.frombytes(pcm[1])
for i in range(max(len(a),len(b))):overlap.append(max(-32768,min(32767,(a[i] if i<len(a) else 0)+(b[i] if i<len(b) else 0))))
write('overlap.wav',overlap.tobytes())
audio.extend([{'file':'mixed-noise.wav','reference':audio[-1]['reference'],'synthetic':True,'scenario':'deterministic low noise'}, {'file':'overlap.wav','synthetic':True,'scenario':'fully overlapped Mandarin and English; negative stress case, not DER benchmark'}])
files=[{'file':p.name,'bytes':p.stat().st_size,'sha256':hashlib.sha256(p.read_bytes()).hexdigest()} for p in sorted(out.iterdir()) if p.is_file() and p.name!='manifest.json']
manifest={'version':'candid-v2-20261016','text_license':'CC0 authored synthetic scenarios','audio_provenance':'macOS built-in say: Tingting, Samantha, Sinji; synthetic test input only','audio':audio,'files':files,'expected':['A73 belongs to customer A, B29 to customer B','Interview facts must not become customer or user experience','PDF page references 1/2; PPTX slides 1/2','Scan and corrupt PDFs fail truthfully','No invented dates, names, prices or completed actions']}
(out/'manifest.json').write_text(json.dumps(manifest,ensure_ascii=False,indent=2))
print(json.dumps({'output':str(out),'files':len(files),'audio_cases':len(audio)},ensure_ascii=False))
