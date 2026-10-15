"""Independent Agent contexts and explicit material scope; recordings stay in one library."""
import json
from memory import Fault, L1, ident, now
from adapters.sources import SOURCE_TABLES, text_of

MATERIAL_TABLES = {**SOURCE_TABLES, 'session':'sessions'}
PERSONAL_KINDS = {'asset','experience','document','personal','discovery'}


class WorkspaceStore:
    def __init__(self, store):
        self.store = store

    def get(self, owner, workspace_id):
        self.store.check_owner(owner)
        return self.store.get('project_spaces',owner,workspace_id)

    def list(self, owner):
        self.store.check_owner(owner)
        return sorted(self.store.rows('project_spaces',owner),key=lambda r:(r['created_at'],r['id']))

    def create(self, owner, name, goal, request_id, occasion_id=None, thread=None):
        with self.store.transaction(owner):
            self.store.check_owner(owner)
            prior = next((r for r in self.list(owner) if r.get('client_request_id')==request_id),None)
            if prior:
                if prior.get('creation_input',{'name':prior['name'],'goal':prior['goal']})!={'name':name,'goal':goal}:
                    raise Fault('REQUEST_CONFLICT','新建空间的重试内容不一致',409)
                return prior
            creation_input = {'name':name,'goal':goal}
            automatic_name = not name
            name = name or '新的沟通 '+str(len(self.list(owner))+1)
            wid = ident()
            if thread is None:
                thread = self.store.put('chat_threads',owner,{'title':name,'workspace_id':wid,
                    'occasion_id':occasion_id,'status':'idle','activity':[],'message_count':0},L1)
            elif thread.get('workspace_id'):
                return self.get(owner,thread['workspace_id'])
            else:
                self.store.update('chat_threads',owner,thread['id'],{'workspace_id':wid})
            return self.store.put('project_spaces',owner,{'id':wid,'name':name,'goal':goal,
                'default_thread_id':thread['id'],'client_request_id':request_id,'version':1,'context_version':1,
                'status':'active','archive_analysis_status':'not_requested','creation_input':creation_input,
                'name_source':'auto' if automatic_name else 'manual','goal_source':'manual' if goal else 'auto',
                'created_at':thread['created_at']},L1)

    def migrate_legacy(self):
        with self.store.transaction():
            owners = self.store.db.execute('SELECT DISTINCT owner_id FROM chat_threads').fetchall()
            for row in owners:
                owner = row['owner_id']
                for thread in sorted(self.store.rows('chat_threads',owner),key=lambda t:(t['created_at'],t['id'])):
                    if not thread.get('workspace_id'):
                        messages = sorted(self.store.rows('chat_messages',owner,thread_id=thread['id']),key=lambda m:(m['created_at'],m['id']))
                        goal = next((m['content'][:1200] for m in messages if m['role']=='user' and len(m['content'].strip())>=4),'')
                        self.create(owner,thread.get('title') or '历史对话',goal,'legacy:'+thread['id'],thread=thread)

    def update(self, owner, workspace_id, name, goal, expected_version):
        with self.store.transaction(owner):
            row = self.get(owner,workspace_id)
            if row.get('status')=='archived':
                raise Fault('WORKSPACE_ARCHIVED','请先恢复空间后再修改方向',409)
            if row['version']!=expected_version:
                raise Fault('VERSION_CONFLICT','空间已更新，请刷新后再修改',409)
            changed_goal = goal!=row['goal']
            if changed_goal and any(t['status'] in {'queued','running','waiting_input'}
                                    for t in self.store.rows('agent_tasks',owner,thread_id=row['default_thread_id'])):
                raise Fault('WORKSPACE_BUSY','请完成或停止此空间的任务后再修改沟通目标',409)
            updated = self.store.update('project_spaces',owner,workspace_id,{'name':name,'goal':goal,
                'version':row['version']+1,'context_version':row['context_version']+int(changed_goal),
                'name_source':'manual','goal_source':'manual'})
            self.store.update('chat_threads',owner,row['default_thread_id'],{'title':name})
            return updated

    def view(self, owner, row):
        thread = self.store.get('chat_threads',owner,row['default_thread_id'])
        messages = sorted(self.store.rows('chat_messages',owner,thread_id=thread['id']),
                          key=lambda m:(m['created_at'],m['id']))
        tasks = self.store.rows('agent_tasks',owner,thread_id=thread['id'])
        return {**row,'task_status':thread['status'],'message_count':len(messages),
                'last_message':messages[-1]['content'][:100] if messages else '',
                'queued_count':sum(t['status']=='queued' for t in tasks)}

    def seed_from_message(self, owner, workspace_id, text):
        with self.store.transaction(owner):
            row = self.get(owner,workspace_id)
            value = text.strip()
            if row.get('auto_seeded') or len(value)<4 or value in {'你好','你好呀','在吗','您好'}:
                return row
            patch = {'auto_seeded':True,'version':row['version']+1}
            if row.get('name_source')=='auto':
                patch['name'] = value.replace('\n',' ')[:24]
            if row.get('goal_source')=='auto':
                patch['goal'] = value[:1200]
                # First automatic seed applies to later snapshots, without changing in-flight prompts.
            updated = self.store.update('project_spaces',owner,workspace_id,patch)
            self.store.update('chat_threads',owner,row['default_thread_id'],{'title':updated['name']})
            return updated

    def archive(self, owner, workspace_id, expected_version, restore=False):
        with self.store.transaction(owner):
            row = self.get(owner,workspace_id)
            target = 'active' if restore else 'archived'
            if row.get('status','active')==target:
                return row
            if row['version']!=expected_version:
                raise Fault('VERSION_CONFLICT','空间已更新，请刷新后操作',409)
            if not restore and any(t['status'] in {'queued','running','waiting_input'}
                                   for t in self.store.rows('agent_tasks',owner,thread_id=row['default_thread_id'])):
                raise Fault('WORKSPACE_BUSY','请完成或停止空间中的任务后再归档',409)
            return self.store.update('project_spaces',owner,workspace_id,{'status':target,'version':row['version']+1,
                'archived_at':None if restore else now(),
                'archive_analysis_status':row.get('archive_analysis_status','not_requested') if restore else 'queued',
                'archive_confirmation_policy':'review_new_conclusions',
                'archived_by':row.get('archived_by') if restore else owner})

    def scope(self, owner, source_id):
        with self.store.lock:
            row = self.store.db.execute("SELECT data FROM agent_source_scopes WHERE owner_id=? AND json_extract(data,'$.source_id')=?",
                                        (owner,source_id)).fetchone()
            return json.loads(row['data']) if row else None

    def _chain(self, owner, kind, row):
        result = [(kind,row)]
        sid = row.get('session_id') or row.get('source_session_id')
        if sid and kind!='session':
            session = self.store.get('sessions',owner,sid)
            result.append(('session',session))
        oid = row.get('occasion_id') or (result[-1][1].get('occasion_id') if sid else None)
        if oid and kind!='occasion':
            result.append(('occasion',self.store.get('occasions',owner,oid)))
        return result

    def allowed(self, owner, kind, row, workspace_id):
        if workspace_id and self.get(owner,workspace_id).get('is_scope_context'):
            return self._scope_allowed(owner,kind,row,self.get(owner,workspace_id))
        if workspace_id is None:
            return True  # User-facing library APIs; Agent always supplies its server-bound space.
        sid = row.get('session_id') or row.get('source_session_id')
        if sid and kind in {'knowledge','transcript'}:
            session=self.store.get('sessions',owner,sid)
            if kind=='knowledge' and str(row.get('revision'))!=str(session.get('transcript_revision',1)):return False
            if kind=='transcript' and row.get('transcript_revision',1)!=session.get('transcript_revision',1):return False
        if kind=='message':
            thread=self.store.get('chat_threads',owner,row['thread_id'])
            explicit=self.scope(owner,'message:'+row['id'])
            return thread.get('workspace_id')==workspace_id or bool(explicit and explicit['mode']=='spaces' and workspace_id in explicit['workspace_ids'])
        if kind in {'personal','discovery'} and row.get('general_personal') and row.get('status')=='confirmed':
            return True
        if kind in {'personal','discovery'} and row.get('archive_workspace_id')==workspace_id:
            return row.get('status')=='confirmed'
        if kind in {'knowledge','session'} or row.get('session_id'):
            recording_id=row.get('session_id') or row['id']
            if self.store.rows('recording_links',owner,session_id=recording_id,project_id=workspace_id,active=True):return True
            sid = row.get('session_id') or row['id']
            tags = self.store.rows('recording_tags',owner,session_id=sid)
            if any(t.get('active') and t.get('workspace_id')==workspace_id for t in tags):
                return True
        for item_kind,item in self._chain(owner,kind,row):
            scope = self.scope(owner,item_kind+':'+item['id'])
            if scope is not None:
                if scope['mode']=='personal':
                    return item_kind in PERSONAL_KINDS
                return scope['mode']=='spaces' and workspace_id in scope['workspace_ids']
            if item.get('workspace_id'):
                return item['workspace_id']==workspace_id
        return False

    def _scope_allowed(self, owner, kind, row, context):
        scope=context['query_scope']; mode=scope['mode']
        if mode=='companion':
            if row.get('owner_id') != owner:return False
            if kind=='document':
                original=row.get('onboarding_original_id') or (row['id'] if row.get('material_kind')=='onboarding_original' else None)
                if original and self.store.db.execute("SELECT 1 FROM requests WHERE owner_id=? AND request_id=? AND kind='onboarding_document_removed'",(owner,original)).fetchone():return False
                return bool(row.get('text')) and row.get('status') not in {'withdrawn','superseded'}
            if kind in {'knowledge','transcript'}:
                session=self.store.get('sessions',owner,row['session_id'])
                if session.get('fixture') or session.get('consent')!='yes' or not session.get('llm_consent_at'):return False
                return str(row.get('revision') if kind=='knowledge' else row.get('transcript_revision',1))==str(session.get('transcript_revision',1))
            if kind=='message':return self.store.get('chat_threads',owner,row['thread_id']).get('workspace_id')==context['id']
            if kind in {'personal','discovery'}:return row.get('status')=='confirmed'
            return not row.get('fixture') and row.get('status') not in {'withdrawn','superseded'}
        if kind in PERSONAL_KINDS:
            explicit=self.scope(owner,kind+':'+row['id'])
            if explicit and explicit['mode']=='personal':return True
        if kind=='message':
            if self.store.get('chat_threads',owner,row['thread_id']).get('workspace_id')==context['id']:return True
            explicit=self.scope(owner,'message:'+row['id'])
            if not explicit or explicit['mode']!='spaces':return False
            if mode=='project':return scope['project_id'] in explicit['workspace_ids']
            if mode=='meeting':return self.store.get('business_meetings',owner,scope['meeting_id'])['project_id'] in explicit['workspace_ids']
            if mode in {'all','scenario'}:return any(s['id'] in explicit['workspace_ids'] for s in self.list(owner) if not s.get('is_scope_context') and (mode!='scenario' or s.get('scenario')==scope.get('scenario')))
            return False
        if kind in {'personal','discovery'} and row.get('general_personal') and row.get('status')=='confirmed':return True
        if row.get('workspace_id')==context['id'] and kind in {'research','document'}:return True
        if mode=='project':return self.allowed(owner,kind,row,scope['project_id'])
        if mode=='personal':
            explicit=self.scope(owner,kind+':'+row['id'])
            return bool(explicit and explicit['mode']=='personal' and kind in PERSONAL_KINDS)
        spaces=[s for s in self.list(owner) if not s.get('is_scope_context') and
                (mode!='scenario' or s.get('scenario')==scope.get('scenario'))]
        if mode=='meeting':
            meeting=self.store.get('business_meetings',owner,scope['meeting_id'])
            sid=row.get('session_id') or row.get('source_session_id') or (row['id'] if kind=='session' else None)
            links=self.store.rows('recording_links',owner,meeting_id=meeting['id'],active=True)
            if sid:return any(link['session_id']==sid for link in links) and self.allowed(owner,kind,row,meeting['project_id'])
            return self.allowed(owner,kind,row,meeting['project_id']) and kind not in {'knowledge','transcript'}
        return any(self.allowed(owner,kind,row,s['id']) for s in spaces)

    def scope_versions(self, owner, kind, row):
        result=[{'source_id':k+':'+r['id'],'revision':scope['revision'],'mode':scope['mode'],
                 'workspace_ids':scope['workspace_ids']}
                for k,r in self._chain(owner,kind,row)
                if (scope:=self.scope(owner,k+':'+r['id'])) is not None]
        sid=row.get('session_id') or row.get('source_session_id') or (row['id'] if kind=='session' else None)
        if sid:
            tags=sorted(self.store.rows('recording_tags',owner,session_id=sid),key=lambda t:t['id'])
            result.append({'source_id':'recording_tags:'+sid,'tags':[{'id':t['id'],'revision':t['revision'],'active':t['active'],
                'workspace_id':t.get('workspace_id')} for t in tags]})
        return result

    def set_scope(self, owner, source_id, mode, workspace_ids, expected_revision):
        with self.store.transaction(owner):
            self.store.check_owner(owner)
            kind,_,sid = source_id.partition(':')
            if kind not in MATERIAL_TABLES or not sid:
                raise Fault('SOURCE_UNAVAILABLE','资料类型无法关联',422)
            material = self.store.get(MATERIAL_TABLES[kind],owner,sid)
            if material.get('fixture') or str(material.get('producer','')).startswith('fixture'):
                raise Fault('SOURCE_UNAVAILABLE','示例资料不能关联真实空间',422)
            spaces = sorted(set(workspace_ids))
            if mode=='personal' and kind not in PERSONAL_KINDS:
                raise Fault('BAD_REQUEST','仅个人素材、经历和个人文档可标为通用个人资料',422)
            if (mode=='spaces')!=bool(spaces) or (mode!='spaces' and spaces):
                raise Fault('BAD_REQUEST','资料范围与空间列表不一致',422)
            for wid in spaces:
                self.get(owner,wid)
            prior = self.scope(owner,source_id)
            if (prior['revision'] if prior else 0)!=expected_revision:
                raise Fault('VERSION_CONFLICT','资料关联已变化，请刷新后再改',409)
            if prior and prior['mode']==mode and prior['workspace_ids']==spaces:
                return prior
            payload = {'source_id':source_id,'mode':mode,'workspace_ids':spaces,
                       'revision':expected_revision+1,'changed_by':owner}
            return self.store.update('agent_source_scopes',owner,prior['id'],payload) if prior else self.store.put('agent_source_scopes',owner,payload,L1)

    def materials(self, owner, workspace_id):
        self.get(owner,workspace_id)
        items = []
        for kind,table in MATERIAL_TABLES.items():
            for row in self.store.rows(table,owner):
                if row.get('fixture') or str(row.get('producer','')).startswith('fixture'):
                    continue
                if kind=='transcript' and row.get('speaker')!='self':
                    session=self.store.get('sessions',owner,row['session_id'])
                    if session.get('consent')!='yes' or not session.get('llm_consent_at'):continue
                parent_id = row.get('session_id') or row.get('source_session_id')
                if parent_id and self.store.get('sessions',owner,parent_id).get('fixture'):
                    continue
                sid = kind+':'+row['id']; scope = self.scope(owner,sid)
                items.append({'id':sid,'source_id':sid,'created_at':row['created_at'],
                    'kind':kind,'title':row.get('title') or row.get('finding') or ('录音 · '+row.get('started_at','')[:10] if kind=='session' else '资料片段'),
                    'text_preview':text_of(kind,row)[:160] if kind!='session' else row.get('pipeline_status',''),
                    'trust':row.get('trust','L1_evidence'),'can_share_personal':kind in PERSONAL_KINDS,
                    'linked':self.allowed(owner,kind,row,workspace_id),
                    'scope':scope or {'mode':'unassigned','workspace_ids':[],'revision':0}})
        return sorted(items,key=lambda x:(x['created_at'],x['id']),reverse=True)
