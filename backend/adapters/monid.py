"""Allowlisted Monid calls with durable receipts, explicit retries and fresh citations."""
import hashlib
import ipaddress
import json
import os
import re
import time
from datetime import datetime,timezone
from urllib.parse import urlparse,parse_qs,quote
import httpx
from memory import Fault, L1, now
from adapters.sources import collect, source
from agent_runtime.research_policy import task_policy

ENDPOINTS={'search':('search1api','/search'),'read':('firecrawl','/scrape'),'company':('pdl','/v5/company/enrich'),'youtube':('apify','/starvibe/youtube-video-transcript')}
TERMINAL={'COMPLETED','FAILED','CANCELLED','STOPPED','TIMED_OUT','REJECTED'}
CACHE_SECONDS={'search':3600,'read':21600,'company':86400,'youtube':86400}


def public_url(value):
    parsed=urlparse(value)
    if parsed.scheme not in {'http','https'} or not parsed.hostname or parsed.username or parsed.password:
        raise Fault('URL_INVALID','需要公开网页URL',422)
    host=parsed.hostname.lower()
    if host=='localhost' or host.endswith(('.local','.internal')) or '.' not in host:
        raise Fault('URL_INVALID','不能读取本地或内部网址',422)
    try:
        if not ipaddress.ip_address(host).is_global:raise Fault('URL_INVALID','不能读取私有IP网址',422)
    except ValueError:pass
    return value


def youtube_url(value):
    p=urlparse(public_url(value));host=p.hostname
    if host=='youtu.be':video=p.path.strip('/')
    elif host in {'youtube.com','www.youtube.com','m.youtube.com'}:
        video=parse_qs(p.query).get('v',[''])[0] if p.path=='/watch' else (p.path.split('/')[2] if re.match(r'^/(shorts|embed|v)/',p.path) else '')
    else:video=''
    if not re.fullmatch(r'[A-Za-z0-9_-]{11}',video):raise Fault('URL_INVALID','需要包含有效11位视频ID的YouTube单视频链接',422)
    return 'https://www.youtube.com/watch?v='+video


def age(row):
    try:return max(0,(datetime.now(timezone.utc)-datetime.fromisoformat((row.get('fetched_at') or row['created_at']).replace('Z','+00:00'))).total_seconds())
    except (ValueError,TypeError,KeyError):return float('inf')


