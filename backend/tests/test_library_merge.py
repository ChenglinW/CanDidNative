"""Approved memory merge: canonical writes, lossless migration and unified groups."""
from pathlib import Path
import sys
sys.path.insert(0,str(Path(__file__).resolve().parents[1]))
from memory import L1, L2, L3, ident
from memory_library import Edit
from test_memory_library import lib, asset, A, H, document, run


def test_all_legacy_types_and_archive_migrate_once(lib):
    l, _, _ = lib
    with l.store.transaction(A):
        story = l.store.put('assets', A, {'kind':'story','scenario':'interview','title':'项目经历',
            'body':{'text':'我负责验收'},'status':'confirmed','version':3}, L3, actor=A)
        experience = l.store.put('experiences', A, {'scenario':'interview','title':'工作经历',
            'body':{'text':'我的经历'},'status':'confirmed','version':1}, L3, actor=A)
        question = l.store.put('question_bank', A, {'scenario':'interview','question_essence':'为什么转岗？',
            'seen_count':4,'producer':'test','rubric_version':'test'}, L2, source='ai')
        archived = l.store.put('assets', A, {'kind':'story','scenario':'sales','title':'归档故事',
            'body':{'text':'旧故事'},'status':'archived','version':1,'producer':'test','rubric_version':'test'}, L2, source='ai')
    l.migrate(A); l.migrate(A)
    rows = l.store.rows('library_items', A)
    assert len(rows) == 4
    bylegacy = {r['legacy_id']:r for r in rows}
    assert bylegacy[story['id']]['text'] == '我负责验收'
    assert bylegacy[experience['id']]['legacy_table'] == 'experiences'
    assert bylegacy[question['id']]['item_type'] == 'faq'
    assert bylegacy[question['id']]['title'] == '为什么转岗？'
    assert bylegacy[archived['id']]['status'] == 'archived'
    assert len(l.store.rows('assets', A)) == 2  # Originals are untouched.


def test_divergent_legacy_edits_preserved_for_explicit_resolution(lib):
    l, _, _ = lib
    id = asset(l, user_edited=True)
    l.edit(A, id, Edit(expected_version=1, text='当前库改写'))
    l.store.update('assets', A, id, {'body':{'text':'旧版另一次改写'},'version':2})
    l.migrate(A); l.migrate(A)
    current = l.item(A, id)
    assert current['text'] == '当前库改写'
    assert current['migration_conflict']['legacy_text'] == '旧版另一次改写'
    assert sum(r['text']=='旧版另一次改写' for r in current['history']) == 1
    l.edit(A, id, Edit(expected_version=2, resolve_legacy=True,expected_legacy_revision=current["migration_conflict"]["legacy_revision"]))
    l.migrate(A)
    assert l.item(A, id)['migration_conflict'] is None


def test_old_http_and_new_http_share_one_version_counter(lib):
    l, client, _ = lib
    id = asset(l, scenario='sales')
    old = client.patch('/v1/companion/faq/'+id, headers=H,
                       json={'expected_version':1,'text':'旧界面改写','period':'活动期间','expires_on':'2026-12-31'})
    assert old.status_code == 200, old.text
    assert l.item(A,id)['text'] == '旧界面改写'
    assert old.json()['faq_period'] == '活动期间'
    new = client.patch('/v1/library/items/'+id, headers=H, json={'expected_version':2,'text':'统一库改写'})
    assert new.status_code == 200
    stale = client.patch('/v1/companion/faq/'+id, headers=H, json={'expected_version':2,'text':'覆盖'})
    assert stale.status_code == 409
    memory = client.get('/v1/companion/memory', headers=H).json()
    assert next(r for r in memory['expressions'] if r['id']==id)['body']['text']=='统一库改写'
    assert l.store.get('assets', A, id)['body']['text'] == '先确认需求'  # Historical original.


