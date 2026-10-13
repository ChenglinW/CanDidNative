"""Owner-scoped durable events; sequence allocation shares the task transaction."""
import json
from memory import L1, Fault


TERMINAL = {'completed', 'failed', 'cancelled', 'interrupted'}
ACTIVE = {'queued', 'running', 'waiting_input'}


class EventStore:
    def __init__(self, store):
        self.store = store

    def append(self, owner, task_id, kind, data=None, *, attempt=None):
        with self.store.transaction(owner):
            self.store.check_owner(owner)
            task = self.store.get('agent_tasks', owner, task_id)
            if attempt is not None and (task['attempt'] != attempt or task['status'] not in ACTIVE):
                raise Fault('AGENT_CANCELLED', '任务已停止或执行版本已变化', 409)
            seq = task.get('event_seq', 0) + 1
            event = self.store.put('agent_events', owner, {
                'task_id': task_id, 'thread_id': task['thread_id'], 'turn_id': task['turn_id'],
                'attempt': task['attempt'], 'seq': seq, 'kind': kind, 'data': data or {},
                'producer': 'candid-agent:event@1'}, L1, source='ai')
            self.store.update('agent_tasks', owner, task_id, {'event_seq': seq})
            return event

    def after(self, owner, task_id, cursor, limit=200):
        with self.store.lock:
            self.store.check_owner(owner)
            task = self.store.get('agent_tasks', owner, task_id)
            if cursor < 0 or cursor > task.get('event_seq', 0):
                raise Fault('AGENT_EVENT_CURSOR_INVALID', '事件位置已变化，请重新读取任务状态', 409)
            rows = self.store.db.execute('''SELECT data FROM agent_events WHERE owner_id=?
                AND json_extract(data,'$.task_id')=? AND json_extract(data,'$.seq')>?
                ORDER BY json_extract(data,'$.seq') LIMIT ?''', (owner, task_id, cursor, limit)).fetchall()
            return [json.loads(row['data']) for row in rows]

    @staticmethod
    def public(event):
        return {key: event[key] for key in ('task_id', 'thread_id', 'turn_id', 'attempt', 'seq', 'kind', 'data')}
