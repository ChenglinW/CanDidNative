"""Confirmed DashScope models. SDK for live ASR/TTS; HTTP submit for temporary-file ASR."""
import base64
import io
import json
import os
import threading
import wave
import httpx
import dashscope
from dashscope.audio.asr import Recognition, RecognitionCallback, Transcription
from dashscope.audio.qwen_tts_realtime import QwenTtsRealtime, QwenTtsRealtimeCallback, AudioFormat
from dashscope.utils.oss_utils import OssUtils
from memory import Fault


class Speech:
    def __init__(self):
        self.key=os.getenv('DASHSCOPE_API_KEY','')
        self.enabled=os.getenv('CANDID_SPEECH_ENABLED','1')=='1'
        self.realtime_model=os.getenv('DASHSCOPE_ASR_REALTIME_MODEL','qwen-audio-3.1-asr-flash-streaming')
        self.file_model=os.getenv('DASHSCOPE_ASR_FILE_MODEL','qwen-audio-3.1-asr-flash-filetrans')
        self.tts_model=os.getenv('DASHSCOPE_TTS_MODEL','qwen3-tts-flash-realtime')
        self.voice=os.getenv('DASHSCOPE_TTS_VOICE','Cherry')
        self.international=os.getenv('DASHSCOPE_REGION','cn-beijing')!='cn-beijing'
        host='dashscope-intl.aliyuncs.com' if self.international else 'dashscope.aliyuncs.com'
        self.http='https://'+host+'/api/v1';self.ws='wss://'+host+'/api-ws/v1/realtime'
        dashscope.api_key=self.key
        dashscope.base_http_api_url=self.http
        dashscope.base_websocket_api_url='wss://'+host+'/api-ws/v1/inference'

    @property
    def configured(self):return bool(self.key and self.enabled)

    def check(self):
        if not self.configured:raise Fault('SPEECH_NOT_CONFIGURED','语音服务尚未配置或已关闭',503)

    def upload(self,path):
        self.check()
        try:return OssUtils.upload(self.file_model,str(path),api_key=self.key)[0]
        except Exception:raise Fault('ASR_UPLOAD_FAILED','语音服务临时上传失败，原音频保留',502) from None

    def submit_file(self,url):
        self.check()
        # The filetrans SDK does not expose temporary OSS resolution. Use the documented HTTP header.
        try:
            with httpx.Client(timeout=90,follow_redirects=False) as client:
                response=client.post(self.http+'/services/audio/asr/transcription',headers={
                    'Authorization':'Bearer '+self.key,'X-DashScope-Async':'enable','X-DashScope-OssResourceResolve':'enable'},
                    json={'model':self.file_model,'input':{'file_urls':[url]},'parameters':{
                        'channel_id':[0],'language_hints':['zh','en'],'diarization_enabled':True,'keep_dialect':True}})
                if response.status_code!=200:raise ValueError('rejected')
                result=response.json(); task_id=result.get('output',{}).get('task_id')
                if not task_id:raise ValueError('no id')
                return task_id
        except Exception:raise Fault('ASR_SUBMIT_UNCERTAIN','精转写提交结果不明，请核对供应商任务后继续；没有自动重复提交',502) from None

    def fetch_file(self,task_id):
        self.check()
        try:
            result=Transcription.fetch(task_id,api_key=self.key)
            if result.status_code!=200:raise ValueError('query')
            return json.loads(str(result))
        except Exception:raise Fault('ASR_QUERY_FAILED','无法查询已有精转写任务，可以稍后继续',502) from None

    def live(self,callback):
        self.check()
        from .live_asr import LiveRecognition
        return LiveRecognition(self, callback).start()

    def synthesize(self,text,guard=lambda:None):
        chunks=[]
        usage=self.stream_synthesize(text,chunks.append,guard)
        output=io.BytesIO()
        with wave.open(output,'wb') as wav:
            wav.setnchannels(1);wav.setsampwidth(2);wav.setframerate(24000);wav.writeframes(b''.join(chunks))
        return output.getvalue(),usage

    def stream_synthesize(self,text,on_audio,guard=lambda:None,cancellation=None):
        self.check()
        done=threading.Event();finished=threading.Event();audio=bytearray();failure=[];usage=[]
        class Callback(QwenTtsRealtimeCallback):
            def on_event(self,event):
                if event.get('type')=='response.audio.delta':
                    chunk=base64.b64decode(event['delta']);audio.extend(chunk)
                    if len(audio)<=12_000_000:on_audio(chunk)
                    if len(audio)>12_000_000:failure.append('output_limit');done.set()
                if event.get('type')=='response.done':usage.append(event.get('response',{}).get('usage',{}))
                if event.get('type')=='session.finished':finished.set();done.set()
                if event.get('type')=='error':failure.append('provider');done.set()
            def on_close(self,*args):done.set()
        client=QwenTtsRealtime(model=self.tts_model,callback=Callback(),url=self.ws)
        try:
            guard()
            if cancellation:cancellation.register(client.close)
            client.connect();guard()
            client.update_session(voice=self.voice,response_format=AudioFormat.PCM_24000HZ_MONO_16BIT,mode='server_commit',language_type='Auto')
            guard();client.append_text(text);client.finish()
            for _ in range(180):
                guard()
                if done.wait(.5):break
            else:raise Fault('TTS_TIMEOUT','播报合成超时，文字仍可阅读',504)
            if not finished.is_set():raise Fault('TTS_INCOMPLETE','播报连接中断，文字仍可阅读',502)
            if failure or not audio:raise Fault('TTS_FAILED','播报合成失败，文字仍可阅读',502)
        finally:
            if cancellation:cancellation.unregister(client.close)
            client.close()
        return usage
