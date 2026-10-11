"""Persistent local prototype. SQLite guards mirror PRD; Supabase DDL is separate.
No model or speech recognition is implied by the deterministic fixture provider.
"""
import base64
import hashlib
import json
import math
import sqlite3
import threading
from contextlib import contextmanager
from datetime import datetime, timedelta, timezone
from pathlib import Path
from uuid import uuid4

CONFIG = json.loads(Path(__file__).with_name('config.json').read_text('utf8'))
TABLES = ('profiles documents experiences assets asset_revisions question_bank baselines weaknesses '
          'occasions occasion_artifacts audiences script_versions outcomes sessions session_media marks '
          'transcript_segments qa_units metrics diagnoses diagnosis_feedback').split()
IMMUTABLE = {'documents', 'session_media', 'marks', 'transcript_segments'}
SCENARIOS = set(CONFIG['rubrics'])
L1, L2, L3 = 'L1_evidence', 'L2_inferred', 'L3_confirmed'

def now(): return datetime.now(timezone.utc).isoformat()
def ident(): return str(uuid4())
def encode(v): return json.dumps(v, ensure_ascii=False, separators=(',', ':'))
def tokens(v): return math.ceil(len(encode(v)) / 3)  # Explicit estimate, not provider tokenizer.

class Fault(Exception):
    def __init__(self, code, message, status=400, details=None):
        self.code, self.message, self.status, self.details = code, message, status, details or {}

