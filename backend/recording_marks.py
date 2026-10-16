"""User bookmarks enrich the existing recording; they never create parallel facts."""
import hashlib,json,time
from memory import Fault,L1,now
from adapters.sources import version

SEMANTIC_VERSION = 'semantic-mark@1'
SEMANTIC_PROMPT = ('理解录音标记附近在讨论什么，同时生成重点卡片和少量前置原文注释。'
    '只输出 {"title":"简短主题","summary":"片段内容","topics":["需求/问题/表达/跟进/待核实"],"suggestion":"可选建议",'
    '"annotations":[{"anchor_segment_id":"放在该句后","text":"本轮关键信息及关系",'
    '"evidence":[{"segment_id":"原文id","quote":"逐字原文"}]}]}。'
    'focus范围是用户标记位置，周围原文用于补齐沟通轮次。理解话题与上下文，不猜用户按标记的主观意图。'
    '每个连续话题最多一条注释，每组最多两条，通常一条即可；嗯、好的、没问题等口头确认不单独标注。'
    '注释只说明原文中的关键内容和关系，不给后续模型指令，不生成FAQ清单、不评价表达效果、不扩写原话。'
    '完整理解数字、单位、范围及其角色：客户预算、起售价、落地总价、估计、期望和明确承诺不能混淆。'
    '如91万8应作为完整表达，不拆成91万和8；跨句单位可参考上下句，不能擅自修正含糊转写，无法确定则保留原表达并说明待核对。'
    '注释放在有实质内容的focus原句之后，每条给出支持该说明的逐字原文及id。无法形成有依据的说明时annotations为空。'
    '保留观点、提议和未确认状态，不把期望当承诺，不猜本人身份，不新增事实、任务或提醒。'
    '重点卡片标题、摘要和建议也必须基于原文，不能把注释当说话人的原话。')

