"""Trusted research requirements derived only from this task's real user input."""
import re
from urllib.parse import urlsplit,urlunsplit,parse_qs
from memory import Fault


def policy(text):
    offline=bool(re.search(r'(不要|不用|无需|不需要|禁止|先别|请勿|别)(再|先|进行)?(联网|上网)',text))
    urls=[u.rstrip('.,，。；;！!？?）)') for u in re.findall(r'https?://[^\s<>\"，。；！？（）]+',text)]
    read_urls=urls if re.search(r'读|阅读|核实|核对|查阅|查看|根据.{0,6}官网',text) else []
    required=not offline and bool(read_urls or re.search(r'联网|上网|最新.{0,16}(业务|动态|信息|公司)|最近.{0,16}(动态|新闻)',text))
    return {'offline':offline,'required':required,'urls':read_urls if not offline else [],
        'fresh':not offline and bool(re.search(r'最新|刷新|重新抓取|实时|最近.{0,12}(动态|新闻)|今天',text)),
        'search_disabled':bool(re.search(r'(不用|不要|无需|不需要)(额外|再)?搜索',text)),
        'company_disabled':bool(re.search(r'(不用|不要|无需|不需要)(额外|再)?公司数据库',text))}


def task_policy(store, context):
    rows=store.rows('agent_tasks',context.owner_id,id=context.task_id)
    if not rows:return policy('')
    task=rows[0]
    # New answers can provide details, but do not silently revoke an earlier explicit
    # network requirement/offline restriction. A new user task can change that scope.
    return policy(task.get('input',{}).get('content',''))


def canonical_url(value):
    p=urlsplit(value)
    if p.hostname=='youtu.be':return 'youtube:'+p.path.strip('/')
    if p.hostname in {'youtube.com','www.youtube.com','m.youtube.com'}:
        video=parse_qs(p.query).get('v',[''])[0] if p.path=='/watch' else p.path.rsplit('/',1)[-1]
        return 'youtube:'+video
    return urlunsplit((p.scheme.lower(),p.netloc.lower(),p.path.rstrip('/'),p.query,''))


def require_preparation_research(store,context,references):
    rule=task_policy(store,context)
    if not rule['required']:return
    ids={r['source_id'] for r in references}
    rows=store.rows('provider_runs',context.owner_id,task_id=context.task_id)
    usable=[]
    for r in rows:
        if r.get('outcome')!='content':continue
        evidence=store.rows('agent_sources',context.owner_id,provider_run_id=r.get('external_id'))
        if any('research:'+s['id'] in ids and s.get('workspace_id')==context.workspace_id for s in evidence):usable.append(r)
    missing=[url for url in rule['urls'] if not any(r.get('kind') in {'read','youtube'} and canonical_url(r.get('request',{}).get('url') or r.get('request',{}).get('youtube_url',''))==canonical_url(url) for r in usable)]
    if not usable or missing:
        raise Fault('RESEARCH_REQUIRED','尚未完成用户要求的联网核实。先读取指定公开网址或搜索并读取相关来源，将实际 research 来源加入 source_ids 后再保存；不可用时如实说明缺口，不能把本地模板当作已完成调研。',422)
