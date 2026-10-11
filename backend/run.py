"""python run.py [--lan]. Only explicitly requested LAN mode binds all interfaces."""
import argparse
import os
from pathlib import Path
import uvicorn
if __name__=='__main__':
    p=argparse.ArgumentParser();p.add_argument('--lan',action='store_true');p.add_argument('--port',type=int,default=8000);args=p.parse_args()
    import app
    if app.MODE=='local':print('本机访问令牌保存在：'+str(app.TOKEN_PATH.resolve()))
    uvicorn.run(app.app,host='0.0.0.0' if args.lan else '127.0.0.1',port=args.port,access_log=False)