class MarkHighlights:
    def __init__(self,recordings):
        self.recordings=recordings;self.store=recordings.store;self.business=recordings.business
        self.business.handlers['recording_marks']=self.analyze
        self.business.transcript_preparer=self

    def build(self,owner,sid):
        session=self.store.get('sessions',owner,sid)
        hidden=set(session.get('hidden_mark_ids',[]))
        marks=sorted([m for m in self.store.rows('marks',owner,session_id=sid) if m['id'] not in hidden],key=lambda m:(m['t_ms'],m['id']))
        lines=self.recordings.segments(owner,sid) if session.get('consent')=='yes' else []
        groups=[]
        for mark in marks:
            start=max(0,mark['t_ms']-30000);end=mark['t_ms']+15000
            selected=[r for r in lines if r['end_ms']>=start and r['start_ms']<=end]
            if selected:start=selected[0]['start_ms'];end=selected[-1]['end_ms']
            if groups and start<=groups[-1]['end_ms'] and max(end,groups[-1]['end_ms'])-groups[-1]['start_ms']<=120000:
                groups[-1]['mark_ids'].append(mark['id']);groups[-1]['times_ms'].append(mark['t_ms']);groups[-1]['end_ms']=max(end,groups[-1]['end_ms'])
            else:groups.append({'id':mark['id'],'mark_ids':[mark['id']],'times_ms':[mark['t_ms']],'start_ms':start,'end_ms':end})
        expanded=[]
        for group in groups:
            group['focus_start_ms']=group['start_ms'];group['focus_end_ms']=group['end_ms']
            # Whole surrounding sentences let the model interpret replies and
            # split amounts. Overlapping short contexts share one analysis.
            selected=[r for r in lines if r['end_ms']>=min(group['times_ms'])-60000 and r['start_ms']<=max(group['times_ms'])+60000]
            if selected:group['start_ms']=selected[0]['start_ms'];group['end_ms']=selected[-1]['end_ms']
            if expanded and group['start_ms']<=expanded[-1]['end_ms'] and max(group['end_ms'],expanded[-1]['end_ms'])-expanded[-1]['start_ms']<=120000:
                prior=expanded[-1]
                prior['mark_ids']+=group['mark_ids'];prior['times_ms']+=group['times_ms']
                prior['end_ms']=max(prior['end_ms'],group['end_ms'])
                prior['focus_start_ms']=min(prior['focus_start_ms'],group['focus_start_ms']);prior['focus_end_ms']=max(prior['focus_end_ms'],group['focus_end_ms'])
            else:expanded.append(group)
        groups=expanded
        titles=session.get('mark_titles',{});saved=session.get('mark_analysis',{})
        for group in groups:
            selected=[r for r in lines if r['end_ms']>=group['start_ms'] and r['start_ms']<=group['end_ms']]
            refs=[{'source_id':'transcript:'+r['id'],'source_version':version(r),'session_id':sid,'start_ms':r['start_ms'],'end_ms':r['end_ms']} for r in selected]
            digest=hashlib.sha256(json.dumps([SEMANTIC_VERSION,self.business.gateway.model,group,refs],sort_keys=True).encode()).hexdigest()
            analysis=saved.get(group['id'],{})
            if analysis.get('evidence_digest')!=digest:analysis={}
            group.update(evidence_digest=digest,segments=selected,evidence_refs=refs,
                title=titles.get(group['id']) or analysis.get('title') or '标记的重点',
                summary=analysis.get('summary',''),topics=analysis.get('topics',[]),suggestion=analysis.get('suggestion',''),annotations=analysis.get('annotations',[]),
                status='ready' if analysis else 'pending' if selected else 'waiting_transcript')
        return session,groups

    def fingerprint(self,session,groups):
        return hashlib.sha256(json.dumps([session.get('transcript_revision',1),[(g['id'],g['evidence_digest']) for g in groups]],sort_keys=True).encode()).hexdigest()

    def queue(self,owner,sid):
        session,groups=self.build(owner,sid)
        if session.get('consent')!='yes' or not session.get('llm_consent_at'):return None
        if not any(g['segments'] and g['status']!='ready' for g in groups) or not self.business.gateway.configured:return None
        return self.business.submit(owner,'recording_marks',sid,self.fingerprint(session,groups))

    def snapshot(self,owner,sid):
        session,groups=self.build(owner,sid);job=self.queue(owner,sid)
        for g in groups:
            ids={r['source_id'] for r in g['evidence_refs']}
            g['faq_ids']=[r['id'] for r in self.store.rows('library_items',owner,source_session_id=sid) if r.get('status')=='active' and any(x.get('source_id') in ids for x in r.get('evidence_refs',[]))]
            g['faq_links']=[{'id':r['id'],'title':r['title']} for r in self.store.rows('library_items',owner) if r['id'] in g['faq_ids']]
            g['action_ids']=[r['id'] for r in self.store.rows('project_items',owner) if r.get('status')!='withdrawn' and r.get('kind') in {'action','commitment','gap','consensus'} and any(x.get('source_id') in ids for x in r.get('evidence_refs',[]))]
            g['related_actions']=[{'id':r['id'],'text':r['text'],'kind':r['kind']} for r in self.store.rows('project_items',owner) if r['id'] in g['action_ids']]
        return {'items':groups,'job_id':job['id'] if job else None,'status':job['status'] if job else 'ready','error':job.get('error') if job else None}

    def analyze(self,owner,job):
        session,groups=self.build(owner,job['object_id'])
        if not session.get('llm_consent_at') or self.fingerprint(session,groups)!=job['revision']:return {'superseded':True}
        result=dict(session.get('mark_analysis',{}))
        for g in groups:
            if not g['segments'] or g['status']=='ready':continue
            self.business.guard(owner,job)
            out=self.business.structured(SEMANTIC_PROMPT,{'times_ms':g['times_ms'],
                'focus_start_ms':g['focus_start_ms'],'focus_end_ms':g['focus_end_ms'],
                'segments':[{'id':r['id'],'speaker':r.get('speaker_name') or r.get('speaker'),'text':r['text'],'start_ms':r['start_ms'],'end_ms':r['end_ms']} for r in g['segments']]},timeout_seconds=90)
            if not isinstance(out.get('summary'),str) or not out['summary'].strip():raise Fault('MARK_SUMMARY_INVALID','重点整理尚未完成，可继续查看原文',502)
            result[g['id']]={'evidence_digest':g['evidence_digest'],'title':str(out.get('title') or '标记的重点')[:80],
                'summary':out['summary'][:3000],'annotations':self.valid_annotations(g,out.get('annotations',[])),'topics':[x for x in out.get('topics',[]) if x in {'需求','问题','表达','跟进','待核实'}],'suggestion':str(out.get('suggestion',''))[:1000]}
        with self.store.transaction(owner):
            self.business.guard(owner,job)
            current,latest=self.build(owner,job['object_id'])
            if self.fingerprint(current,latest)!=job['revision']:return {'superseded':True}
            self.store.update('sessions',owner,session['id'],{'mark_analysis':result})
        return {'highlights':len(result)}

    def valid_annotations(self,group,items):
        if not isinstance(items,list):return []
        lines={r['id']:r for r in group['segments']};result=[];seen=set()
        for item in items[:2]:
            if not isinstance(item,dict):continue
            anchor=lines.get(item.get('anchor_segment_id'))
            text=item.get('text');evidence=item.get('evidence')
            if not anchor or not isinstance(text,str) or not text.strip() or len(text)>700:continue
            if anchor['end_ms']<group['focus_start_ms'] or anchor['start_ms']>group['focus_end_ms']:continue
            if anchor['text'].strip('。！？,.!? \n') in {'嗯','嗯嗯','好','好的','行','行行','没问题','冇問題','OK','okay'}:continue
            if not isinstance(evidence,list) or not evidence:continue
            if any(not isinstance(e,dict) or e.get('segment_id') not in lines or not isinstance(e.get('quote'),str) or len(e['quote'].strip())<4 or e['quote'] not in lines[e['segment_id']]['text'] for e in evidence):continue
            if text.strip() in seen:continue
            seen.add(text.strip())
            result.append({'anchor_segment_id':anchor['id'],'text':text.strip(),
                'evidence':[{'segment_id':e['segment_id'],'quote':e['quote']} for e in evidence]})
        return result

    def prepare(self,owner,sid):
        """The shared durable job is the only model call for cards and enrichment.

        BusinessJobs.run atomically claims queued jobs. A competing reader waits
        for the same job; failed/interrupted attempts fall back without retrying.
        """
        for _ in range(2):
            session,groups=self.build(owner,sid);job=self.queue(owner,sid)
            if not job:return groups
            if job['status']=='queued':self.business.run(owner,job)
            deadline=time.monotonic()+95
            while True:
                state=self.store.get('business_jobs',owner,job['id'])
                if state['status']!='running' or time.monotonic()>=deadline:break
                time.sleep(.1)
            current,latest=self.build(owner,sid)
            if self.fingerprint(current,latest)==job['revision']:return latest
            # A late marker or transcript revision needs a different source job.
        return []

    def edit(self,owner,sid,mid,title=None,remove=False):
        with self.store.transaction(owner):
            mark=self.store.get('marks',owner,mid);session=self.store.get('sessions',owner,sid)
            if mark['session_id']!=sid:raise Fault('NOT_FOUND','标记不属于本场录音',404)
            if remove:
                self.store.update('sessions',owner,sid,{'hidden_mark_ids':sorted(set(session.get('hidden_mark_ids',[])+[mid]))})
            else:self.store.update('sessions',owner,sid,{'mark_titles':{**session.get('mark_titles',{}),mid:title.strip()}})
        return self.snapshot(owner,sid)