def test_scope_and_unknown_legacy_refs_are_preserved(lib):
    l, _, _ = lib
    space = l.spaces.create(A, '私有客户', '', ident())
    id = asset(l, scenario='interview', evidence_refs=[{'session_id':'missing-old-session','start_ms':0,'end_ms':5}])
    l.spaces.set_scope(A,'asset:'+id,'spaces',[space['id']],0)
    # An import already completed must not unexpectedly expand the canonical scope.
    l.store.remove('library_items', A, id)
    l.migrate(A)
    assert l.spaces.scope(A,'faq:'+id)['workspace_ids'] == [space['id']]
    row = l.item(A,id)
    assert row['evidence_state']=='changed'
    assert row['evidence_refs'][0]['source_id']=='legacy:unresolved'


def test_unified_grouping_keeps_scenarios_scopes_and_old_mapping(lib):
    l, _, _ = lib
    ids = [asset(l,title='报价是多少？',kind='qa_answer',scenario='sales') for _ in range(2)]
    interview = asset(l,title='报价是多少？',kind='qa_answer',scenario='interview')
    private = asset(l,title='报价是多少？',kind='qa_answer',scenario='sales')
    space = l.spaces.create(A,'客户乙','',ident())
    for id in ids+[interview]: l.spaces.set_scope(A,'faq:'+id,'personal',[],0)
    l.spaces.set_scope(A,'faq:'+private,'spaces',[space['id']],0)
    l.store.put('question_groupings',A,{'groups':[ids],'revision':'legacy','producer':'test','rubric_version':'test'},L2,source='ai')
    l.grouping.encoder_factory=lambda:type('Encoder',(),{'encode':lambda self,texts:[[1,0] for t in texts]})()
    pending=l.grouping.snapshot(A)
    l.business.run(A,l.store.get('business_jobs',A,pending['job_id']))
    ready=l.grouping.snapshot(A)
    assert ready['status']=='ready'
    assert sorted(len(g['item_ids']) for g in ready['groups'])==[1,1,2]
    combined=next(g for g in ready['groups'] if len(g['item_ids'])==2)
    assert combined['legacy_group_ids']==[min(ids)]
    assert l.store.rows('library_group_links',A)[0]['old_group_id']==min(ids)
    assert l.store.rows('question_groupings',A)[0]['revision']=='legacy'
    assert not l.grouping.snapshot('other-owner')['groups']


def test_legacy_deadline_includes_selected_day_and_validation(lib):
    l, client, _ = lib
    id=asset(l,scenario='interview',faq_period='面试阶段',faq_expires_on='2026-12-31')
    value=l.item(A,id)
    assert value['period']=='面试阶段'
    assert value['valid_until'].startswith('2027-01-01T00:00:00')
    invalid=client.patch('/v1/library/items/'+id,headers=H,json={'expected_version':1,'valid_until':'2026-99-01'})
    assert invalid.status_code==422
    assert l.item(A,id)['version']==1 and not l.item(A,id)['history']
    wrong=client.patch('/v1/library/items/'+id,headers=H,json={'expected_version':1,'topic':'车型与配置'})
    assert wrong.status_code==422


def test_archived_items_excluded_from_groups_and_cannot_leak_to_agent(lib):
    l, client, _ = lib
    id=asset(l,title='归档问题？',scenario='sales')
    l.edit(A,id,Edit(expected_version=1,status='archived'))
    assert l.grouping.snapshot(A)['groups']==[]
    l.edit(A,id,Edit(expected_version=2,status='active'))
    assert l.grouping.snapshot(A)['groups'][0]['item_ids']==[id]


def test_stale_questions_stay_visible_and_historical_counts_are_not_audio(lib):
    l, _, _ = lib
    id=asset(l,title='历史问题？',kind='qa_answer',scenario='interview',
             evidence_refs=[{'source_id':'transcript:missing','session_id':'missing'}])
    groups=l.grouping.snapshot(A)['groups']
    assert groups[0]['item_ids']==[id]  # Source repair remains reachable.
    assert l.item(A,id)['evidence_state']=='changed'
    l.store.put('question_bank',A,{'question_essence':'为什么换岗？','scenario':'interview',
        'seen_count':4,'producer':'test','rubric_version':'test'},L2,source='ai')
    l.migrate(A)
    group=next(g for g in l.grouping.snapshot(A)['groups'] if g['question']=='为什么换岗？')
    assert group['occurrences']==0 and group['recording_count']==0
    assert group['legacy_counts']==[4]


