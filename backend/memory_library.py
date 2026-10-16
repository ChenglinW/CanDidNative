"""Source-bound FAQ, versioned documents, practice and descriptive speech metrics."""
import hashlib
import json
import re
from datetime import datetime, timezone
from uuid import UUID
from fastapi import Depends, Request
from pydantic import BaseModel, Field
from memory import Fault, L1, L2, now, ident
from adapters.sources import version, state_of
from adapters.sqlite_memory import SQLiteMemoryAdapter
from tasks.workspaces import WorkspaceStore

TOPICS={'sales':['产品与方案','价格与政策','需求与场景','异议与比较','交付与服务','故事与案例'],
        'interview':['自我介绍','经历与故事','专业问题','动机与规划','岗位与公司','其他']}

def words(text):return len(re.findall(r'[\u3400-\u9fff]|[A-Za-z]+(?:\'[A-Za-z]+)?|\d+',text))
def union_ms(rows):
    spans=sorted((max(0,r['start_ms']),max(0,r['end_ms'])) for r in rows if r['end_ms']>r['start_ms'])
    total=0;end=0
    for a,b in spans:total+=max(0,b-max(a,end));end=max(end,b)
    return total

class Library:
    def __init__(self,store,business,onboarding):
        self.store,self.business,self.onboarding=store,business,onboarding
        self.adapter=SQLiteMemoryAdapter(store);self.spaces=WorkspaceStore(store)
        business.handlers['library_extract']=self.extract
        business.handlers['library_sync']=self.sync
        business.handlers['library_mock']=self.mock

    def migrate(self,owner):
        with self.store.transaction(owner):
            known={r.get('legacy_id') for r in self.store.rows('library_items',owner)}
            for asset in self.store.rows('assets',owner):
                if asset['id'] in known or asset.get('status')=='withdrawn':continue
                if not asset.get('companion_expression') and asset.get('kind')!='qa_answer':continue
                refs=asset.get('evidence_refs',[])
                self.store.put('library_items',owner,{'id':asset['id'],'legacy_id':asset['id'],'title':asset.get('title','沟通素材'),
                    'text':asset.get('body',{}).get('text',''),'topic':TOPICS.get(asset.get('scenario'),TOPICS['sales'])[0],
                    'scenario':asset.get('scenario','sales'),'item_type':'faq' if ('问' in asset.get('title','') or asset.get('kind')=='qa_answer') else 'material',
                    'source_session_id':asset.get('source_session_id'),'workspace_id':asset.get('workspace_id'),
                    'evidence_refs':refs,'expression_state':'reusable' if asset.get('status')=='confirmed' or asset.get('user_edited') or '值得复用' in asset.get('tags',[]) else 'improve',
                    'version':asset.get('version',1),'user_edited':bool(asset.get('user_edited')),'status':'active','remind':True,
                    'producer':'library/migration','rubric_version':'library@1'},L2,source='ai')
                for revision in self.store.rows('asset_revisions',owner,asset_id=asset['id']):
                    self.store.put('library_versions',owner,{'item_id':asset['id'],'answer_version':revision.get('version',1),'text':revision.get('body',{}).get('text',''),'reason':'历史表达版本'},L1)
                old=self.spaces.scope(owner,'asset:'+asset['id'])
                if old:self.spaces.set_scope(owner,'faq:'+asset['id'],old['mode'],old['workspace_ids'],0)

    def refs_state(self,owner,row):
        if state_of(row)=='stale':return 'expired'
        refs=row.get('evidence_refs',[])
        if row.get('requires_document') and not any(r.get('source_id','').startswith('document:') for r in refs):return 'missing'
        if not refs:return 'missing'
        status=self.adapter.references_status(owner,refs,None)
        if any(r['status']!='current' for r in status):return 'changed'
        return 'ready'

    def item(self,owner,id):
        row=self.store.get('library_items',owner,id)
        all_uses=self.store.rows('library_uses',owner,item_id=id)
        uses=[u for u in all_uses if u.get('answer_version')==row['version'] and all(r['status']=='current' for r in self.adapter.references_status(owner,u.get('evidence_refs',[])))]
        practice=self.store.rows('library_practices',owner,item_id=id)
        display_refs=[]
        for ref in row.get('evidence_refs',[]):
            display=dict(ref)
            if ref.get('source_id','').startswith('document:'):
                try:
                    doc=self.store.get('documents',owner,ref['source_id'].split(':',1)[1]);display.update(title=doc.get('title','背景资料'),original_id=doc.get('onboarding_original_id'))
                except Fault:display.update(title='原资料已移除')
            display_refs.append(display)
        return {**row,'evidence_refs':display_refs,'evidence_state':self.refs_state(owner,row),'uses':all_uses,
            'effect_state':'positive' if any(u.get('outcome')=='positive' for u in uses) else 'questioned' if any(u.get('outcome')=='questioned' for u in uses) else 'untried',
            'practices':practice,'history':self.store.rows('library_versions',owner,item_id=id),
            'topics':TOPICS.get(row.get('scenario'),TOPICS['sales'])}

    def snapshot(self,owner):
        self.migrate(owner)
        # Idempotent task keys let existing recordings acquire richer FAQ without rewriting legacy assets.
        for s in self.store.rows('sessions',owner):
            if self.business.gateway.configured and (s.get('pipeline_status')=='done' or (s.get('kind')=='oral_debrief' and self.store.rows('transcript_segments',owner,session_id=s['id']))) and not s.get('fixture') and s.get('kind')!='practice':
                self.business.submit(owner,'library_extract',s['id'],str(s.get('transcript_revision',1)))
        for j in self.store.rows('business_jobs',owner,kind='library_sync'):
            if j['status']=='failed' and j.get('error')=='新资料仍在解析，完成后可继续同步' and self.store.rows('documents',owner,onboarding_original_id=j['revision']):self.business.retry(owner,j['id'])
        return {'items':[self.item(owner,r['id']) for r in self.store.rows('library_items',owner) if r.get('status')!='withdrawn'],
            'documents':self.documents(owner),'metrics':self.metrics(owner),'topics':TOPICS,
            'updates':[{'id':j['id'],'status':j['status'],'message':j.get('result',{}).get('message',j.get('error') or j.get('progress',''))} for j in self.store.rows('business_jobs',owner) if j['kind'] in {'library_sync','library_extract'}][:10]}

    def edit(self,owner,id,body):
        with self.store.transaction(owner):
            row=self.store.get('library_items',owner,id)
            if row['version']!=body.expected_version:raise Fault('VERSION_CONFLICT','说法已更新，你的输入仍可保留后重试',409)
            self.store.put('library_versions',owner,{'item_id':id,'answer_version':row['version'],'text':row['text'],'valid_until':row.get('valid_until'),'reason':'编辑前版本'},L1)
            patch={k:v for k,v in body.model_dump().items() if k!='expected_version' and v is not None}
            if 'text' in patch:
                patch.update(user_edited=True,expression_state='reusable')
                if patch['text']==row.get('suggested_text') and row.get('suggested_document_id'):
                    doc=self.store.get('documents',owner,row['suggested_document_id'])
                    patch.update(evidence_refs=[r for r in row.get('evidence_refs',[]) if not r.get('source_id','').startswith('document:')]+[{'source_id':'document:'+doc['id'],'source_version':version(doc)}],suggested_text=None,suggested_document_id=None)
            if 'topic' in patch and patch['topic'] not in TOPICS.get(row.get('scenario'),TOPICS['sales']):raise Fault('TOPIC_INVALID','请选择当前场景的主题',422)
            patch.update(version=row['version']+1)
            self.store.update('library_items',owner,id,patch,actor=owner)
            return self.item(owner,id)

    def extract(self,owner,job):
        s=self.store.get('sessions',owner,job['object_id']);rev=int(job['revision'])
        lines=[r for r in self.store.rows('transcript_segments',owner,session_id=s['id']) if r.get('transcript_revision',1)==rev]
        if not lines or s.get('fixture') or s.get('kind')=='practice':return {'items':0}
        if rev!=s.get('transcript_revision',1):raise Fault('SOURCE_SUPERSEDED','原文已更新',409)
        if s.get('consent')!='yes' and not all(x.get('speaker')=='self' for x in lines):return {'items':0}
        scenario=s.get('scenario','sales');topics=TOPICS.get(scenario,TOPICS['sales'])
        workspace=s.get('customer_workspace_id') if s.get('customer_confirmed_at') else None
        docs=[d for d in self.store.rows('documents',owner) if d.get('text') and ((workspace and self.spaces.allowed(owner,'document',d,workspace)) or (not workspace and (self.spaces.scope(owner,'document:'+d['id']) or {}).get('mode')=='personal'))]
        docs=[d for d in docs if self.adapter.references_status(owner,[{'source_id':'document:'+d['id'],'source_version':version(d)}],workspace)[0]['status']=='current']
        result=self.business.structured('从沟通原文提取有依据的常见问题及可改进/复用表达。只返回 {"items":[{"question":"问题","answer":"建议说法，不能编报价、承诺或经历","topic":"主题","segment_ids":["原文id"],"state":"improve或reusable","used_text":"原文实际说法","outcome":"unknown或positive或questioned","reason":"有具体原文依据的效果说明","document_id":"实际适用资料id或空","document_quote":"资料逐字原文或空","general_method":false}]}。最多12条。普通追问不代表失败，只有明确理解/行动才positive。未知说话人不写成用户经历。原文不足则items为空。只有可抽象为提问、澄清、确认下一步等通用方法时general_method=true，客户事实不是通用方法。',
            {'scenario':scenario,'topics':topics,'segments':[{'id':r['id'],'speaker':r.get('speaker'),'text':r['text']} for r in lines],'documents':[{'id':d['id'],'text':d['text'][:18000]} for d in docs]},timeout_seconds=180)
        byid={r['id']:r for r in lines};added=0
        with self.store.transaction(owner):
            self.business.guard(owner,job)
            if self.store.get('sessions',owner,s['id']).get('transcript_revision',1)!=rev:raise Fault('SOURCE_SUPERSEDED','原文已更新',409)
            for n,data in enumerate(result.get('items',[])[:12]):
                if not isinstance(data,dict) or not data.get('question') or not data.get('answer'):continue
                evidence=[byid[x] for x in data.get('segment_ids',[]) if x in byid]
                if not evidence:continue
                key=s['id']+':'+str(rev)+':'+str(n)
                if self.store.rows('library_items',owner,extraction_key=key):continue
                refs=[{'source_id':'transcript:'+r['id'],'source_version':version(r),'session_id':s['id'],'start_ms':r['start_ms'],'end_ms':r['end_ms']} for r in evidence]
                cited=next((d for d in docs if d['id']==data.get('document_id') and data.get('document_quote') and data['document_quote'] in d['text']),None)
                if cited:refs.append({'source_id':'document:'+cited['id'],'source_version':version(cited),'quote':data['document_quote']})
                faq_key=hashlib.sha256((scenario+'|'+str(workspace or s['id'])+'|'+re.sub(r'[^\w\u4e00-\u9fff]','',str(data['question']).casefold())).encode()).hexdigest()
                existing=next(iter(self.store.rows('library_items',owner,faq_key=faq_key)),None)
                row=existing or self.store.put('library_items',owner,{'faq_key':faq_key,'extraction_key':key,'title':str(data['question'])[:200],'text':str(data['answer'])[:6000],
                    'scenario':scenario,'topic':data.get('topic') if data.get('topic') in topics else topics[0],'item_type':'faq','version':1,
                    'source_session_id':s['id'],'requires_document':data.get('topic') in {'价格与政策','交付与服务'},'evidence_refs':refs,'expression_state':'reusable' if data.get('state')=='reusable' else 'improve',
                    'remind':True,'status':'active','producer':'agent/library','rubric_version':'library@1'},L2,source='ai')
                if existing and existing.get('source_session_id')==s['id'] and not existing.get('user_edited'):
                    self.store.put('library_versions',owner,{'item_id':row['id'],'answer_version':row['version'],'text':row['text'],'reason':'原文修订前版本'},L1)
                    row=self.store.update('library_items',owner,row['id'],{'text':str(data['answer'])[:6000],'evidence_refs':refs,'version':row['version']+1})
                # Outcome records describe a source utterance, never prove an AI rewrite worked.
                self.store.put('library_uses',owner,{'item_id':row['id'],'answer_version':0,'session_id':s['id'],'evidence_type':'recalled' if s.get('kind')=='oral_debrief' else 'recording','text':data.get('used_text',''),
                    'outcome':data.get('outcome','unknown'),'reason':data.get('reason',''),'evidence_refs':refs},L1)
                # Record only verifiable verbatim reuse of an existing answer, not an AI rewrite.
                used=str(data.get('used_text',''))
                if s.get('kind')!='oral_debrief' and len(used)>=5 and any(used in e['text'] for e in evidence):
                    for previous in self.store.rows('library_items',owner):
                        if previous.get('text')!=used:continue
                        if not workspace or not self.spaces.allowed(owner,'faq',previous,workspace):continue
                        key=previous['id']+':'+str(previous['version'])+':'+s['id']+':'+str(rev)
                        if not self.store.rows('library_uses',owner,usage_key=key):self.store.put('library_uses',owner,{'usage_key':key,'item_id':previous['id'],'answer_version':previous['version'],'session_id':s['id'],'text':used,'outcome':data.get('outcome','unknown'),'reason':data.get('reason',''),'evidence_refs':refs},L1)
                        if data.get('outcome') in {'positive','questioned'}:self.store.update('library_items',owner,previous['id'],{'expression_state':'reusable' if data['outcome']=='positive' else 'improve'})
                if data.get('general_method') is True:
                    topic=row['topic'];common_key=scenario+':'+topic
                    if not self.store.rows('library_items',owner,general_key=common_key):
                        common=self.store.put('library_items',owner,{'general_key':common_key,'title':topic+'：先确认，再展开','text':'您目前最关心的是哪一项？我先确认这一点，再展开说明。最后一起明确下一步。',
                            'topic':topic,'scenario':scenario,'item_type':'material','version':1,'status':'active','expression_state':'reusable','remind':True,
                            'evidence_refs':[],'private_provenance':refs,'producer':'agent/general-method','rubric_version':'library@1'},L2,source='ai')
                        self.spaces.set_scope(owner,'faq:'+common['id'],'personal',[],0)
                added+=1
        return {'items':added}

    def documents(self,owner):
        output=[]
        for receipt in self.onboarding.documents(owner):
            original=self.store.get('documents',owner,receipt['id'])
            family=next(iter(self.store.rows('document_families',owner,original_id=original['id'])),None)
            if not family:
                family=next((f for f in self.store.rows('document_families',owner) if original['id'] in f.get('versions',[])),None)
            parsed=self.store.rows('documents',owner,onboarding_original_id=original['id'])
            if family and family.get('current_id')!=original['id']:continue
            pending_job=next((j for j in self.store.rows('business_jobs',owner,kind='library_sync') if family and j['object_id']==family['id'] and j['revision']==family.get('pending_id')),None)
            output.append({**receipt,'error':pending_job.get('error') if pending_job and pending_job.get('status')=='failed' else receipt.get('error'),'family_id':family['id'] if family else original['id'],'version':family.get('version',1) if family else 1,
                'versions':family.get('versions',[original['id']]) if family else [original['id']],
                'sha256':original['sha256'],'pages':parsed[0].get('pages',[]) if parsed else [],'text':parsed[0].get('text','') if parsed else '',
                'parsed_id':parsed[0]['id'] if parsed else None,'changes':family.get('changes',[]) if family else [],
                'pending_id':family.get('pending_id') if family else None})
        return output

    def replace(self,owner,old_id,new_id):
        with self.store.transaction(owner):
            old=self.store.get('documents',owner,old_id);new=self.store.get('documents',owner,new_id)
            if self.onboarding.removed(owner,old_id) or self.onboarding.removed(owner,new_id):raise Fault('DOCUMENT_REMOVED','资料已移除',409)
            family=next((f for f in self.store.rows('document_families',owner) if old_id in f.get('versions',[])),None)
            if not family:family=self.store.put('document_families',owner,{'original_id':old_id,'current_id':old_id,'version':1,'versions':[old_id]},L1)
            if new_id in family['versions']:return family
            family=self.store.update('document_families',owner,family['id'],{'versions':family['versions']+[new_id],'pending_id':new_id})
            return self.business.submit(owner,'library_sync',family['id'],new_id)

    def sync(self,owner,job):
        family=self.store.get('document_families',owner,job['object_id']);new_id=job['revision']
        if family.get('pending_id')!=new_id:return {'message':'已有更新版本，保留当前结果'}
        parsed=self.store.rows('documents',owner,onboarding_original_id=new_id)
        if not parsed:raise Fault('DOCUMENT_NOT_READY','新资料仍在解析，完成后可继续同步',409)
        new=parsed[0];old_id=family['current_id'];old=next(iter(self.store.rows('documents',owner,onboarding_original_id=old_id)),None)
        affected=[r for r in self.store.rows('library_items',owner) if old and any(ref.get('source_id')=='document:'+old['id'] for ref in r.get('evidence_refs',[]))]
        revisions={r['id']:r['version'] for r in affected}
        result=self.business.structured('对比两版资料，输出 {"changes":["具体变化"],"answers":[{"id":"回答id","text":"只更新有明确新资料支撑的事实，保留其他措辞","quote":"新资料逐字引用","conflict":false}]}。用户已改写的回答只提供建议，不直接覆盖；不受影响的回答不返回。缺页或OCR疑问处不能替换数字。',
            {'old':(old or {}).get('text',''),'new':new['text'],'pages':new.get('pages',[]),'answers':[{'id':r['id'],'text':r['text'],'user_edited':r.get('user_edited',False)} for r in affected]})
        with self.store.transaction(owner):
            self.business.guard(owner,job);family=self.store.get('document_families',owner,family['id'])
            if family.get('pending_id')!=new_id:return {'message':'已有更新版本'}
            for answer in result.get('answers',[]):
                id=answer.get('id')
                if id not in revisions:continue
                row=self.store.get('library_items',owner,id)
                if row['version']!=revisions[id]:continue
                quote=answer.get('quote','');text=answer.get('text','')
                if not quote or quote not in new['text'] or not text:continue
                if row.get('user_edited') or answer.get('conflict') or any(p.get('review_required') for p in new.get('pages',[]) if quote in p.get('text','')):
                    self.store.update('library_items',owner,id,{'suggested_text':text,'suggested_document_id':new['id']});continue
                self.store.put('library_versions',owner,{'item_id':id,'answer_version':row['version'],'text':row['text'],'evidence_refs':row.get('evidence_refs',[]),'reason':'资料同步前版本'},L1)
                refs=[ref for ref in row.get('evidence_refs',[]) if ref.get('source_id')!='document:'+old['id']]+[{'source_id':'document:'+new['id'],'source_version':version(new)}]
                self.store.update('library_items',owner,id,{'text':text,'version':row['version']+1,'evidence_refs':refs,'synced_at':now()})
            answered={a.get('id') for a in result.get('answers',[])}
            for candidate in affected:
                if candidate['id'] in answered:continue
                current=self.store.get('library_items',owner,candidate['id'])
                refs=current.get('evidence_refs',[])
                oldrefs=[r for r in refs if r.get('source_id')=='document:'+old['id']]
                if oldrefs and all(r.get('quote') and r['quote'] in new['text'] for r in oldrefs):
                    refs=[{**r,'source_id':'document:'+new['id'],'source_version':version(new)} if r in oldrefs else r for r in refs]
                    self.store.update('library_items',owner,current['id'],{'evidence_refs':refs})
            # Scope follows the original; an update never broadens its audience.
            if old:
                scope=self.spaces.scope(owner,'document:'+old['id'])
                if scope:
                    prior=self.spaces.scope(owner,'document:'+new['id'])
                    self.spaces.set_scope(owner,'document:'+new['id'],scope['mode'],scope['workspace_ids'],prior['revision'] if prior else 0)
            changes=[str(x)[:500] for x in result.get('changes',[])][:20]
            self.store.update('document_families',owner,family['id'],{'current_id':new_id,'pending_id':None,'version':family['version']+1,'changes':changes})
            # Immutable originals remain available in history; outdated extracted evidence is not current.
            # Supersession is derived by the adapter from family.current_id; original evidence is immutable.
        return {'message':'资料已更新，关联说法已同步；你的改写已保留','changes':changes}

    def practice(self,owner,id,request_id,answer='',practice_id=None):
        row=self.item(owner,id)
        if practice_id:
            p=self.store.get('library_practices',owner,practice_id)
            if p['item_id']!=id:raise Fault('BAD_REQUEST','练习不匹配',422)
        else:
            prior=self.store.rows('library_practices',owner,request_id=request_id)
            if prior:
                p=prior[0]
                if p['item_id']!=id:raise Fault('REQUEST_CONFLICT','这个请求属于另一道练习',409)
            else:p=self.store.put('library_practices',owner,{'item_id':id,'request_id':request_id,'question':row['title'],
                'answer_version':row['version'],'evidence_refs':row.get('evidence_refs',[]),'status':'awaiting_answer','turns':[]},L1)
        if answer.strip():
            job=self.business.submit(owner,'library_mock',p['id'],request_id,{'answer':answer.strip(),'item_version':row['version'],'question':p['question'],'item_text':row['text'],'evidence_refs':row.get('evidence_refs',[])})
            if job['status'] in {'failed','interrupted','cancelled'}:self.business.retry(owner,job['id'])
            return {**p,'job_id':job['id']}
        return p

    def mock(self,owner,job):
        p=self.store.get('library_practices',owner,job['object_id']);row=self.item(owner,p['item_id'])
        input_refs=job['payload'].get('evidence_refs',row.get('evidence_refs',[]))
        refs=self.adapter.read_evidence(owner,input_refs,workspace_id=None)['items'] if input_refs else []
        result=self.business.structured('你是沟通练习教练，扮演对应场景的客户/面试官。评价实际回答，不能编造客户真实反应或事实。只输出 {"feedback":"具体优点、一个优先改进点、资料缺口","next_question":"下一句客户/面试官追问","suggested_text":"保留用户原意的更好说法"}。引用资料不够时明确说明，不提供臆测数字。',
            {'scenario':row.get('scenario'),'question':job['payload'].get('question',p['question']),'answer':job['payload']['answer'],'current_saying':job['payload'].get('item_text',row['text']),'evidence':refs})
        with self.store.transaction(owner):
            self.business.guard(owner,job);p=self.store.get('library_practices',owner,p['id'])
            if any(t.get('request_id')==job['revision'] for t in p['turns']):return {'practice_id':p['id']}
            turn={'request_id':job['revision'],'question':job['payload'].get('question',p['question']),'answer':job['payload']['answer'],'feedback':str(result.get('feedback','')),
                'suggested_text':str(result.get('suggested_text','')),'answer_version':job['payload']['item_version'],'evidence_versions':[r.get('source_version') for r in input_refs]}
            self.store.update('library_practices',owner,p['id'],{'status':'reviewed','turns':p['turns']+[turn],'question':str(result.get('next_question') or row['title'])})
        return {'practice_id':p['id']}

    def metrics(self,owner):
        rows=[];seen=set()
        for s in sorted(self.store.rows('sessions',owner),key=lambda x:x.get('recorded_at') or x['created_at']):
            if s.get('fixture') or s.get('kind') in {'practice','oral_debrief'} or s.get('consent')!='yes':continue
            media=self.store.rows('session_media',owner,session_id=s['id'])
            if not media:continue
            digest=media[0].get('sha256') or s['id']
            if digest in seen:continue
            lines=[r for r in self.store.rows('transcript_segments',owner,session_id=s['id']) if r.get('transcript_revision',1)==s.get('transcript_revision',1)]
            mine=[r for r in lines if r.get('speaker')=='self'];ms=union_ms(mine);allms=union_ms(lines)
            if not ms:continue
            seen.add(digest);text=' '.join(r['text'] for r in mine);count=words(text)
            fillers=sum(len(re.findall(pattern,text,re.I)) for pattern in [r'嗯',r'呃',r'\bum\b',r'\buh\b',r'你知道',r'就是说'])
            rows.append({'id':s['id'],'title':s.get('title','沟通录音'),'date':s.get('recorded_at') or s['created_at'],'scenario':s.get('scenario','sales'),
                'self_ms':ms,'total_ms':allms,'words':count,'fillers':fillers,'pace':round(count*60000/ms,1),
                'share':round(ms*100/allms,1) if allms else 0,'filler_rate':round(fillers*60000/ms,1),
                'coverage':round(sum(r['end_ms']-r['start_ms'] for r in lines if r.get('speaker') in {'self','other'})*100/max(1,sum(r['end_ms']-r['start_ms'] for r in lines)),1),
                'transcript_revision':s.get('transcript_revision',1)})
        def aggregate(group):
            ms=sum(x['self_ms'] for x in group);total=sum(x['total_ms'] for x in group)
            return {'count':len(group),'self_ms':ms,'pace':round(sum(x['words'] for x in group)*60000/ms,1) if ms else None,
                    'share':round(ms*100/total,1) if total else None,'filler_rate':round(sum(x['fillers'] for x in group)*60000/ms,1) if ms else None,
                    'from':group[0]['date'] if group else None,'to':group[-1]['date'] if group else None}
        return {'sessions':rows,'recent':aggregate(rows[-3:]),'baseline':aggregate(rows[:3]) if len(rows)>=6 else None,
            'note':'按本人有效句段时长加权；语速为转写估计，口头禅可能被 ASR 省略。部分认领仅统计已认领部分；精确停顿与评分雷达暂未提供。'}

