"""DashScope documented duplex protocol with actual task-started readiness.

The existing websocket-client dependency is supplied by DashScope. Connections,
callbacks and cancellation belong to one substream; no process-wide SDK patches.
"""
import json
import threading
import time
from uuid import uuid4
import websocket
from memory import Fault


class LiveResult:
    def __init__(self, sentence=None, usage=None, code=None):
        self.sentence, self.usage, self.code = sentence, usage, code
    def get_sentence(self): return self.sentence
    def get_usage(self, sentence=None): return self.usage


class LiveRecognition:
    def __init__(self, speech, callback):
        self.speech, self.callback = speech, callback
        self.task_id = uuid4().hex
        self.socket = None
        self.ready = threading.Event()
        self.done = threading.Event()
        self.closed = threading.Event()
        self.lock = threading.Lock()
        self.error = None
        self.metrics = {'connect_started': time.monotonic(), 'frames': 0, 'bytes': 0}
        self.worker = threading.Thread(target=self._receive, daemon=True, name='candid-live-asr')

    def start(self):
        self.worker.start()
        if not self.ready.wait(15):
            self.abort()
            raise Fault('ASR_READY_TIMEOUT', '语音连接未就绪，输入已保留，请稍后重试', 504)
        if self.error:
            raise Fault(self.error, '实时转写服务暂不可用，请检查连接或配置', 502)
        return self

    def _receive(self):
        try:
            host = 'dashscope-intl.aliyuncs.com' if self.speech.international else 'dashscope.aliyuncs.com'
            sock = websocket.create_connection('wss://' + host + '/api-ws/v1/inference',
                header={'Authorization': 'Bearer ' + self.speech.key}, timeout=15, enable_multithread=True)
            self.socket = sock
            if self.closed.is_set(): return
            self.metrics['connected'] = time.monotonic()
            try:self.metrics['transport_peer']=sock.sock.getpeername()
            except Exception:pass
            sock.send(json.dumps({'header': {'action': 'run-task', 'task_id': self.task_id, 'streaming': 'duplex'},
                'payload': {'task_group': 'audio', 'task': 'asr', 'function': 'recognition',
                'model': self.speech.realtime_model, 'parameters': {'format': 'pcm', 'sample_rate': 16000,
                'language_hints': ['zh', 'en'], 'keep_dialect': True, 'semantic_punctuation_enabled': True}, 'input': {}}}))
            while not self.closed.is_set():
                raw = sock.recv()
                if not raw: raise ConnectionError()
                if not isinstance(raw, str): continue
                event = json.loads(raw)
                header = event.get('header', {})
                if header.get('task_id') != self.task_id: continue
                kind = header.get('event')
                if kind == 'task-started':
                    self.metrics['provider_ready'] = time.monotonic()
                    sock.settimeout(35)
                    self.ready.set()
                    if hasattr(self.callback, 'on_ready'): self.callback.on_ready()
                elif kind == 'result-generated':
                    payload = event.get('payload', {})
                    sentence = payload.get('output', {}).get('sentence')
                    if isinstance(sentence, dict):
                        self.metrics['last_callback'] = time.monotonic()
                        self.callback.on_event(LiveResult(sentence, payload.get('usage')))
                elif kind == 'task-finished':
                    self.metrics['completed'] = time.monotonic()
                    self.callback.on_complete()
                    self.done.set()
                    return
                elif kind == 'task-failed':
                    code = header.get('error_code', '')
                    self.error = 'ASR_AUTH_FAILED' if code in {'InvalidApiKey', 'Unauthorized', 'AccessDenied'} else 'ASR_PROVIDER_FAILED'
                    raise ConnectionError()
        except Exception as exc:
            if not self.closed.is_set():
                status = getattr(exc, 'status_code', None)
                self.error = self.error or ('ASR_AUTH_FAILED' if status in {401, 403} else 'ASR_CONNECTION_FAILED')
                self.callback.on_error(LiveResult(code=self.error))
        finally:
            self.ready.set()
            self.done.set()
            if self.socket:
                try: self.socket.close(timeout=1)
                except Exception: pass

    def send_audio_frame(self, pcm):
        if not self.ready.is_set() or self.closed.is_set() or self.error or self.done.is_set():
            raise Fault('ASR_STREAM_CLOSED', '语音子段连接已关闭，输入已保留', 502)
        with self.lock:
            self.socket.send_binary(pcm)
            self.metrics['frames'] += 1
            self.metrics['bytes'] += len(pcm)
            self.metrics.setdefault('first_wire', time.monotonic())

    def stop(self):
        if self.closed.is_set(): return
        if not self.done.is_set():
            with self.lock:
                self.metrics['finish_requested'] = time.monotonic()
                self.socket.send(json.dumps({'header': {'action': 'finish-task', 'task_id': self.task_id,
                    'streaming': 'duplex'}, 'payload': {'input': {}}}))
            if not self.done.wait(15):
                self.abort()
                raise Fault('ASR_FINAL_TIMEOUT', '这句话的最终转写未完成，输入已保留', 504)
        if self.error: raise Fault(self.error, '最终转写不完整，输入已保留', 502)
        self.worker.join(timeout=1)

    def abort(self):
        self.closed.set()
        if self.socket:
            try: self.socket.shutdown()
            except Exception: pass
        self.ready.set()
        self.done.set()