class Memory:
    def __init__(self, path, storage):
        self.root = Path(storage); self.root.mkdir(parents=True, exist_ok=True)
        self.lock = threading.RLock(); self.actor = None
        self.db = sqlite3.connect(path, check_same_thread=False, isolation_level=None)
        self.db.row_factory = sqlite3.Row
        self.db.create_function('actor', 0, lambda: self.actor or '')
        self.db.execute('PRAGMA journal_mode=WAL')
        for table in TABLES:
            self.db.executescript(f'''
            CREATE TABLE IF NOT EXISTS {table}(
              id TEXT PRIMARY KEY, owner_id TEXT NOT NULL, created_at TEXT NOT NULL,
              data TEXT NOT NULL CHECK(json_valid(data)),
              CHECK(coalesce(json_extract(data,'$.visibility'),'')='private'),
              CHECK(coalesce(json_extract(data,'$.source'),'') IN ('user','device','ai')),
              CHECK(coalesce(json_extract(data,'$.trust'),'') IN ('{L1}','{L2}','{L3}')),
              CHECK(json_extract(data,'$.source') != 'ai' OR coalesce(length(json_extract(data,'$.producer')),0)>0),
              CHECK(json_extract(data,'$.trust') != '{L2}' OR
                (coalesce(length(json_extract(data,'$.producer')),0)>0 AND coalesce(length(json_extract(data,'$.rubric_version')),0)>0)),
              CHECK(json_extract(data,'$.trust') != '{L3}' OR
                (json_extract(data,'$.source')='user' AND coalesce(json_extract(data,'$.confirmed_by'),'')=owner_id
                 AND coalesce(length(json_extract(data,'$.confirmed_at')),0)>0)),
              CHECK(coalesce(json_extract(data,'$.status'),'')!='confirmed' OR json_extract(data,'$.trust')='{L3}')
            );
            CREATE INDEX IF NOT EXISTS {table}_owner ON {table}(owner_id,created_at,id);
            CREATE TRIGGER IF NOT EXISTS {table}_human_insert BEFORE INSERT ON {table}
              WHEN json_extract(NEW.data,'$.trust')='{L3}' AND actor()!=NEW.owner_id
              BEGIN SELECT RAISE(ABORT,'L3_NEEDS_HUMAN'); END;
            CREATE TRIGGER IF NOT EXISTS {table}_human_update BEFORE UPDATE ON {table}
              WHEN json_extract(NEW.data,'$.trust')='{L3}' AND actor()!=NEW.owner_id
              BEGIN SELECT RAISE(ABORT,'L3_NEEDS_HUMAN'); END;
            ''')
            if table in IMMUTABLE:
                self.db.executescript(f"CREATE TRIGGER IF NOT EXISTS {table}_immutable BEFORE UPDATE ON {table} BEGIN SELECT RAISE(ABORT,'L1_IMMUTABLE'); END;")
        self.db.executescript('''
        CREATE UNIQUE INDEX IF NOT EXISTS profile_one_owner ON profiles(owner_id);
        CREATE TRIGGER IF NOT EXISTS diagnosis_evidence BEFORE INSERT ON diagnoses
          WHEN coalesce(json_array_length(json_extract(NEW.data,'$.evidence_refs')),0) < 1
          BEGIN SELECT RAISE(ABORT,'EVIDENCE_MISSING'); END;
        CREATE TRIGGER IF NOT EXISTS diagnosis_evidence_update BEFORE UPDATE ON diagnoses
          WHEN coalesce(json_array_length(json_extract(NEW.data,'$.evidence_refs')),0) < 1
          BEGIN SELECT RAISE(ABORT,'EVIDENCE_MISSING'); END;
        CREATE TABLE IF NOT EXISTS requests(owner_id TEXT, request_id TEXT, kind TEXT, object_id TEXT,
          PRIMARY KEY(owner_id,request_id,kind));
        CREATE TABLE IF NOT EXISTS jobs(id TEXT PRIMARY KEY, owner_id TEXT, session_id TEXT,
          stage TEXT, attempts INTEGER DEFAULT 0, status TEXT DEFAULT 'queued', available_at TEXT);
        CREATE TABLE IF NOT EXISTS deletion_log(id TEXT PRIMARY KEY, object_id TEXT, object_type TEXT,
          deleted_at TEXT, reason TEXT);
        CREATE TABLE IF NOT EXISTS blocked_owners(owner_id TEXT PRIMARY KEY);
        ''')

    @contextmanager
    def transaction(self, actor=None):
        with self.lock:
            previous = self.actor; self.actor = actor
            self.db.execute('BEGIN IMMEDIATE')
            try:
                yield
                self.db.execute('COMMIT')
            except BaseException:
                self.db.execute('ROLLBACK'); raise
            finally: self.actor = previous

    def check_owner(self, owner):
        with self.lock:
            if self.db.execute('SELECT 1 FROM blocked_owners WHERE owner_id=?',(owner,)).fetchone():
                raise Fault('MEMORY_DELETED','记忆已删除，访问已停止',410)

    def get(self, table, owner, id):
        assert table in TABLES
        with self.lock:
            r = self.db.execute(f'SELECT data FROM {table} WHERE owner_id=? AND id=?',(owner,id)).fetchone()
            if not r: raise Fault('NOT_FOUND','记录不存在',404)
            return json.loads(r['data'])

    def rows(self, table, owner, **filters):
        assert table in TABLES
        with self.lock:
            rs=[json.loads(r['data']) for r in self.db.execute(f'SELECT data FROM {table} WHERE owner_id=? ORDER BY created_at DESC,id DESC',(owner,))]
            return [r for r in rs if all(r.get(k)==v for k,v in filters.items() if v is not None)]

    def put(self, table, owner, data, trust=L1, source='user', actor=None):
        assert table in TABLES
        data=dict(data)
        data.update(id=data.get('id',ident()),owner_id=owner,visibility='private',trust=trust,source=source,
                    created_at=data.get('created_at',now()),updated_at=now())
        data.setdefault('evidence_refs',[])
        if source=='ai' and not data.get('producer'): raise Fault('PRODUCER_REQUIRED','AI 数据必须记录生产者',422)
        if trust==L2 and (not data.get('producer') or not data.get('rubric_version')):
            raise Fault('RUBRIC_REQUIRED','推断必须记录评分标准与生产者',422)
        if table=='diagnoses':
            self.validate_evidence(owner,data.get('evidence_refs',[]))
            if any(r['session_id']!=data.get('session_id') for r in data['evidence_refs']):raise Fault('EVIDENCE_INVALID','诊断证据必须属于本场次',422)
        if trust==L3:
            if source!='user' or actor!=owner: raise Fault('L3_NEEDS_HUMAN','仅用户本人可以确认记忆',403)
            data.update(confirmed_by=owner,confirmed_at=now())
        with self.lock:
            prior=self.actor; self.actor=actor
            try:
                self.db.execute(f'INSERT INTO {table}(id,owner_id,created_at,data) VALUES(?,?,?,?)',
                                (data['id'],owner,data['created_at'],encode(data)))
            finally:self.actor=prior
        return data

    def update(self, table, owner, id, patch, actor=None):
        with self.lock:
            item=self.get(table,owner,id)
            item.update(patch); item['updated_at']=now()
            prior=self.actor;self.actor=actor
            try:self.db.execute(f'UPDATE {table} SET data=? WHERE owner_id=? AND id=?',(encode(item),owner,id))
            finally:self.actor=prior
            return item

    def remove(self, table, owner, id):
        assert table in TABLES
        self.db.execute(f'DELETE FROM {table} WHERE owner_id=? AND id=?',(owner,id))

    def validate_evidence(self, owner, refs):
        if not refs:raise Fault('EVIDENCE_MISSING','诊断必须引用用户原文证据',422)
        for ref in refs:
            session=self.get('sessions',owner,ref.get('session_id'))
            a,b=ref.get('start_ms',-1),ref.get('end_ms',-1)
            if not isinstance(a,int) or not isinstance(b,int) or not 0<=a<b:
                raise Fault('EVIDENCE_INVALID','证据时间范围无效',422)
            segments=self.rows('transcript_segments',owner,session_id=session['id'],speaker='self')
            if not any(x['start_ms']<=a and b<=x['end_ms'] for x in segments):
                raise Fault('EVIDENCE_INVALID','证据必须位于本用户已保存的原文范围内',422)

    def profile(self, owner):
        with self.lock:
            found=self.rows('profiles',owner)
            return found[0] if found else self.put('profiles',owner,{'preferences':{'audio_retention_days':90},'target_roles':[],'concerns':[]},L3,actor=owner)

    def create_session(self,owner,data):
        with self.transaction(owner):
            key=str(data['client_request_id'])
            r=self.db.execute("SELECT object_id FROM requests WHERE owner_id=? AND request_id=? AND kind='session'",(owner,key)).fetchone()
            if r:return self.get('sessions',owner,r[0])
            occasion=self.get('occasions',owner,str(data['occasion_id'])) if data.get('occasion_id') else None
            if data.get('audience_id'):
                audience=self.get('audiences',owner,str(data['audience_id']))
                if audience['occasion_id']!=data.get('occasion_id'):raise Fault('BAD_REQUEST','听众不属于该场合')
            days=data.get('retention_days')
            if days is None:days=self.profile(owner)['preferences']['audio_retention_days']
            if days not in CONFIG['retention_options']:raise Fault('BAD_REQUEST','保留期无效')
            if data['kind']=='practice':data['consent']='yes'
            if data['kind']=='live' and data['consent']=='yes' and not data.get('consent_ack_text_version'):
                raise Fault('BAD_REQUEST','请记录录音告知文案版本')
            scenario=occasion['scenario'] if occasion else data.get('scenario','interview')
            start=now()
            item=self.put('sessions',owner,{**data,'scenario':scenario,'started_at':start,'duration_ms':0,
                'retention_days':days,'purge_at':(datetime.fromisoformat(start)+timedelta(days=days)).isoformat(),
                'audio_purged_at':None,'consent_at':start if data['consent']=='yes' else None,
                'pipeline_status':'created','rubric_version':CONFIG['rubrics'][scenario],'fixture':False},source='device')
            self.db.execute('INSERT INTO requests VALUES(?,?,?,?)',(owner,key,'session',item['id']))
            return item

    def mutate_asset(self,owner,id,version,body=None,tags=None,status=None,table='assets'):
        with self.transaction(owner):
            item=self.get(table,owner,id)
            if item['version']!=version:raise Fault('VERSION_CONFLICT','版本已更新，请刷新后再试',409)
            self.put('asset_revisions',owner,{'asset_id':id,'version':version,'body':item['body'],'edited_by':owner},L3,actor=owner)
            patch={'version':version+1,'body':body if body is not None else item['body'],'tags':tags if tags is not None else item.get('tags',[])}
            target=status or item['status']
            patch['status']=target
            if target=='confirmed':patch.update(source='user',trust=L3,confirmed_by=owner,confirmed_at=now())
            return self.update(table,owner,id,patch,actor=owner)

    def transition(self,owner,id,event,session_id):
        w=self.get('weaknesses',owner,id)
        if w.get('last_event_session_id')==session_id:return w
        state=w['state']; patch={'last_event_session_id':session_id,'last_session_id':session_id}
        if event=='disagree':patch.update(state='disputed',user_disagrees=True,dispute_hits=0)
        elif event=='hit':
            hits=w.get('hit_count',0)+1;patch.update(hit_count=hits,consecutive_pass=0)
            if state=='disputed':
                count=w.get('dispute_hits',0)+1;patch['dispute_hits']=count
                if count>=CONFIG['weakness_hit_threshold']:patch.update(state='open',user_disagrees=False)
            elif hits>=CONFIG['weakness_hit_threshold']:patch['state']='open'
        elif event=='pass':
            count=w.get('consecutive_pass',0)+1;patch['consecutive_pass']=count
            if state!='disputed':patch['state']='resolved' if count>=CONFIG['weakness_pass_threshold'] else 'improving'
        return self.update('weaknesses',owner,id,patch)

    def context(self,owner,purpose,occasion_id=None,session_id=None,budget=None):
        if purpose not in CONFIG['context_budgets']:raise Fault('BAD_REQUEST','用途无效')
        occasion=self.get('occasions',owner,occasion_id) if occasion_id else None
        session=self.get('sessions',owner,session_id) if session_id else None
        if session and occasion and session.get('occasion_id')!=occasion_id:raise Fault('BAD_REQUEST','场合与场次不匹配')
        scenario=(occasion or session or {}).get('scenario','interview');rubric=CONFIG['rubrics'][scenario]
        def clean(table,items):
            out=[]
            for x in items:
                if x.get('speaker') and x['speaker']!='self':continue
                if x.get('status')=='archived' or x.get('user_disagrees'):continue
                if x['trust']==L2 and x.get('rubric_version')!=rubric:continue
                # Only explicit allowlisted content enters context. Counterpart identity never does.
                text={k:x[k] for k in ['title','body','bullets','text','fields','target_roles','concerns','timeline','finding','suggestion','question_essence','description','value','metric_key','dimension','role_key','label'] if k in x}
                out.append({'trust':'INFERRED' if x['trust']==L2 else 'FACT','ref':table+':'+x['id'],
                            'text':'<memory_data>'+encode(text)+'</memory_data>',
                            'rubric_version':x.get('rubric_version'),'producer':x.get('producer')})
            return out
        selected=[]
        def section(key,table,items):selected.append({'key':key,'items':clean(table,items)})
        experiences=self.rows('experiences',owner,status='confirmed')
        assets=[a for a in self.rows('assets',owner,status='confirmed') if a.get('scenario') in (None,scenario)]
        query=(occasion or {}).get('fields',{}).get('tags',[])
        assets.sort(key=lambda a:(len(set(a.get('tags',[]))&set(query))*2,a['created_at']),reverse=True)
        weak=self.rows('weaknesses',owner,scenario=scenario,state='open')
        questions=sorted(self.rows('question_bank',owner,scenario=scenario),key=lambda q:q.get('seen_count',0),reverse=True)
        if purpose=='prep':
            section('occasion','occasions',[occasion] if occasion else [])
            section('confirmed_experiences','experiences',experiences)
            section('assets','assets',assets);section('weaknesses','weaknesses',weak);section('questions','question_bank',questions)
        elif purpose=='rehearse':
            section('audience','audiences',self.rows('audiences',owner,occasion_id=occasion_id) if occasion_id else [])
            section('requirements','occasions',[occasion] if occasion else [])
            section('asked_questions','qa_units',self.rows('qa_units',owner,session_id=session_id) if session_id else [])
            section('weaknesses','weaknesses',weak)
        elif purpose=='diagnose':
            section('self_transcript','transcript_segments',self.rows('transcript_segments',owner,session_id=session_id,speaker='self') if session else [])
            section('metrics','metrics',self.rows('metrics',owner,session_id=session_id) if session else [])
            section('baselines','baselines',self.rows('baselines',owner));section('marks','marks',self.rows('marks',owner,session_id=session_id) if session else [])
            section('assets','assets',assets)
        elif purpose=='review':
            section('diagnoses','diagnoses',self.rows('diagnoses',owner,session_id=session_id) if session else [])
            section('metrics','metrics',self.rows('metrics',owner,session_id=session_id) if session else [])
            section('weaknesses','weaknesses',weak)
            section('draft_assets','assets',self.rows('assets',owner,source_session_id=session_id,status='draft') if session else [])
        else:
            section('profile','profiles',[self.profile(owner)])
            section('confirmed_experiences','experiences',experiences)
            section('recent_occasions','occasions',self.rows('occasions',owner)[:3])
        budget=budget if budget is not None else CONFIG['context_budgets'][purpose]
        truncated=[]
        for sec in reversed(selected):
            if sec['key']=='confirmed_experiences':continue
            while sum(tokens(z) for z in selected)>budget and sec['items']:
                sec['items'].pop();
                if sec['key'] not in truncated:truncated.append(sec['key'])
        count=sum(tokens(z) for z in selected)
        if count>budget:raise Fault('BUDGET_TOO_SMALL','预算不足以容纳用户确认经历',400)
        return {'purpose':purpose,'sections':selected,'token_count':count,'token_count_method':'chars_div_3_estimate',
                'truncated':truncated,'rubric_version':rubric}

    def log_delete(self,id,kind,reason):
        self.db.execute('INSERT INTO deletion_log VALUES(?,?,?,?,?)',(ident(),id,kind,now(),reason))

    def purge_audio(self,owner,id,reason='user'):
        with self.transaction(owner):
            s=self.get('sessions',owner,id)
            if s['audio_purged_at']:return s
            for m in self.rows('session_media',owner,session_id=id):
                path=self.root/m['storage_path']
                path.unlink(missing_ok=True);self.remove('session_media',owner,m['id'])
                self.log_delete(m['id'],'session_media',reason)
            # Pending or acknowledged-but-not-registered uploads also expire.
            for suffix in ['.part','.audio']:(self.root/owner/(id+suffix)).unlink(missing_ok=True)
            for seg in self.rows('transcript_segments',owner,session_id=id,speaker='other'):
                self.remove('transcript_segments',owner,seg['id'])
            s=self.update('sessions',owner,id,{'audio_purged_at':now()})
            self.log_delete(id,'audio',reason);return s

    def purge_expired(self,at=None):
        at=at or now();report={'purged':0,'failed':0}
        with self.lock:owners=[r[0] for r in self.db.execute('SELECT DISTINCT owner_id FROM sessions')]
        for owner in owners:
            for s in self.rows('sessions',owner):
                if not s['audio_purged_at'] and s['purge_at']<=at and s['pipeline_status']=='done':
                    try:self.purge_audio(owner,s['id'],'expired');report['purged']+=1
                    except OSError:report['failed']+=1
                elif not s['audio_purged_at'] and s['retention_days']!=0 and s['purge_at']<=at:
                    try:self.purge_audio(owner,s['id'],'expired');report['purged']+=1
                    except OSError:report['failed']+=1
        return report

    def change_retention(self,owner,days,session_id=None):
        if days not in CONFIG['retention_options']:raise Fault('BAD_REQUEST','保留期无效')
        with self.transaction(owner):
            if session_id:
                targets=[self.get('sessions',owner,session_id)]
                if targets[0]['audio_purged_at']:raise Fault('ALREADY_PURGED','音频已删除',409)
            else:
                p=self.profile(owner);old=p['preferences'].get('audio_retention_days',90)
                self.update('profiles',owner,p['id'],{'preferences':{**p['preferences'],'audio_retention_days':days}},actor=owner)
                targets=self.rows('sessions',owner) if days<old else []
            for s in targets:
                if s['audio_purged_at']:continue
                if not session_id and days>=s['retention_days']:continue
                self.update('sessions',owner,s['id'],{'retention_days':days,'purge_at':(datetime.fromisoformat(s['started_at'])+timedelta(days=days)).isoformat()})
        return {'updated':len(targets)}

    def delete_memory(self,owner):
        # Tombstone first so failed disk cleanup cannot permit further reads/jobs.
        with self.lock:self.db.execute('INSERT OR IGNORE INTO blocked_owners VALUES(?)',(owner,))
        files=list((self.root/owner).glob('*')) if (self.root/owner).exists() else []
        for f in files:
            if f.is_file():f.unlink(missing_ok=True)
        with self.transaction(owner):
            for table in TABLES:self.db.execute(f'DELETE FROM {table} WHERE owner_id=?',(owner,))
            self.db.execute('DELETE FROM requests WHERE owner_id=?',(owner,));self.db.execute('DELETE FROM jobs WHERE owner_id=?',(owner,))
            self.log_delete(owner,'memory','user')
        return {'deleted':True}

    def fixture(self,owner,occasion_id):
        """Explicit preprocessed demo: cannot be invoked for a real-media session."""
        s=self.create_session(owner,{'client_request_id':ident(),'occasion_id':occasion_id,'kind':'practice','consent':'yes'})
        with self.transaction(owner):
            s=self.update('sessions',owner,s['id'],{'fixture':True,'pipeline_status':'queued','duration_ms':60000})
            self.put('transcript_segments',owner,{'session_id':s['id'],'speaker':'self','start_ms':0,'end_ms':60000,
                'text':'示例：我负责门店对账方案，先了解客户现有流程，再确认接口和实施范围。结果部分还需要补充可核实的数据。',
                'asr_producer':'fixture@1','fixture':True},source='user')
            self.db.execute('INSERT INTO jobs(id,owner_id,session_id,stage,available_at) VALUES(?,?,?,?,?)',(ident(),owner,s['id'],'segmenting',now()))
        return s

    def run_stage(self,owner,sid,stage):
        s=self.get('sessions',owner,sid)
        self.check_owner(owner)
        if not s.get('fixture'):raise Fault('ASR_NOT_CONFIGURED','真实转写与模型尚未配置；音频已保存，未生成诊断',503)
        version=s['rubric_version'];trace={'producer':'fixture@1','rubric_version':version}
        segments=self.rows('transcript_segments',owner,session_id=sid,speaker='self')
        if not segments:raise Fault('EVIDENCE_MISSING','缺少用户原文',422)
        seg=segments[0];ref={'session_id':sid,'start_ms':seg['start_ms'],'end_ms':seg['end_ms']}
        if stage=='segmenting':
            self.put('qa_units',owner,{'session_id':sid,'mode':'answer','question_essence':'如何讲清已确认的贡献与结果？','a_start_ms':0,'a_end_ms':60000,**trace},L2,'ai')
            self.put('metrics',owner,{'session_id':sid,'metric_key':'self_characters_per_minute','value':len(seg['text']),**trace},L2,'ai')
        elif stage=='diagnosing':
            if not self.rows('qa_units',owner,session_id=sid):raise Fault('STAGE_MISSING','缺少问答切分',422)
            self.put('diagnoses',owner,{'session_id':sid,'dimension':'result_specificity','finding':'示例诊断：结果细节需要补充','suggestion':'只补充你可以核实的结果，不编造数字。','score':None,'evidence_refs':[ref],**trace},L2,'ai')
        elif stage=='aggregating':
            if not self.rows('diagnoses',owner,session_id=sid):raise Fault('STAGE_MISSING','缺少诊断',422)
            self.rebuild_aggregates(owner,s['scenario'],version)
            if not self.rows('assets',owner,source_session_id=sid):
                self.put('assets',owner,{'kind':'story','scenario':s['scenario'],'title':'示例：先确认范围，再讲价值',
                    'body':{'text':seg['text']},'tags':['需求确认'],'competencies':[],'status':'draft','version':1,'source_session_id':sid,
                    'evidence_refs':[ref],**trace},L2,'ai')
        self.update('sessions',owner,sid,{'pipeline_status':{'segmenting':'diagnosing','diagnosing':'aggregating','aggregating':'done'}[stage]})

    def rebuild_aggregates(self,owner,scenario,version):
        existing_weaknesses={w['dimension']:w for w in self.rows('weaknesses',owner,scenario=scenario) if w.get('rubric_version')==version}
        for table in ['question_bank','baselines','weaknesses']:
            prior=self.rows(table,owner,scenario= scenario) if table!='baselines' else self.rows(table,owner)
            for row in prior:
                if row.get('rubric_version')==version:self.remove(table,owner,row['id'])
        sessions=[s for s in self.rows('sessions',owner,scenario=scenario) if s['rubric_version']==version]
        trace={'producer':'fixture_aggregate@1','rubric_version':version}
        units=[u for u in self.rows('qa_units',owner) if u['rubric_version']==version and any(s['id']==u['session_id'] for s in sessions)]
        groups={}
        for u in units:groups.setdefault(u['question_essence'],set()).add(u['session_id'])
        for essence,sids in groups.items():self.put('question_bank',owner,{'scenario':scenario,'question_essence':essence,'seen_count':len(sids),**trace},L2,'ai')
        hits=[d for d in self.rows('diagnoses',owner) if d['rubric_version']==version and any(s['id']==d['session_id'] for s in sessions)]
        if hits:
            sids={d['session_id'] for d in hits}
            previous=existing_weaknesses.get('result_specificity',{})
            previous_hit_count=previous.get('hit_count',0)
            fresh_hits=max(0,len(sids)-previous_hit_count)
            dispute_hits=previous.get('dispute_hits',0)+fresh_hits
            disputed=previous.get('user_disagrees',False) and dispute_hits<CONFIG['weakness_hit_threshold']
            self.put('weaknesses',owner,{'scenario':scenario,'dimension':'result_specificity','description':'示例推断：结果需要更具体',
                'state':'disputed' if disputed else 'open' if len(sids)>=2 else 'observed','hit_count':len(sids),'consecutive_pass':0,
                'user_disagrees':disputed,'dispute_hits':dispute_hits,**trace},L2,'ai')
        metrics=[m for m in self.rows('metrics',owner) if m['rubric_version']==version and any(s['id']==m['session_id'] for s in sessions)]
        window=metrics[:CONFIG['baseline_window']]
        if len(window)>=CONFIG['baseline_min_sessions']:
            self.put('baselines',owner,{'scope':'delivery','scenario':None,'metric_key':'self_characters_per_minute',
                'value':sum(m['value'] for m in window)/len(window),'n_sessions':len(window),'window_size':CONFIG['baseline_window'],**trace},L2,'ai')

    def retry(self,owner,sid,stage):
        stages=['transcribing','segmenting','diagnosing','aggregating']
        if stage not in stages:raise Fault('BAD_REQUEST','阶段无效')
        with self.transaction(owner):
            s=self.get('sessions',owner,sid)
            if stage=='transcribing' and self.rows('transcript_segments',owner,session_id=sid):
                stage='segmenting'  # L1 is never rewritten.
            index=stages.index(stage)
            for table,threshold in [('qa_units',1),('metrics',1),('diagnoses',2),('assets',3)]:
                if index<=threshold:
                    for r in self.rows(table,owner):
                        if (r.get('session_id')==sid or r.get('source_session_id')==sid) and r['trust']==L2:self.remove(table,owner,r['id'])
            self.db.execute('DELETE FROM jobs WHERE owner_id=? AND session_id=?',(owner,sid))
            self.db.execute('INSERT INTO jobs(id,owner_id,session_id,stage,available_at) VALUES(?,?,?,?,?)',(ident(),owner,sid,stage,now()))
            return self.update('sessions',owner,sid,{'pipeline_status':'queued'})

    def tick(self):
        with self.lock:
            jobs=self.db.execute("SELECT * FROM jobs WHERE status='queued' AND available_at<=? ORDER BY available_at LIMIT 1",(now(),)).fetchall()
        for j in jobs:
            owner,sid=j['owner_id'],j['session_id']
            try:
                with self.transaction():
                    current=self.db.execute("SELECT stage,status FROM jobs WHERE id=?",(j['id'],)).fetchone()
                    if not current or current['status']!='queued' or current['stage']!=j['stage']:continue
                    self.db.execute("UPDATE jobs SET status='running' WHERE id=?",(j['id'],))
                    self.run_stage(owner,sid,j['stage'])
                    nextstage={'segmenting':'diagnosing','diagnosing':'aggregating'}.get(j['stage'])
                    if nextstage:self.db.execute("UPDATE jobs SET stage=?,status='queued',attempts=0 WHERE id=?",(nextstage,j['id']))
                    else:self.db.execute("DELETE FROM jobs WHERE id=?",(j['id'],))
            except Fault as e:
                with self.lock:
                    count=j['attempts']+1
                    self.db.execute("UPDATE jobs SET status=?,attempts=?,available_at=? WHERE id=?",('failed' if count>=3 else 'queued',count,(datetime.now(timezone.utc)+timedelta(seconds=2**count)).isoformat(),j['id']))
                    if self.rows('sessions',owner,id=sid):self.update('sessions',owner,sid,{'pipeline_status':'failed:'+j['stage'],'pipeline_error':e.code})