class Edit(BaseModel):
    expected_version:int=Field(ge=1)
    text:str|None=Field(default=None,min_length=1,max_length=12000)
    topic:str|None=None
    valid_until:str|None=None
    remind:bool|None=None
class Practice(BaseModel):
    client_request_id:UUID
    practice_id:UUID|None=None
    answer:str=Field(default='',max_length=12000)
class Replacement(BaseModel):new_document_id:UUID
class Link(BaseModel):
    document_id:UUID
    expected_version:int=Field(ge=1)
class OCRPage(BaseModel):
    page:int=Field(ge=1,le=300)
    text:str=Field(max_length=200000)
    source:str='vision'
    review_required:bool=False
class OCR(BaseModel):
    sha256:str
    processor:str='apple-vision@1'
    pages:list[OCRPage]=Field(max_length=300)


def install(app,owner,get_library):
    @app.get('/v1/library')
    def snapshot(uid=Depends(owner)):return get_library().snapshot(uid)
    @app.get('/v1/library/items/{id}')
    def item(id:UUID,uid=Depends(owner)):return get_library().item(uid,str(id))
    @app.patch('/v1/library/items/{id}')
    def edit(id:UUID,body:Edit,uid=Depends(owner)):return get_library().edit(uid,str(id),body)
    @app.post('/v1/library/items/{id}/document')
    def link(id:UUID,body:Link,uid=Depends(owner)):
        lib=get_library()
        with lib.store.transaction(uid):
            row=lib.store.get('library_items',uid,str(id));doc=lib.store.get('documents',uid,str(body.document_id))
            if lib.adapter.references_status(uid,[{'source_id':'document:'+doc['id'],'source_version':version(doc)}])[0]['status']!='current':raise Fault('SOURCE_SUPERSEDED','请选择当前可用资料',409)
            if not doc.get('text'):raise Fault('DOCUMENT_NOT_READY','资料仍在解析',409)
            if row['version']!=body.expected_version:raise Fault('VERSION_CONFLICT','回答已更新',409)
            refs=row.get('evidence_refs',[])+[{'source_id':'document:'+doc['id'],'source_version':version(doc)}]
            lib.store.update('library_items',uid,row['id'],{'evidence_refs':refs,'version':row['version']+1})
            return lib.item(uid,row['id'])
    @app.post('/v1/library/items/{id}/practice')
    def practice(id:UUID,body:Practice,uid=Depends(owner)):
        return get_library().practice(uid,str(id),str(body.client_request_id),body.answer,str(body.practice_id) if body.practice_id else None)
    @app.get('/v1/library/practices/{id}')
    def get_practice(id:UUID,uid=Depends(owner)):return get_library().store.get('library_practices',uid,str(id))
    @app.get('/v1/library/documents/{id}/file')
    def original(id:UUID,uid=Depends(owner)):
        from fastapi.responses import FileResponse
        lib=get_library();row=lib.store.get('documents',uid,str(id))
        if lib.onboarding.removed(uid,str(id)) or row.get('material_kind')!='onboarding_original':raise Fault('NOT_FOUND','资料已移除',404)
        return FileResponse(lib.store.root/row['storage_path'],filename=row['title'])
    @app.post('/v1/library/documents/{id}/replace')
    def replace(id:UUID,body:Replacement,uid=Depends(owner)):return get_library().replace(uid,str(id),str(body.new_document_id))
    @app.post('/v1/library/documents/{id}/retry-sync')
    def retry_sync(id:UUID,uid=Depends(owner)):
        lib=get_library()
        family=next((f for f in lib.store.rows('document_families',uid) if str(id) in f.get('versions',[])),None)
        jobs=[j for j in lib.store.rows('business_jobs',uid,kind='library_sync') if family and j['object_id']==family['id'] and j['revision']==family.get('pending_id')]
        if not jobs:raise Fault('NOT_FOUND','没有待继续的同步任务',404)
        return lib.business.retry(uid,jobs[0]['id'])
    @app.post('/v1/library/documents/{id}/restore')
    def restore(id:UUID,body:Replacement,uid=Depends(owner)):
        lib=get_library()
        with lib.store.transaction(uid):
            family=next((f for f in lib.store.rows('document_families',uid) if str(id) in f.get('versions',[])),None)
            target=str(body.new_document_id)
            if not family or target not in family['versions'] or lib.onboarding.removed(uid,target):raise Fault('NOT_FOUND','历史资料不可用',404)
            return lib.store.update('document_families',uid,family['id'],{'current_id':target,'pending_id':None,'version':family['version']+1,'changes':['已恢复历史资料，相关回答按当前依据重新核对']})
    @app.post('/v1/library/documents/{id}/ocr')
    def ocr(id:UUID,body:OCR,uid=Depends(owner)):return get_library().onboarding.ocr(uid,str(id),body.model_dump())
