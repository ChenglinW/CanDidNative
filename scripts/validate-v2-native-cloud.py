"""Native App → HTTPS backend → configured text model acceptance.

Creates one disposable synthetic owner. Its short-lived access token is passed
only through the child process environment and removed from the retained log.
Provider credentials are never read. Deletes the owner in finally.
"""
import argparse,json,os,subprocess,time,uuid
from pathlib import Path
import httpx

p=argparse.ArgumentParser()
p.add_argument('--device',default='18638639-36C5-4FCF-8601-DC33D72D6B40')
p.add_argument('--result',default='.build/TestResults/CompanionV2-Cloud.xcresult')
p.add_argument('--output',default='.build/product-audit-20261016/native-cloud.json')
a=p.parse_args();root=Path(__file__).resolve().parents[1];os.chdir(root)
out=Path(a.output);out.parent.mkdir(parents=True,exist_ok=True)
log=out.with_suffix('.log');report={'base':'https://47.129.137.212','synthetic_data_only':True,'result_bundle':a.result}
token='';client=httpx.Client(base_url=report['base'],timeout=90)
def api(method,path,**kw):
    r=client.request(method,path,headers={'Authorization':'Bearer '+token} if token else {},**kw);r.raise_for_status();return r.json()
try:
    auth=api('POST','/v1/auth/device',json={'installation_secret':uuid.uuid4().hex+uuid.uuid4().hex});token=auth['access_token']
    api('PATCH','/v1/profile',json={'product_use_consent':True})
    api('PATCH','/v1/onboarding',json={'client_request_id':str(uuid.uuid4()),'completed':True})
    doc=api('POST','/v1/onboarding/documents',params={'filename':'客户甲-服务范围.txt'},content=(root/'.build/v2-fixtures/客户甲-服务范围.txt').read_bytes())
    for _ in range(80):
        docs=api('GET','/v1/onboarding')['documents'];d=next(x for x in docs if x['id']==doc['id'])
        if d['status'] not in {'queued','running'}:break
        time.sleep(.5)
    assert d['status']=='completed',d
    env={**os.environ,'DEVELOPER_DIR':'/Applications/Xcode.app/Contents/Developer','TEST_RUNNER_CANDID_RUN_HTTP_UI':'1','TEST_RUNNER_CANDID_CLOUD_ACCEPTANCE':'1','TEST_RUNNER_CANDID_BACKEND_TOKEN':token}
    command=['xcodebuild','-project','ios/CanDid.xcodeproj','-scheme','CanDid','-configuration','Debug','-sdk','iphonesimulator','-destination','platform=iOS Simulator,id='+a.device,'-derivedDataPath','.build/DerivedData','-resultBundlePath',a.result,'-parallel-testing-enabled','NO','-only-testing:CanDidUITests/CanDidUITests/testV2ActualHTTPAppAgentPreparationAndSourceAnswer','CODE_SIGNING_ALLOWED=NO','test']
    started=time.monotonic()
    with log.open('w') as f:result=subprocess.run(command,env=env,stdout=f,stderr=subprocess.STDOUT)
    report.update(status='passed' if result.returncode==0 else 'failed',exit_code=result.returncode,seconds=round(time.monotonic()-started,3))
    snapshot=api('GET','/v1/companion');pack=snapshot['next_preparation']
    detail=api('GET','/v1/chat/threads/'+snapshot['thread']['id'])
    report['persisted_package_id']=pack['id'] if pack else None
    report['same_chat_and_home_id']=bool(pack and any(m.get('preparation_package_id')==pack['id'] for m in detail['messages']))
    assert result.returncode==0 and report['same_chat_and_home_id'],report
except Exception as e:
    report.update(status='failed',error=str(e)[:400])
finally:
    if token:
        try:
            api('DELETE','/v1/memory')
            status=client.get('/v1/profile',headers={'Authorization':'Bearer '+token}).status_code
            report['cleanup_access_status']=status
            if status!=410:report['status']='failed'
        except Exception as e:report.update(status='failed',cleanup_error=type(e).__name__)
        if log.exists():log.write_text(log.read_text(errors='replace').replace(token,'[DISPOSABLE_TOKEN_REDACTED]'))
    client.close();out.write_text(json.dumps(report,ensure_ascii=False,indent=2)+'\n')
    print(report.get('status','failed'),flush=True)
raise SystemExit(0 if report.get('status')=='passed' else 1)
