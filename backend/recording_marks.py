"""User bookmarks enrich the existing recording; they never create parallel facts."""
import hashlib,json
from memory import Fault,L1,now
from adapters.sources import version

class MarkHighlights:
    def __init__(self,recordings):
        self.recordings=recordings;self.store=recordings.store;self.business=recordings.business
        self.business.handlers['recording_marks']=self.analyze

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
        titles=session.get('mark_titles',{});saved=session.get('mark_analysis',{})
        for group in groups:
            selected=[r for r in lines if r['end_ms']>=group['start_ms'] and r['start_ms']<=group['end_ms']]
            refs=[{'source_id':'transcript:'+r['id'],'source_version':version(r),'session_id':sid,'start_ms':r['start_ms'],'end_ms':r['end_ms']} for r in selected]
            digest=hashlib.sha256(json.dumps([group,refs],sort_keys=True).encode()).hexdigest()
            analysis=saved.get(group['id'],{})
            if analysis.get('evidence_digest')!=digest:analysis={}
            group.update(evidence_digest=digest,segments=selected,evidence_refs=refs,
                title=titles.get(group['id']) or analysis.get('title') or '标记的重点',
                summary=analysis.get('summary',''),topics=analysis.get('topics',[]),suggestion=analysis.get('suggestion',''),
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
            out=self.business.structured('整理用户标记的录音片段，只输出 {"title":"简短主题","summary":"这一段提到的内容","topics":["需求/问题/表达/跟进/待核实，可多选"],"suggestion":"一个可选的下一步建议"}。标记只表示关注，不猜标记原因或正负评价。未知说话人不当成本人经历，不把提议当承诺，不创造任务、提醒或事实。标题与摘要必须来自提供原文。',{'times_ms':g['times_ms'],'segments':[{'speaker':r.get('speaker_name') or r.get('speaker'),'text':r['text'],'start_ms':r['start_ms']} for r in g['segments']]},timeout_seconds=90)
            if not isinstance(out.get('summary'),str) or not out['summary'].strip():raise Fault('MARK_SUMMARY_INVALID','重点整理尚未完成，可继续查看原文',502)
            result[g['id']]={'evidence_digest':g['evidence_digest'],'title':str(out.get('title') or '标记的重点')[:80],
                'summary':out['summary'][:3000],'topics':[x for x in out.get('topics',[]) if x in {'需求','问题','表达','跟进','待核实'}],'suggestion':str(out.get('suggestion',''))[:1000]}
        with self.store.transaction(owner):
            self.business.guard(owner,job)
            current,latest=self.build(owner,job['object_id'])
            if self.fingerprint(current,latest)!=job['revision']:return {'superseded':True}
            self.store.update('sessions',owner,session['id'],{'mark_analysis':result})
        return {'highlights':len(result)}

    def edit(self,owner,sid,mid,title=None,remove=False):
        with self.store.transaction(owner):
            mark=self.store.get('marks',owner,mid);session=self.store.get('sessions',owner,sid)
            if mark['session_id']!=sid:raise Fault('NOT_FOUND','标记不属于本场录音',404)
            if remove:
                self.store.update('sessions',owner,sid,{'hidden_mark_ids':sorted(set(session.get('hidden_mark_ids',[])+[mid]))})
            else:self.store.update('sessions',owner,sid,{'mark_titles':{**session.get('mark_titles',{}),mid:title.strip()}})
        return self.snapshot(owner,sid)