def test_document_sync_targets_canonical_edits_and_keeps_version_history(lib,monkeypatch):
    l, client, _ = lib
    old,parsed=document(l,'old.txt','交期两周');new,parsed2=document(l,'new.txt','交期三周')
    id=asset(l,scenario='sales')
    l.edit(A,id,Edit(expected_version=1,text='用户保留的说法'))
    from adapters.sources import version
    l.store.update('library_items',A,id,{'evidence_refs':[{'source_id':'document:'+parsed['id'],'source_version':version(parsed)}]})
    monkeypatch.setattr(l.business,'structured',lambda *a,**k:{'changes':['两周到三周'],'answers':[{'id':id,'text':'交期三周','quote':'交期三周','conflict':False}]})
    job=l.replace(A,old,new);l.business.run(A,job)
    assert l.item(A,id)['text']=='用户保留的说法'
    assert l.item(A,id)['suggested_text']=='交期三周'


def test_legacy_resolution_rejects_changes_since_user_opened_diff(lib):
    l, client, _ = lib
    id=asset(l,user_edited=True)
    l.edit(A,id,Edit(expected_version=1,text='当前修改'))
    l.store.update('assets',A,id,{'body':{'text':'旧版修改甲'},'version':2})
    l.migrate(A)
    revision=l.item(A,id)['migration_conflict']['legacy_revision']
    l.store.update('assets',A,id,{'body':{'text':'旧版修改乙'},'version':3})
    response=client.patch('/v1/library/items/'+id,headers=H,json={'expected_version':2,'text':'旧版修改甲','resolve_legacy':True,'expected_legacy_revision':revision})
    assert response.status_code==409
    assert l.item(A,id)['text']=='当前修改'
    assert l.item(A,id)['migration_conflict']['legacy_text']=='旧版修改乙'


def test_upstream_schema_upgrade_preserves_edits_deadline_scope_and_history(lib):
    l, client, _ = lib
    id=asset(l,quote='交付需要多久？',faq_period='旧活动',faq_history=[{'version':1,'text':'历史回答'}])
    l.store.remove('library_items',A,id)
    for row in l.store.rows('library_versions',A,item_id=id):l.store.remove('library_versions',A,row['id'])
    l.store.put('library_items',A,{'id':id,'legacy_id':id,'legacy_schema':2,'title':'交付怎么答？',
        'text':'线上手改回答','topic':'交付与服务','scenario':'sales','item_type':'faq','status':'active',
        'version':4,'user_edited':True,'expression_state':'reusable','evidence_refs':[],
        'legacy_period':'线上适用期间','valid_until':'2026-12-31T23:59:59+08:00',
        'producer':'library/migration','rubric_version':'library@2'},L2,source='ai')
    history=l.store.put('library_versions',A,{'item_id':id,'answer_version':1,'text':'历史回答','period':'','reason':'历史表达版本'},L1)
    l.migrate(A);l.migrate(A)
    current=l.item(A,id)
    assert current['version']==4 and current['text']=='线上手改回答'
    assert current['period']=='线上适用期间' and current['original_question']=='交付需要多久？'
    assert current['valid_until']=='2026-12-31T23:59:59+08:00'
    assert current['migration_conflict']['legacy_text']=='先确认需求'
    assert [r['id'] for r in current['history'] if r['text']=='历史回答']==[history['id']]
    response=client.patch('/v1/library/items/'+id,headers=H,json={'expected_version':4,'legacy_period':'新版期间'})
    assert response.status_code==200,response.text
    assert response.json()['period']==response.json()['legacy_period']=='新版期间'
    bad=client.patch('/v1/library/items/'+id,headers=H,json={'expected_version':5,'legacy_period':'甲','period':'乙'})
    assert bad.status_code==422 and l.item(A,id)['version']==5


