"""Sales/interview product domain. Global recordings and conversation scopes stay separate.
All model writes are grounded against the current immutable transcript revision.
"""
import hashlib
import json
from datetime import datetime
from zoneinfo import ZoneInfo
from memory import Fault, L1, L2, L3, now, ident
from tasks.workspaces import WorkspaceStore
from adapters.sources import version, source, collect

KINDS={'consensus','question','answer','commitment','action','internal','gap','story','weakness'}
STAGES={'sales':{'demand','proposal','negotiation','won','lost'},'interview':{'preparing','hr','business','final','offer','closed'}}

class Product:
    def __init__(self, store, business=None):
        self.store=store;self.spaces=WorkspaceStore(store);self.business=business
        if business:
            business.handlers.update(meeting_analysis=self.analyze,preparation=self.prepare,discovery=self.discover,followup_rewrite=self.rewrite_followup)

    @staticmethod
    def validate_dates(payload,keys):
        for key in keys:
            value=payload.get(key)
            if not value:continue
            try:
                if datetime.fromisoformat(value.replace('Z','+00:00')).tzinfo is None:raise ValueError()
            except (ValueError,AttributeError):raise Fault('DATE_INVALID','时间需要合法日期与时区',422) from None

    def migrate(self, owner):
        """Idempotent, additive migration, only unique explicit occasion links are merged."""
        with self.store.transaction(owner):
            self.store.check_owner(owner)
            spaces=self.spaces.list(owner)
            occasions=self.store.rows('occasions',owner)
            mapping={}
            for occasion in occasions:
                candidates=[s for s in spaces if self.store.get('chat_threads',owner,s['default_thread_id']).get('occasion_id')==occasion['id']]
                if len(candidates)==1:mapping[occasion['id']]=candidates[0]['id']
                elif not candidates:
                    space=self.spaces.create(owner,occasion['title'],occasion.get('fields',{}).get('goal',''),'occasion-migration:'+occasion['id'])
                    spaces.append(space);mapping[occasion['id']]=space['id']
                # Multiple old chats stay independent; expose the occasion as unassigned instead of merging.
            for space in spaces:
                if space.get('product_schema') or space.get('is_scope_context'):continue
                occasion=next((o for o in occasions if mapping.get(o['id'])==space['id']),None)
                scenario=space.get('scenario') or (occasion.get('scenario') if occasion else None)
                self.store.update('project_spaces',owner,space['id'],{'product_schema':1,
                    'scenario':scenario,'organization':space.get('organization',''),'opportunity':space.get('opportunity',''),
                    'stage':space.get('stage') or ('demand' if scenario=='sales' else 'preparing'),
                    'participants':space.get('participants',[]),'result':space.get('result'),'occasion_ids':[occasion['id']] if occasion else [],'is_example':bool(occasion and occasion.get('fixture'))})
                if occasion and not occasion.get('fixture'):
                    self.spaces.set_scope(owner,'occasion:'+occasion['id'],'spaces',[space['id']],(self.spaces.scope(owner,'occasion:'+occasion['id']) or {}).get('revision',0))
            for session in self.store.rows('sessions',owner):
                project=mapping.get(session.get('occasion_id'))
                if not project or any(m.get('legacy_session_id')==session['id'] for m in self.store.rows('business_meetings',owner)):continue
                meeting=self.meeting(owner,project,{'title':session.get('title') or '历史沟通','goal':'','kind':session.get('kind','live'),
                    'scheduled_at':None,'actual_at':session.get('started_at'),'timezone':'Asia/Hong_Kong','legacy_session_id':session['id'],
                    'is_practice':session.get('kind')=='practice','is_example':bool(session.get('fixture')),'status':'completed' if session.get('pipeline_status')=='done' else 'recorded'},'legacy:'+session['id'])
                self.link(owner,meeting['id'],session['id'])

    def projects(self,owner):
        self.migrate(owner)
        return [self.spaces.view(owner,s) for s in self.spaces.list(owner) if not s.get('is_scope_context')]

    def project(self,owner,pid):
        row=self.spaces.get(owner,pid)
        if row.get('is_scope_context'):raise Fault('NOT_A_PROJECT','此范围不是业务项目',422)
        return row

    def create(self,owner,payload,request_id):
        scenario=payload.get('scenario')
        if scenario not in STAGES:raise Fault('SCENARIO_REQUIRED','请选择销售或面试',422)
        with self.store.transaction(owner):
            prior=next((p for p in self.spaces.list(owner) if p.get('client_request_id')==request_id),None)
            canonical={k:payload.get(k) for k in ('name','goal','scenario','organization','opportunity','participants')}
            if prior and prior.get('product_input')!=canonical:raise Fault('REQUEST_CONFLICT','重试内容与原项目不同',409)
            space=self.spaces.create(owner,payload['name'],payload.get('goal',''),request_id)
            if prior:return self.spaces.view(owner,space)
            space=self.store.update('project_spaces',owner,space['id'],{**canonical,'product_schema':1,
                'stage':'demand' if scenario=='sales' else 'preparing','result':None,'occasion_ids':[],'is_example':False,'product_input':canonical})
            return self.spaces.view(owner,space)

    def update_project(self,owner,pid,patch,expected):
        with self.store.transaction(owner):
            row=self.project(owner,pid)
            if row['version']!=expected:raise Fault('VERSION_CONFLICT','项目已更新，请刷新',409)
            if patch.get('stage') and patch['stage'] not in STAGES.get(patch.get('scenario',row.get('scenario')),set()):raise Fault('STAGE_INVALID','项目阶段与场景不一致',422)
            if row['status']=='archived':raise Fault('WORKSPACE_ARCHIVED','请先恢复项目',409)
            if any(t['status'] in {'queued','running','waiting_input'} for t in self.store.rows('agent_tasks',owner,workspace_id=pid)):raise Fault('WORKSPACE_BUSY','请先完成或停止项目问答再修改方向',409)
            updated=self.store.update('project_spaces',owner,pid,{**patch,'version':row['version']+1,'context_version':row['context_version']+1})
            self.store.update('chat_threads',owner,row['default_thread_id'],{'title':updated['name']})
            return self.spaces.view(owner,updated)

    def meeting(self,owner,pid,payload,request_id):
        with self.store.transaction(owner):
            project=self.project(owner,pid)
            if project['status']=='archived':raise Fault('WORKSPACE_ARCHIVED','请先恢复项目',409)
            prior=next((m for m in self.store.rows('business_meetings',owner,project_id=pid) if m['request_id']==request_id),None)
            if prior:
                if prior.get('creation_input')!=payload:raise Fault('REQUEST_CONFLICT','重试内容与原场次不同',409)
                return prior
            self.validate_dates(payload,('scheduled_at','actual_at'))
            date=payload.get('scheduled_at'); tz=payload.get('timezone','Asia/Hong_Kong')
            try:
                ZoneInfo(tz)
                if date and datetime.fromisoformat(date.replace('Z','+00:00')).tzinfo is None:raise ValueError()
            except (ValueError,KeyError):raise Fault('DATE_INVALID','计划时间需要时区',422) from None
            return self.store.put('business_meetings',owner,{**payload,'project_id':pid,'scenario':project.get('scenario'),
                'request_id':request_id,'creation_input':payload,'version':1,'participants':payload.get('participants',[]),
                'goal':payload.get('goal',''),'status':payload.get('status','planned'),
                'is_practice':payload.get('is_practice',False),'is_example':payload.get('is_example',False)},L1)

    def get_meeting(self,owner,mid):
        self.store.check_owner(owner); return self.store.get('business_meetings',owner,mid)

    def patch_meeting(self,owner,mid,patch,expected):
        with self.store.transaction(owner):
            row=self.get_meeting(owner,mid)
            self.validate_dates(patch,('scheduled_at','actual_at'))
            if row['version']!=expected:raise Fault('VERSION_CONFLICT','场次已更新，请刷新',409)
            self.project(owner,row['project_id'])
            return self.store.update('business_meetings',owner,mid,{**patch,'version':expected+1})

    def link(self,owner,mid,sid,active=True):
        with self.store.transaction(owner):
            meeting=self.get_meeting(owner,mid);session=self.store.get('sessions',owner,sid)
            if session.get('fixture') and not meeting.get('is_example'):raise Fault('EXAMPLE_RECORDING','示例录音不能关联真实场次',422)
            prior=self.store.rows('recording_links',owner,meeting_id=mid,session_id=sid)
            if prior:
                if prior[0]['active']==active:
                    return self.store.update('recording_links',owner,prior[0]['id'],{'association_source':'manual'})
                return self.store.update('recording_links',owner,prior[0]['id'],{'active':active,'version':prior[0]['version']+1})
            return self.store.put('recording_links',owner,{'meeting_id':mid,'project_id':meeting['project_id'],'session_id':sid,'active':active,'version':1},L1)

    def sync_recording(self,owner,sid):
        """Only a tag carrying an explicit project ID can automatically form a business scene."""
        with self.store.transaction(owner):
            session=self.store.get('sessions',owner,sid)
            if session.get('fixture'):return
            self.migrate(owner)
            valid={p['id'] for p in self.spaces.list(owner) if not p.get('is_scope_context') and p['status']=='active'}
            tags=self.store.rows('recording_tags',owner,session_id=sid)
            tagged={t.get('workspace_id') for t in tags if t.get('active') and t.get('workspace_id') in valid}
            if session.get('customer_assignment_required'):
                tagged = {session['customer_workspace_id']} if session.get('customer_confirmed_at') and session.get('customer_workspace_id') in valid else set()
            for link in self.store.rows('recording_links',owner,session_id=sid):
                if link.get('association_source')=='ai_tag' and link['project_id'] not in tagged:
                    self.store.update('recording_links',owner,link['id'],{'active':False,'version':link['version']+1})
            for pid in tagged:
                links=self.store.rows('recording_links',owner,session_id=sid,project_id=pid,active=True)
                if not links:
                    prior=next((m for m in self.store.rows('business_meetings',owner,project_id=pid) if m.get('request_id')=='recording:'+sid),None)
                    m=prior or self.meeting(owner,pid,{'title':session.get('title') or '录音沟通','goal':'','actual_at':session.get('started_at'),
                        'status':'recorded','created_from_recording':sid},'recording:'+sid)
                    link=self.link(owner,m['id'],sid)
                    self.store.update('recording_links',owner,link['id'],{'association_source':'ai_tag'})
            for link in self.store.rows('recording_links',owner,session_id=sid,active=True):
                if self.evidence(owner,link['meeting_id']):self.queue_analysis(owner,link['meeting_id'])

    def evidence(self,owner,mid):
        meeting=self.get_meeting(owner,mid);out=[]
        for link in self.store.rows('recording_links',owner,meeting_id=mid,active=True):
            session=self.store.get('sessions',owner,link['session_id'])
            if session.get('customer_assignment_required') and (not session.get('customer_confirmed_at') or session.get('customer_workspace_id')!=meeting['project_id']):continue
            for line in self.store.rows('transcript_segments',owner,session_id=session['id']):
                if session.get('consent')!='yes' and line.get('speaker')!='self':continue
                if line.get('transcript_revision',1)!=session.get('transcript_revision',1):continue
                out.append({'source_id':'transcript:'+line['id'],'source_version':version(line),'session_id':session['id'],
                    'start_ms':line['start_ms'],'end_ms':line['end_ms'],'text':line['text'],'speaker':line.get('speaker_id') or line.get('speaker'),
                    'personal_eligible':line.get('speaker')=='self'})
        return sorted(out,key=lambda e:(e['session_id'],e['start_ms'],e['source_id']))

    def current(self,owner,item):
        for ref in item.get('evidence_refs',[]):
            try:
                kind,rid=ref['source_id'].split(':',1)
                table={'transcript':'transcript_segments','message':'chat_messages','asset':'assets'}.get(kind)
                if not table:return False
                row=self.store.get(table,owner,rid)
                if version(row)!=ref['source_version']:return False
                if kind=='transcript' and row.get('transcript_revision',1)!=self.store.get('sessions',owner,row['session_id']).get('transcript_revision',1):return False
            except (Fault,KeyError,ValueError):return False
        return bool(item.get('evidence_refs'))

    def items(self,owner,pid=None,mid=None):
        if pid:self.project(owner,pid)
        if mid:self.get_meeting(owner,mid)
        return [{**r,'reference_status':'current' if self.current(owner,r) else 'superseded'} for r in self.store.rows('project_items',owner)
                if (not pid or r['project_id']==pid) and (not mid or r['meeting_id']==mid) and r.get('status')!='withdrawn']

    def detail(self,owner,pid):
        project=self.project(owner,pid)
        return {'project':self.spaces.view(owner,project),
                'meetings':sorted(self.store.rows('business_meetings',owner,project_id=pid),key=lambda m:(m.get('scheduled_at') or m.get('actual_at') or m['created_at'],m['id'])),
                'items':self.items(owner,pid), 'preparations':self.store.rows('preparation_packs',owner,project_id=pid),
                'followups':self.store.rows('followup_drafts',owner,project_id=pid),'tracking':self.tracking(owner,pid),
                'recordings':self.store.rows('recording_links',owner,project_id=pid,active=True)}

    def tracking(self,owner,pid):
        groups={}
        for item in self.items(owner,pid):
            if not item['reference_status']=='current' or item.get('is_practice') or item.get('is_example'):continue
            if item['kind'] not in {'question','answer'}:continue
            key=item.get('question_key') or (item['text'] if item['kind']=='question' else '')
            if not key:continue
            group=groups.setdefault(key,{'key':key,'questions':[],'answers':[]})
            group['questions' if item['kind']=='question' else 'answers'].append(item)
        return [{**g,'status':'answered' if g['answers'] else 'open','occurrences':len(g['questions']),
            'wording_variants':len({a['text'] for a in g['answers']})} for g in groups.values() if g['questions']]

    def scope_thread(self,owner,scope):
        with self.store.transaction(owner):
            self.store.check_owner(owner)
            mode=scope['mode']
            if mode=='project' and not scope.get('practice'):return self.store.get('chat_threads',owner,self.project(owner,scope['project_id'])['default_thread_id'])
            if mode=='project':self.project(owner,scope['project_id'])
            if mode=='meeting':self.get_meeting(owner,scope['meeting_id'])
            canonical={k:v for k,v in scope.items() if v is not None}
            request='scope:'+json.dumps(canonical,sort_keys=True)
            prior=next((s for s in self.spaces.list(owner) if s.get('client_request_id')==request),None)
            if not prior:
                names={'personal':'个人资料','all':'全部项目','scenario':'销售' if scope.get('scenario')=='sales' else '面试','meeting':'本场沟通','project':'面试练习'}
                space=self.spaces.create(owner,names[mode],'',request)
                prior=self.store.update('project_spaces',owner,space['id'],{'is_scope_context':True,'auto_seeded':True,'query_scope':canonical,'scope_label':names[mode],'is_practice':bool(scope.get('practice'))})
            return self.store.get('chat_threads',owner,prior['default_thread_id'])

    def scope_projects(self,owner,wid):
        space=self.spaces.get(owner,wid)
        if not space.get('is_scope_context'):return [space['id']]
        scope=space['query_scope'];mode=scope['mode']
        if mode=='personal':return []
        if mode=='project':return [scope['project_id']]
        if mode=='meeting':return [self.get_meeting(owner,scope['meeting_id'])['project_id']]
        return [s['id'] for s in self.spaces.list(owner) if not s.get('is_scope_context') and (mode!='scenario' or s.get('scenario')==scope.get('scenario'))]

    def queue_analysis(self,owner,mid):
        meeting=self.get_meeting(owner,mid);evidence=self.evidence(owner,mid)
        if not evidence:raise Fault('TRANSCRIPT_MISSING','请先关联已转写的录音',409)
        revision=hashlib.sha256(json.dumps(evidence,sort_keys=True,ensure_ascii=False).encode()).hexdigest()
        return self.business.submit(owner,'meeting_analysis',mid,revision)

    def analyze(self,owner,job):
        mid=job['object_id'];meeting=self.get_meeting(owner,mid);evidence=self.evidence(owner,mid)
        digest=hashlib.sha256(json.dumps(evidence,sort_keys=True,ensure_ascii=False).encode()).hexdigest()
        if digest!=job['revision']:raise Fault('TRANSCRIPT_CHANGED','资料已修订，请重新整理',409)
        groups=[];group=[];size=0
        for e in evidence:
            if size+len(e['text'])>18000 and group:groups.append(group);group=[];size=0
            group.append(e);size+=len(e['text'])
        if group:groups.append(group)
        for index,group in enumerate(groups):
            key=job['key']+':'+str(index)
            checkpoint=self.store.get('business_jobs',owner,job['id']).get('completed_parts',[])
            if key in checkpoint:continue
            result=self.business.structured('从真实沟通原文提取结构化记录，不能猜本人或姓名。输出 {"items":[{"kind":"consensus/question/answer/commitment/action/internal/gap/story/weakness","text":"内容","quote":"逐字原文","source_id":"提供的ID","owner":"原文明确负责人或空字符串","due_at":null,"date_quote":"原文日期或空","external_safe":false,"question_key":"相关问题的简短规范表述"}]}。内部审批、未答好和我方短板external_safe=false；只有本场与客户明确讨论可对外的事实才设true。截止时间必须原文明确并能结合实际场次日期确定，否则null；个人故事仅personal_eligible片段。',{'meeting':meeting,'evidence':group,'previous_questions':[g['key'] for g in self.tracking(owner,meeting['project_id'])]})
            byid={e['source_id']:e for e in group}
            with self.store.transaction(owner):
                self.business.guard(owner,job)
                if self.evidence(owner,mid)!=evidence:raise Fault('TRANSCRIPT_CHANGED','资料已修订，请重新整理',409)
                for item in result.get('items',[])[:60]:
                    if not isinstance(item,dict):continue
                    e=byid.get(item.get('source_id'));text=item.get('text');quote=item.get('quote');kind=item.get('kind')
                    if not e or kind not in KINDS or not isinstance(text,str) or not text.strip() or not isinstance(quote,str) or not quote.strip() or quote not in e['text']:continue
                    if kind=='story' and not e['personal_eligible']:continue
                    owner_name=item.get('owner','');owner_name=owner_name if isinstance(owner_name,str) and owner_name in quote else ''
                    if owner_name in {'我','本人'} and not e['personal_eligible']:owner_name=''
                    # Dates require the model's exact date evidence plus anchored meeting time.
                    due=item.get('due_at');date_quote=item.get('date_quote','')
                    try:
                        if not due or not date_quote or date_quote not in quote or not meeting.get('actual_at') or datetime.fromisoformat(due.replace('Z','+00:00')).tzinfo is None:due=None
                    except (ValueError,AttributeError):due=None
                    dedupe=hashlib.sha256((mid+job['revision']+kind+text+e['source_id']).encode()).hexdigest()
                    if any(i.get('dedupe')==dedupe for i in self.store.rows('project_items',owner)):continue
                    self.store.put('project_items',owner,{'project_id':meeting['project_id'],'meeting_id':mid,'kind':kind,'text':text[:2000],
                        'owner':owner_name,'due_at':due,'status':'open','version':1,'external_safe':item.get('external_safe') is True and kind not in {'internal','weakness','gap','story'} and not any(word in text+quote for word in ('内部审批','我方短板','没答好','未答好','内部底价','内部成本')),
                        'question_key':str(item.get('question_key',''))[:150],'dedupe':dedupe,'analysis_key':key,
                        'evidence_refs':[{k:e[k] for k in ('source_id','source_version','session_id','start_ms','end_ms')}|{'quote':quote}],
                        'producer':'anker/'+self.business.gateway.model,'rubric_version':'meeting@1','is_practice':meeting.get('is_practice',False),'is_example':meeting.get('is_example',False)},L2,source='ai')
                self.store.update('business_jobs',owner,job['id'],{'completed_parts':[*checkpoint,key]})
        with self.store.transaction(owner):
            self.business.guard(owner,job)
            self.store.update('business_meetings',owner,mid,{'status':'completed','analysis_revision':job['revision'],'version':self.get_meeting(owner,mid)['version']+1})
        return {'meeting_id':mid,'item_count':len(self.items(owner,mid=mid))}

    def patch_item(self,owner,iid,patch,expected):
        with self.store.transaction(owner):
            row=self.store.get('project_items',owner,iid)
            self.validate_dates(patch,('due_at',))
            if row['version']!=expected:raise Fault('VERSION_CONFLICT','行动已更新，请刷新',409)
            return self.store.update('project_items',owner,iid,{**patch,'version':expected+1,'user_updated_at':now(),'update_source':'user'})

    def queue_preparation(self,owner,mid):
        meeting=self.get_meeting(owner,mid)
        revision=hashlib.sha256(json.dumps({'meeting':meeting,'items':self.items(owner,meeting['project_id']),
            'materials':self.spaces.materials(owner,meeting['project_id'])},sort_keys=True,ensure_ascii=False).encode()).hexdigest()
        return self.business.submit(owner,'preparation',mid,revision)

    def prepare(self,owner,job):
        meeting=self.get_meeting(owner,job['object_id']);pid=meeting['project_id'];project=self.project(owner,pid)
        items=[i for i in self.items(owner,pid) if i['reference_status']=='current' and not i.get('is_practice') and not i.get('is_example')]
        materials=self.spaces.materials(owner,pid)
        items_snapshot=self.items(owner,pid)
        from adapters.sqlite_memory import SQLiteMemoryAdapter
        adapter=SQLiteMemoryAdapter(self.store);material_excerpts=[];material_refs={}
        for mat in materials:
            if not mat.get('linked') or len(material_excerpts)>=16:continue
            try:
                kind,resolved=adapter.resolve(owner,mat['source_id'],pid)
                item=source(kind,resolved,limit=1600)
                material_excerpts.append(item)
                material_refs[item['source_id']]={'source_id':item['source_id'],'source_version':item['source_version']}
            except Fault:continue
        data={'project':{k:project.get(k) for k in ('id','name','goal','scenario','participants')},
            'meeting':meeting,'items':items[:60],'materials':material_excerpts,
            'coverage':{'item_count':len(items),'included_items':min(60,len(items)),'material_count':len(materials),'included_materials':len(material_excerpts)}}
        # Fixed sections preserve all saved actions; model recommendations use bounded, cited excerpts.
        sections=[{'title':'本次目标','text':meeting.get('goal') or project.get('goal') or '说说本次最想推进什么','evidence_refs':[]}]
        resolved={g['key'] for g in self.tracking(owner,pid) if g['status']=='answered'}
        for title,kinds in [('尚待回答',{'question','gap'}),('承诺与下一步',{'commitment','action'}),('上次之后的进展',{'consensus','internal','answer'}),('口径与冲突',{'commitment','answer'})]:
            for item in items:
                if title=='尚待回答' and item.get('question_key') in resolved:continue
                if item['kind'] in kinds and (item.get('status')!='done' or title=='上次之后的进展'):
                    sections.append({'title':title,'text':item['text'],'evidence_refs':item['evidence_refs']})
        result=self.business.structured('生成会前准备包。返回 {"sections":[{"title":"栏目","text":"内容","source_ids":["已提供source_id"]}]}。销售包含关键问题与表达口径、分歧同时保留；面试包含已讲故事/下一轮选故事/数字缺口/待练问题。每项事实都引用资料ID，无资料的内容明确写为建议。严禁编造经历公司事实数字。',data)
        valid={e['source_id']:e for i in items for e in i['evidence_refs']}
        valid.update(material_refs)
        for section in result.get('sections',[])[:20]:
            if not isinstance(section,dict) or not isinstance(section.get('text'),str):continue
            refs=[valid[s] for s in section.get('source_ids',[]) if s in valid]
            if section.get('source_ids') and len(refs)!=len(section['source_ids']):continue
            sections.append({'title':str(section.get('title','准备建议'))[:80],'text':section['text'][:3000],
                'evidence_refs':refs,'suggestion':not bool(refs)})
        with self.store.transaction(owner):
            self.business.guard(owner,job)
            if self.get_meeting(owner,meeting['id'])!=meeting or self.project(owner,pid)!=project or self.items(owner,pid)!=items_snapshot or self.spaces.materials(owner,pid)!=materials:
                raise Fault('PREPARATION_CHANGED','准备目标或资料已变化，请重新生成',409)
            if any(not self.current(owner,i) for i in items):raise Fault('TRANSCRIPT_CHANGED','准备资料已修订',409)
            prior=self.store.rows('preparation_packs',owner,job_id=job['id'])
            row=prior[0] if prior else self.store.put('preparation_packs',owner,{'project_id':pid,'meeting_id':meeting['id'],'sections':sections,
                'job_id':job['id'],'producer':'anker/'+self.business.gateway.model,'rubric_version':'preparation@1','evidence_refs':[e for section in sections for e in section['evidence_refs']], 'input_coverage':data['coverage']},L2,source='ai')
        return {'preparation_id':row['id']}

    def draft(self,owner,mid,channel,internal=False):
        meeting=self.get_meeting(owner,mid)
        items=[i for i in self.items(owner,mid=mid) if i['reference_status']=='current' and (internal or i['external_safe'])]
        if not items:raise Fault('FOLLOWUP_EMPTY','暂无可用资料，请先整理本场录音',409)
        # External content is composed only from approved grounded extraction. No extra model can invent a commitment.
        content='\n'.join('• '+i['text'] for i in items)
        title=('内部纪要' if internal else '本次沟通跟进')+' · '+meeting['title']
        with self.store.transaction(owner):
            row=self.store.put('followup_drafts',owner,{'project_id':meeting['project_id'],'meeting_id':mid,'channel':channel,'internal':internal,
                'title':title,'text':content,'version':1,'send_status':'draft','recipient':'','evidence_refs':[e for i in items for e in i['evidence_refs']]},L1)

            self.save_draft_version(owner,row)
            return row

    def save_draft_version(self,owner,row):
        prior=self.store.rows('followup_versions',owner,draft_id=row['id'],draft_version=row['version'])
        if not prior:self.store.put('followup_versions',owner,{'draft_id':row['id'],'draft_version':row['version'],
            'title':row['title'],'text':row['text'],'recipient':row['recipient'],'channel':row['channel'],'internal':row['internal']},L1)

    def patch_draft(self,owner,did,patch,expected):
        with self.store.transaction(owner):
            row=self.store.get('followup_drafts',owner,did)
            if row['version']!=expected:raise Fault('VERSION_CONFLICT','稿件已更新，请刷新',409)
            self.save_draft_version(owner,row)
            updated=self.store.update('followup_drafts',owner,did,{**patch,'version':expected+1,'edited_at':now(),'send_status':'draft'})
            self.save_draft_version(owner,updated)
            return updated

    def sent(self,owner,did,result,manual=False,sent_version=None):
        with self.store.transaction(owner):
            row=self.store.get('followup_drafts',owner,did)
            if row['internal']:raise Fault('INTERNAL_DRAFT','内部纪要不能记为客户跟进',422)
            if result!='sent':return row
            if row['channel']!='email' and not manual:raise Fault('MANUAL_RECEIPT_REQUIRED','请确认实际已发出',422)
            sent_version=sent_version or row['version']
            if sent_version!=row['version'] and not self.store.rows('followup_versions',owner,draft_id=did,draft_version=sent_version):raise Fault('DRAFT_VERSION_MISSING','找不到发出版本，请核对稿件',409)
            self.save_draft_version(owner,row)
            return self.store.update('followup_drafts',owner,did,{'send_status':'sent' if sent_version==row['version'] else row['send_status'],'sent_at':now(),'sent_version':sent_version,
                'receipt_source':'user' if manual else 'mail_composer','delivery_status':'unknown'})

    def rewrite_followup(self,owner,job):
        row=self.store.get('followup_drafts',owner,job['object_id'])
        if row['version']!=job['payload']['draft_version'] or not self.current(owner,row):raise Fault('DRAFT_CHANGED','稿件或原文已更新，请重新改写',409)
        allowed=[i for i in self.items(owner,mid=row['meeting_id']) if i['reference_status']=='current' and (row['internal'] or i['external_safe'])]
        result=self.business.structured('按用户要求改写跟进稿，不增加事实、负责人、数字、报价或排期。只使用提供的稿件和可用资料。返回 {"paragraphs":[{"text":"段落","item_ids":["提供的资料ID"]}]}，无依据的段落仅可为问候结束语，不可新增承诺。对外稿不得推断内部情况。',{'draft':row['text'],'channel':row['channel'],'instruction':job['payload']['instruction'],'items':[{'id':i['id'],'text':i['text']} for i in allowed]})
        byid={i['id']:i for i in allowed};paragraphs=[];refs=[]
        import re
        known_numbers=set(re.findall(r'\d+(?:\.\d+)?',row['text']+' '.join(i['text'] for i in allowed)))
        for paragraph in result.get('paragraphs',[])[:40]:
            if not isinstance(paragraph,dict) or not isinstance(paragraph.get('text'),str):continue
            ids=paragraph.get('item_ids',[])
            if not isinstance(ids,list) or any(i not in byid for i in ids):raise Fault('REWRITE_UNGROUNDED','改写包含缺少依据的内容，请重新生成',502)
            if set(re.findall(r'\d+(?:\.\d+)?',paragraph['text']))-known_numbers:raise Fault('REWRITE_UNGROUNDED','改写增加了原稿没有的数字，请重新生成',502)
            paragraphs.append(paragraph['text']);refs.extend(e for i in ids for e in byid[i]['evidence_refs'])
        if not paragraphs:raise Fault('REWRITE_EMPTY','没有得到可用改写',502)
        with self.store.transaction(owner):
            self.business.guard(owner,job)
            if not self.current(owner,row):raise Fault('SOURCE_SUPERSEDED','稿件来源已修订',409)
            updated=self.patch_draft(owner,row['id'],{'text':'\n'.join(paragraphs),'evidence_refs':refs or row['evidence_refs']},row['version'])
        return {'draft_id':updated['id'],'version':updated['version']}

    def faq(self,owner,iid):
        row=self.store.get('project_items',owner,iid)
        if not self.current(owner,row):raise Fault('SOURCE_SUPERSEDED','原文已修订，请重新整理',409)
        with self.store.transaction(owner):
            prior=[a for a in self.store.rows('assets',owner) if a.get('project_item_id')==iid]
            if prior:return prior[0]
            asset=self.store.put('assets',owner,{'title':row['text'][:80],'body':{'text':row['text']},'kind':'qa_answer','status':'confirmed','version':1,
                'tags':[],'workspace_id':row['project_id'],'project_item_id':iid,'evidence_refs':row['evidence_refs']},L3,actor=owner)
            return asset

    def discovery_candidates(self,owner,pid,items,archive_job=None):
        with self.store.transaction(owner):
            saved=[]
            for item in items:
                key=hashlib.sha256((pid+item['text']+json.dumps(item['evidence_refs'],sort_keys=True)).encode()).hexdigest()
                prior=next((d for d in self.store.rows('discoveries',owner) if d.get('key')==key),None)
                if prior:saved.append(prior['id']);continue
                confirmed=next((d for d in self.store.rows('discoveries',owner) if d.get('status')=='confirmed' and d['text']==item['text']),None)
                legacy=next((d for d in self.store.rows('personal_memories',owner) if d.get('status')=='confirmed' and d['text']==item['text']),None)
                if confirmed or legacy:continue
                d=self.store.put('discoveries',owner,{**item,'key':key,'project_id':pid,'archive_job_id':archive_job,'status':'pending','general_personal':True,
                    'version':1,'producer':'anker/'+self.business.gateway.model,'rubric_version':'discovery@1'},L2,source='ai')
                saved.append(d['id'])
            return saved

    def discover(self,owner,job):
        pid=job['object_id'];self.project(owner,pid)
        evidence=[]
        for m in self.store.rows('business_meetings',owner,project_id=pid):
            if m.get('is_practice') or m.get('is_example'):continue
            evidence.extend(e for e in self.evidence(owner,m['id']) if e['personal_eligible'])
        if not evidence:return {'discovery_ids':[]}
        groups=[];group=[];size=0
        for e in evidence:
            if group and size+len(e['text'])>16000:groups.append(group);group=[];size=0
            group.append(e);size+=len(e['text'])
        if group:groups.append(group)
        ids=[]
        for group in groups:
            key=hashlib.sha256(json.dumps(group,sort_keys=True,ensure_ascii=False).encode()).hexdigest()
            prior=self.store.get('business_jobs',owner,job['id']).get('discovery_parts',{})
            if key in prior:ids.extend(prior[key]);continue
            result=self.business.structured('提取可复用的个人表达发现，必须有本人原文证据。输出 {"items":[{"title":"标题","text":"结论或建议","source_ids":[]}]}。不能将其他人的内容或练习当本人经历，不得虚构进步分数；仅一场的依据不能说成多场反复出现。',{'evidence':group})
            byid={e['source_id']:e for e in group};candidates=[]
            for item in result.get('items',[])[:12]:
                if not isinstance(item,dict):continue
                refs=[byid[s] for s in item.get('source_ids',[]) if s in byid]
                if not refs or len(refs)!=len(item.get('source_ids',[])) or not isinstance(item.get('text'),str):continue
                candidates.append({'title':str(item.get('title','个人发现'))[:120],'text':item['text'][:1200],
                    'evidence_refs':[{k:e[k] for k in ('source_id','source_version','session_id','start_ms','end_ms')} for e in refs]})
            with self.store.transaction(owner):
                self.business.guard(owner,job)
                if any(not self.current(owner,i) for i in candidates):raise Fault('TRANSCRIPT_CHANGED','发现来源已修订',409)
                saved=self.discovery_candidates(owner,pid,candidates);ids.extend(saved)
                self.store.update('business_jobs',owner,job['id'],{'discovery_parts':{**prior,key:saved},'progress':f'个人发现已整理 {len(prior)+1}/{len(groups)} 部分'})
        return {'discovery_ids':list(dict.fromkeys(ids)),'coverage':'all_personal_evidence_in_parts','parts':len(groups)}

    def confirm_discoveries(self,owner,entries):
        with self.store.transaction(owner):
            validated=[]
            for entry in entries:
                row=self.store.get('discoveries',owner,entry['id'])
                if row['version']!=entry['expected_version']:raise Fault('VERSION_CONFLICT','发现已更新，请刷新',409)
                if entry['status']=='confirmed' and not self.current(owner,row):raise Fault('SOURCE_SUPERSEDED','发现依据已修订，请先重新整理',409)
                validated.append((row,entry))
            return [self.store.update('discoveries',owner,row['id'],{'status':e['status'],'text':e.get('text') or row['text'],
                'version':row['version']+1,'source':'user' if e['status']=='confirmed' else row['source'],
                'trust':L3 if e['status']=='confirmed' else L2,'confirmed_by':owner if e['status']=='confirmed' else None,
                'confirmed_at':now() if e['status']=='confirmed' else None},actor=owner) for row,e in validated]

    def stats(self,owner):
        real=[m for m in self.store.rows('business_meetings',owner) if not m.get('is_practice') and not m.get('is_example') and m['status']=='completed']
        ids={m['id'] for m in real};items=[i for i in self.items(owner) if i['meeting_id'] in ids and i['reference_status']=='current']
        actions=[i for i in items if i['kind']=='action'];questions=[i for i in items if i['kind']=='question']
        answered={i.get('question_key') for i in items if i['kind']=='answer' and i.get('question_key')}
        metrics=[{'name':'行动有负责人','count':sum(bool(i['owner']) for i in actions),'total':len(actions),
                  'evidence_refs':[e for i in actions for e in i['evidence_refs']]},
                 {'name':'行动有日期','count':sum(bool(i['due_at']) for i in actions),'total':len(actions),
                  'evidence_refs':[e for i in actions for e in i['evidence_refs']]},
                 {'name':'问题已有回答','count':sum(bool(i.get('question_key') in answered) for i in questions),'total':len(questions),
                  'evidence_refs':[e for i in items if i['kind'] in {'question','answer'} for e in i['evidence_refs']]}]
        return {'sample_count':len(real),'metrics':metrics,
            'acoustic_metrics':None,'rubric_version':'text-coverage@1',
            'note':'图形仅表示已保存文本资料的覆盖比例，不是综合能力评分；语速、语气与声学打断暂无依据。'}
