"""Agent-owned source material, separate from confirmed personal memory."""
from memory import Fault, L1, L2, now
from adapters.sources import version


class AgentSourceStore:
    def __init__(self, store):
        self.store = store

    def save(self, owner, *, material_kind, title, text, url=None, producer=None, fetched_at=None):
        self.store.check_owner(owner)
        if material_kind not in {'public_company','user_material','ai_suggestion'}:
            raise Fault('SOURCE_KIND_INVALID', '资料类型尚未开放', 422)
        if not isinstance(text,str) or not text.strip() or len(text)>200000:
            raise Fault('SOURCE_INPUT_LIMIT', '正文为空或超过资料保存上限', 422)
        if not isinstance(title,str) or not 1<=len(title)<=200:
            raise Fault('SOURCE_INPUT_LIMIT', '资料标题不正确', 422)
        inferred = material_kind == 'ai_suggestion'
        if inferred and not producer:
            raise Fault('PRODUCER_REQUIRED', 'AI 建议需要记录生产者', 422)
        data = {'material_kind':material_kind,'title':title,'text':text,'url':url,
                'fetched_at':fetched_at or now(), 'status':'active', 'acquired':True}
        if inferred:
            data.update(producer=producer,rubric_version='agent-source@1')
        with self.store.transaction(owner):
            row = self.store.put('agent_sources',owner,data,L2 if inferred else L1,
                                 source='ai' if inferred else 'user')
        return {'source_id':'research:'+row['id'],'source_version':version(row),
                'material_kind':material_kind,'trust':row['trust']}