def test_upstream_canonical_cache_is_mapped_without_claiming_legacy_provenance(lib):
    l, _, _ = lib
    id=asset(l,title='交付怎么说？',kind='qa_answer',quote='交付需要多久？')
    cache=l.store.put('question_groupings',A,{'groups':[[id]],'revision':'upstream-canonical',
        'producer':'test','rubric_version':'library-qwen3.7-average-top15-0.6646@2'},L2,source='ai')
    ready=l.grouping.snapshot(A)
    assert ready['groups'][0]['question']=='交付需要多久？'
    assert ready['groups'][0]['legacy_group_ids']==[]
    assert ready['groups'][0]['prior_canonical_group_ids']==[id]
    link=l.store.rows('library_group_links',A)[0]
    assert link['old_group_kind']=='canonical' and link['old_policy'].startswith('library-')
    assert l.store.get('question_groupings',A,cache['id'])['revision']=='upstream-canonical'


def test_canonical_grouping_yields_worker_capacity_to_interactive_work(lib,monkeypatch):
    l, _, _ = lib
    captured=[]
    monkeypatch.setattr(l.business.pools['background'],'submit',lambda fn,owner,job:captured.append(job['kind']))
    l.business.submit(A,'library_grouping',ident());l.business.submit(A,'recording_marks',ident())
    l.business.tick()
    assert len(captured)==1
    l.business.handlers['interactive_mock']=lambda owner,job:{}
    l.business.submit(A,'interactive_mock',ident());l.business.tick()
    assert captured[-1]=='interactive_mock' and len(captured)==2


def test_reextraction_matches_legacy_original_question_when_title_was_summarized(lib,monkeypatch):
    l, _, _ = lib
    from adapters.sources import version
    session=l.store.create_session(A,{'client_request_id':ident(),'kind':'live','scenario':'sales','consent':'yes','consent_ack_text_version':'v1'})
    line=l.store.put('transcript_segments',A,{'session_id':session['id'],'speaker':'other','text':'交付需要多久？','start_ms':0,'end_ms':5000,'transcript_revision':1},L1)
    id=asset(l,title='交付周期问题',quote=line['text'],tags=['客户常问'],source_session_id=session['id'],user_edited=True,evidence_refs=[{'source_id':'transcript:'+line['id'],'source_version':version(line)}])
    monkeypatch.setattr(l.business,'structured',lambda *a,**k:{'items':[{'question':line['text'],'answer':'新的 AI 建议','segment_ids':[line['id']],'topic':'交付与服务'}]})
    assert run(l,'library_extract',session['id'])['status']=='completed'
    assert [r['id'] for r in l.store.rows('library_items',A)]==[id]
    assert l.item(A,id)['text']=='先确认需求'


def test_companion_material_search_prefers_edited_canonical_and_never_resurfaces_archive(lib):
    from companion import Companion
    from tasks.materials import Materials
    l, _, _ = lib
    wid = Companion(l.store).thread(A)['workspace_id']
    id = asset(l)
    original = l.store.get('assets', A, id)
    l.edit(A, id, Edit(expected_version=1, text='需求新版：先说明实现，再统一评价标准'))
    # An original with no canonical counterpart must remain available.
    standalone = l.store.put('assets', A, {'title':'独立需求素材','body':{'text':'未导入需求资料'},
        'version':1,'status':'draft','evidence_refs':[], 'producer':'test','rubric_version':'test'}, L2, source='ai')
    materials = Materials(l.store, l.spaces)
    found = materials.search(A, wid, '需求', [])['items']
    assert 'asset:'+id not in {r['source_id'] for r in found}
    current = next(r for r in found if r['source_id']=='faq:'+id)
    assert current['text']=='需求新版：先说明实现，再统一评价标准'
    assert 'asset:'+standalone['id'] in {r['source_id'] for r in found}
    l.edit(A, id, Edit(expected_version=2, status='archived'))
    archived = materials.search(A, wid, '需求', [])['items']
    assert not {'asset:'+id, 'faq:'+id} & {r['source_id'] for r in archived}
    assert 'faq:'+standalone['id'] in {r['source_id'] for r in archived}
    assert 'asset:'+standalone['id'] not in {r['source_id'] for r in archived}
    assert l.store.get('assets', A, id)==original
