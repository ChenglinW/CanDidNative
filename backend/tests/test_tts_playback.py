"""TTS cache correctness and exact reply ownership; no cloud requests."""
from pathlib import Path
from types import SimpleNamespace
import sys
import pytest
sys.path.insert(0,str(Path(__file__).resolve().parents[1]))
from memory import Memory, Fault, L1
from tasks.recordings import Recordings
OWNER='11111111-1111-4111-8111-111111111111'
class Speech:
    tts_model='test-model';voice='test-voice'
    def __init__(self):self.spoken=[]
    def synthesize(self,text,guard):guard();self.spoken.append(text);return b'RIFF-test',{}

def test_cache_reuses_only_identical_content_model_voice_and_policy(tmp_path):
    store=Memory(tmp_path/'test.sqlite',tmp_path/'files')
    speech=Speech();business=SimpleNamespace(handlers={},guard=lambda *args:None)
    recordings=Recordings(store,business,speech)
    message=store.put('chat_messages',OWNER,{'role':'assistant','content':'第一句。第二句。'},L1)
    job={'id':'job','object_id':message['id']}
    first=recordings.tts(OWNER,job)
    assert speech.spoken==['第一句。第二句。']
    assert recordings.tts(OWNER,job)['clip_ids']==first['clip_ids']
    assert len(speech.spoken)==1
    old=recordings.speech_version(message)
    speech.voice='another-voice'
    assert recordings.speech_version(message)!=old
    assert recordings.tts(OWNER,job)['clip_ids']!=first['clip_ids']
    old=recordings.speech_version(message);speech.tts_model='another-model'
    assert recordings.speech_version(message)!=old
    store.update('chat_messages',OWNER,message['id'],{'content':'修改后的正文。'})
    recordings.tts(OWNER,job)
    assert speech.spoken[-1]=='修改后的正文。'
    store.update('chat_messages',OWNER,message['id'],{'incomplete':True})
    with pytest.raises(Fault):recordings.tts(OWNER,job)
    store.db.close()
