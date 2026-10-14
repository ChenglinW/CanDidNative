"""Cooperative cancellation plus best-effort closure of active provider connections."""
import threading
from memory import Fault


class Cancellation:
    def __init__(self):
        self._event = threading.Event()
        self._lock = threading.Lock()
        self._closers = set()

    def check(self):
        if self._event.is_set():
            raise Fault('AGENT_CANCELLED', '任务已停止', 409)

    def register(self, close):
        with self._lock:
            self.check()
            self._closers.add(close)

    def unregister(self, close):
        with self._lock:
            self._closers.discard(close)

    def cancel(self):
        self._event.set()
        with self._lock:
            closers = list(self._closers)
        # A blocked network close never delays the cancellation HTTP acknowledgement.
        for close in closers:
            def shutdown(callback=close):
                try:
                    callback()
                except Exception:
                    pass
            threading.Thread(target=shutdown, daemon=True, name='candid-cancel-connection').start()
