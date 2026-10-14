import re
from memory import Fault


class SpeechCommitter:
    """Only instantiated for a tool-disabled final answer, never planner deltas."""
    def __init__(self, runtime, context, sources, references=()):
        self.runtime, self.context, self.sources = runtime, context, sources
        self.references=references
        self.pending = ''
        self.seq = 0
        self.fenced = False

    def push(self, text):
        self.pending += text
        while True:
            match = re.search(r'[。！？!?]\s*|\.(?=\s)|\n', self.pending)
            cut = match.end() if match else None
            if cut is None and len(self.pending) > 160:
                cut = max(self.pending.rfind(' ', 40, 160), self.pending.rfind('，', 40, 160))
                if cut < 40 and not any(x in self.pending[:160] for x in ['http', '```']): cut = 120
                elif cut < 40: cut = None
            if cut is None: return
            part, self.pending = self.pending[:cut], self.pending[cut:]
            self.commit(part)

    def commit(self, text):
        self.context.remaining()
        from agent_runtime.context_manager import reference_set
        self.runtime.context_manager.validate(self.context.owner_id,[*self.references,*reference_set(self.sources)],self.context.workspace_id)
        if '```' in text:
            self.fenced = not self.fenced if text.count('```') % 2 else self.fenced
            return
        if self.fenced: return
        citations = {'[' + n + ']' for n in re.findall(r'\[(\d+)\]', text)}
        valid = {s.get('citation') for s in self.sources}
        if citations - valid: raise Fault('SOURCE_CITATION_INVALID', '回复引用无法核对，已停止播报', 502)
        readable = re.sub(r'\[([^\]]+)\]\(https?://[^)]+\)', r'\1', text)
        readable = re.sub(r'https?://\S+|\[\d+\]|[*_`#]+', '', readable)
        readable = re.sub(r'^\s*(?:[-+>]\s|\d+[.)]\s)', '', readable).strip()
        if not readable or readable.startswith(('{', '}')): return
        self.seq += 1
        task = self.runtime.tasks.get(self.context.owner_id, self.context.task_id)
        voice = task.get('voice_context', {})
        self.runtime.tasks.emit(self.context, 'speech.segment', {'text': readable, 'segment_seq': self.seq,
            'generation_id': voice.get('generation_id'), 'voice_session_id': voice.get('voice_session_id'),
            'kind': 'answer'})

    def finish(self):
        if self.pending: self.commit(self.pending); self.pending = ''