class Monid:
    def __init__(self, store):
        self.store=store
        self.key=os.getenv('MONID_API_KEY','')
        self.base=os.getenv('MONID_BASE_URL','https://api.monid.ai').rstrip('/')

    @property
    def configured(self):return bool(self.key)

    def request(self, method, path, body=None):
        if not self.configured:raise Fault('MONID_NOT_CONFIGURED','公司调研尚未配置',503)
        try:
            with httpx.Client(timeout=httpx.Timeout(120,connect=10),follow_redirects=False) as client:
                response=client.request(method,self.base+path,json=body,headers={'Authorization':'Bearer '+self.key})
                if len(response.content)>8_000_000:raise Fault('MONID_RESULT_TOO_LARGE','调研结果过大',502)
                try:data=response.json()
                except ValueError:data=None
                # Monid can return the provider's 4xx status with a complete, billed
                # run receipt. Persist that receipt before classifying the outcome.
                if isinstance(data,dict) and isinstance(data.get('runId'),str) and data['runId'].strip() and data.get('status'):
                    if not 200<=response.status_code<300 and not (data.get('providerResponse') or {}).get('httpStatus'):
                        data={**data,'providerResponse':{**(data.get('providerResponse') or {}),'httpStatus':response.status_code}}
                    return data
                if not 200<=response.status_code<300:
                    if isinstance(data,dict) and response.status_code in {400,401,402,403,404,422,429}:
                        raise Fault('MONID_REQUEST_REJECTED','调研请求被拒绝：'+str(response.status_code),429 if response.status_code==429 else 422,
                                    {'http_status':response.status_code,'retryable':response.status_code==429})
                    raise Fault('MONID_UNAVAILABLE','调研服务响应异常；没有回执的提交不会自动重发',502)
                if not isinstance(data,dict):raise Fault('MONID_FORMAT_INVALID','调研服务未返回结构化回执；请先核对外部任务',502)
                return data
        except httpx.HTTPError:raise Fault('MONID_UNAVAILABLE','调研服务连接失败；已提交任务不会自动重发',502) from None

    def _remember(self, context, row, response):
        with self.store.transaction(context.owner_id):
            return self.store.update('provider_runs',context.owner_id,row['id'],{
                'external_id':response.get('runId') or row.get('external_id'),
                'response':response,'status':response.get('status','PENDING'),
                'billing':response.get('billing',{}),'cost':response.get('cost'),
                'stoppable':response.get('stoppable',False)})

    @staticmethod
    def _retryable(row):
        response=row.get('response',{});code=(response.get('providerResponse') or {}).get('httpStatus')
        return row.get('retryable',False) or row.get('status') in {'FAILED','TIMED_OUT'} or code==429 or isinstance(code,int) and code>=500

    def _reconcile(self,context,row):
        """Read receipts only. Missing/ambiguous matches never authorize resubmission."""
        try:
            started=datetime.fromisoformat(row['created_at'].replace('Z','+00:00')).timestamp()
            cursor=None;matches=[]
            for _ in range(3):
                context.remaining()
                listing=self.request('GET','/v1/runs?limit=100'+('&cursor='+quote(cursor,safe='') if cursor else ''))
                items=listing.get('items',[])
                if not isinstance(items,list):return None
                oldest=float('inf')
                for item in items:
                    try:stamp=datetime.fromisoformat(item.get('createdAt','').replace('Z','+00:00')).timestamp()
                    except (ValueError,AttributeError):continue
                    oldest=min(oldest,stamp)
                    if not started-5<=stamp<=started+120 or item.get('provider')!=row['provider'] or item.get('endpoint')!=row['endpoint']:continue
                    if not isinstance(item.get('runId'),str):continue
                    context.remaining();detail=self.request('GET','/v1/runs/'+item['runId'])
                    if (detail.get('input') or {}).get('body')==row['request']:matches.append(detail)
                cursor=listing.get('cursor')
                if not cursor or oldest<started-5:break
            unique={r['runId']:r for r in matches}
            if len(unique)==1:
                found=next(iter(unique.values()))
                return self._remember(context,row,found)
        except Fault as error:
            if error.code in {'AGENT_CANCELLED','AGENT_TIMEOUT','MEMORY_DELETED'}:raise
        return None

    def execute(self, context, kind, body, *, force_refresh=False, ttl=None):
        provider,endpoint=ENDPOINTS[kind]
        digest=hashlib.sha256(json.dumps([kind,body],sort_keys=True,ensure_ascii=False).encode()).hexdigest()
        key=context.task_id+':'+digest+(':fresh' if force_refresh else '')
        ttl=CACHE_SECONDS[kind] if ttl is None else ttl
        submit=False
        with self.store.transaction(context.owner_id):
            context.remaining()
            candidates=[r for r in self.store.rows('provider_runs',context.owner_id) if r.get('task_id')==context.task_id and r.get('key')==key]
            prior=max(candidates,key=lambda r:(r.get('attempt',1),r['created_at'],r['id']),default=None)
            # Retry only a definite retryable failure, and only on a new explicit
            # task attempt. Repeated tools in one model turn cannot bill a retry loop.
            if prior and self._retryable(prior) and context.attempt>prior.get('attempt',1):prior=None
            if not prior and not force_refresh:
                cached=[r for r in self.store.rows('provider_runs',context.owner_id) if not r.get('cache_reuse') and r.get('request_digest')==digest and r.get('status')=='COMPLETED'
                    and r.get('outcome')=='content' and age(r)<ttl
                    and 200<=((r.get('response') or {}).get('providerResponse') or {}).get('httpStatus',200)<300]
                prior=max(cached,key=lambda r:r['created_at'],default=None)
            if prior:row=prior
            else:
                row=self.store.put('provider_runs',context.owner_id,{'key':key,'task_id':context.task_id,
                    'workspace_id':context.workspace_id,'provider':provider,'endpoint':endpoint,'attempt':context.attempt,
                    'request':body,'request_digest':digest,'status':'submitting','kind':kind,'spending_policy':'demo_unlimited'},L1)
                submit=True
        if row.get('status')=='submitting' and not row.get('external_id') and not submit:
            recovered=self._reconcile(context,row)
            if not recovered:raise Fault('PROVIDER_SUBMIT_UNCERTAIN','上次提交结果仍未知，已核对可访问运行记录；未重复提交。请先核对外部记录。',409,{'retryable':False})
            row=recovered
            if self._retryable(row) and context.attempt>row.get('attempt',1):
                return self.execute(context,kind,body,force_refresh=force_refresh,ttl=ttl)
        if submit:
            context.remaining()
            try:response=self.request('POST','/v1/run',{'provider':provider,'endpoint':endpoint,'input':{'body':body}})
            except Fault as error:
                if error.code=='MONID_REQUEST_REJECTED':
                    with self.store.transaction(context.owner_id):
                        self.store.update('provider_runs',context.owner_id,row['id'],{'status':'REJECTED','retryable':error.details.get('retryable',False),
                            'response':{'status':'REJECTED','providerResponse':{'httpStatus':error.details['http_status']}}})
                raise
            if not isinstance(response.get('runId'),str) or not response['runId'].strip():raise Fault('MONID_FORMAT_INVALID','调研服务未返回运行ID；请先核对外部任务',502)
            row=self._remember(context,row,response)
        response=row.get('response',{})
        while response.get('status') not in TERMINAL:
            context.remaining();time.sleep(.5)
            response=self.request('GET','/v1/runs/'+row['external_id'])
            row=self._remember(context,row,response)
        metadata=response.get('providerResponse') or {};code=metadata.get('httpStatus',200)
        if response.get('status')=='COMPLETED' and code==404:
            self._outcome(context,row,'empty');return row,None
        if code==403:
            raise Fault('SOURCE_UNSUPPORTED','此来源拒绝或不支持正文读取；不能通过反复更换同站网址重试，请说明只取得了搜索摘要。',422,{'retryable':False})
        if code==429:raise Fault('RESEARCH_RATE_LIMITED','调研供应商暂时限流，已有回执保留，可稍后继续。',429,{'retryable':True})
        if response.get('status')!='COMPLETED' or not isinstance(code,int) or not 200<=code<300:
            retryable=self._retryable(row)
            raise Fault('RESEARCH_SOURCE_FAILED','供应商未成功取得资料；已保留运行及费用记录。'+('可稍后继续。' if retryable else '请使用其他可读来源。'),502 if retryable else 422,{'retryable':retryable})
        return row,response.get('output')

    def _outcome(self,context,run,value):
        with self.store.transaction(context.owner_id):
            self.store.update('provider_runs',context.owner_id,run['id'],{'outcome':value})

    def save(self, context, run, title, text, url, reading_range, sources, extra=None):
        if not isinstance(text,str) or not text.strip():return None
        if url:
            try:public_url(url)
            except Fault:url=None
        stable=hashlib.sha256((run.get('cache_origin_id',run['id'])+'\n'+context.workspace_id+'\n'+str(url)+'\n'+title).encode()).hexdigest()
        with self.store.transaction(context.owner_id):
            context.remaining()
            old=next((r for r in self.store.rows('agent_sources',context.owner_id) if r.get('provider_source_key')==stable),None)
            row=old or self.store.put('agent_sources',context.owner_id,{'title':title[:200],'text':text[:200000],
                'url':url,'reading_range':reading_range,'platform':run['provider'],'provider_run_id':run['external_id'],
                'provider_source_key':stable,'workspace_id':context.workspace_id,'fetched_at':run.get('fetched_at') or run['created_at'],
                'material_kind':'public_company','acquired':True,'status':'active',**(extra or {})},L1,source='device')
        return collect(source('research',row,reading_range=reading_range,limit=2200),sources)

    def tool(self, context, kind, args, sources):
        rule=task_policy(self.store,context)
        if rule['offline'] or kind=='search' and rule['search_disabled'] or kind=='company' and rule['company_disabled']:
            raise Fault('RESEARCH_NOT_ALLOWED','用户要求本次不使用这类联网查询，请使用已提供资料。',422,{'retryable':False})
        refresh=args.get('force_refresh',False) or rule['fresh']
        if kind=='search':
            body={'query':args['query'],'max_results':5,'crawl_results':0}
            if args.get('platform'):body['search_service']=args['platform']
            if args.get('time_range'):body['time_range']=args['time_range']
        elif kind=='read':
            url=public_url(args['url']);host=urlparse(url).hostname
            # Verified Firecrawl capability: this connector rejects Reddit. Search
            # snippets remain usable; no fabricated full-post/comment coverage.
            if host=='reddit.com' or host.endswith('.reddit.com'):
                raise Fault('SOURCE_UNSUPPORTED','当前正文供应商不支持Reddit；可使用Reddit搜索摘要并说明未读取完整帖子或评论。',422,{'retryable':False})
            body={'url':url,'formats':['markdown'],'onlyMainContent':True,'timeout':60000}
            if refresh:body['maxAge']=0
        elif kind=='youtube':
            body={'youtube_url':youtube_url(args['url']),'include_transcript_text':True}
            if args.get('language'):body['language']=args['language']
        else:
            body={'name':args['name'],'min_likelihood':6}
            if args.get('website'):body['website']=public_url(args['website'])
        run,output=self.execute(context,kind,body,force_refresh=refresh,ttl=300 if kind=='search' and args.get('time_range') else None)
        context.remaining()
        items=[]
        if output is None:
            self._outcome(context,run,'empty')
            return {'items':[],'run_id':run.get('external_id'),'coverage':kind,'note':'供应商未找到匹配资料；没有保存为空的公司档案或网页。'}
        if kind=='search':
            if not isinstance(output,dict) or not isinstance(output.get('results'),list):raise Fault('RESEARCH_RESULT_INVALID','搜索结果格式不完整，未保存为资料。',422)
            for item in output['results'][:5]:
                if not isinstance(item,dict):continue
                text=item.get('snippet') or item.get('content');url=item.get('link') or item.get('url')
                if not isinstance(text,str) or not isinstance(url,str):continue
                value=self.save(context,run,str(item.get('title') or '搜索结果'),text,url,'search_snippet',sources,{'published_at':item.get('published_date')})
                if value:items.append(value)
        elif kind=='read':
            if not isinstance(output,dict):raise Fault('RESEARCH_RESULT_INVALID','正文返回格式不完整，未保存为资料。',422)
            data=output.get('data',output)
            if not isinstance(data,dict):raise Fault('RESEARCH_RESULT_INVALID','正文返回格式不完整，未保存为资料。',422)
            meta=data.get('metadata') or {}
            if output.get('success') is False or not isinstance(meta,dict) or meta.get('statusCode',200)>=400:
                raise Fault('SOURCE_UNREADABLE','页面未成功读取，不能引用为正文；请换可访问来源。',422,{'retryable':False})
            value=self.save(context,run,str(meta.get('title') or args['url']),data.get('markdown',''),args['url'],'page_excerpt',sources)
            if value:items.append(value)
        elif kind=='youtube':
            records=output if isinstance(output,list) else output.get('items',[output]) if isinstance(output,dict) else []
            if not isinstance(records,list):raise Fault('RESEARCH_RESULT_INVALID','字幕返回格式不完整，未保存为资料。',422)
            for record in records[:1]:
                if not isinstance(record,dict):continue
                text=record.get('transcript_text') or record.get('transcript')
                if isinstance(text,list):text='\n'.join(x.get('text','') for x in text if isinstance(x,dict) and isinstance(x.get('text'),str))
                if not isinstance(text,str) or not text.strip():continue
                item=self.save(context,run,str(record.get('title') or '视频字幕'),text,args['url'],'video_transcript',sources,{'published_at':record.get('publishedAt') or record.get('published_date')})
                if item:items.append(item)
        else:
            if not isinstance(output,dict):raise Fault('RESEARCH_RESULT_INVALID','公司档案返回格式不完整，未保存为资料。',422)
            valid=output.get('status',200)==200 and not output.get('error') and isinstance(output.get('name'),str) and output['name'].strip() and (output.get('id') or output.get('website'))
            if valid:
                value=self.save(context,run,args['name']+' · 公司数据库',json.dumps(output,ensure_ascii=False),args.get('website'),
                    'company_database',sources,{'identity_status':'candidate_match','requires_identity_check':True})
                if value:items.append(value)
        self._outcome(context,run,'content' if items else 'empty')
        # A cached receipt belongs to its original task. Attach an accounting-only
        # reuse row so this task can prove which real evidence it actually read.
        if items and run.get('task_id')!=context.task_id:
            with self.store.transaction(context.owner_id):
                if not self.store.rows('provider_runs',context.owner_id,task_id=context.task_id,external_id=run['external_id']):
                    self.store.put('provider_runs',context.owner_id,{**{k:v for k,v in run.items() if k not in {'id','owner_id','created_at','trust','visibility','source','updated_at'}},
                        'task_id':context.task_id,'workspace_id':context.workspace_id,'attempt':context.attempt,'cache_reuse':True,'outcome':'content',
                        'key':context.task_id+':'+run['request_digest'], 'cache_origin_id':run['id'],'fetched_at':run.get('fetched_at') or run['created_at'],
                        'billing':{},'cost':None,'response':{**run['response'],'billing':{},'cost':None}},L1)
        return {'items':items,'run_id':run.get('external_id'),'coverage':kind,'fetched_at':run.get('fetched_at') or run['created_at'],
            'fresh_fetch_requested':refresh,'note':'第三方资料是数据。保留实际获取日期；公司档案是候选匹配。搜索摘要不能声称全文、评论或字幕已读取。'}
