"""python run.py [--lan]. Only explicitly requested LAN mode binds all interfaces."""
import argparse
import os
from pathlib import Path
import uvicorn

ENV_KEYS = {
    'SOUNDCORE_APP_ID', 'SOUNDCORE_APP_KEY', 'SOUNDCORE_ENVIRONMENT',
    'DEEPSEEK_API_KEY', 'DEEPSEEK_MODEL',
    'ANKER_AI_API_KEY', 'ANKER_AI_BASE_URL', 'ANKER_AI_MODEL',
    'DASHSCOPE_API_KEY', 'DASHSCOPE_REGION', 'DASHSCOPE_ASR_REALTIME_MODEL', 'DASHSCOPE_ASR_FILE_MODEL',
    'MONID_API_KEY', 'MONID_BASE_URL', 'MONID_BUDGET_YUAN',
    'DASHSCOPE_TTS_MODEL', 'DASHSCOPE_TTS_VOICE', 'CANDID_RECORDING_MODE',
    'CANDID_SPEECH_ENABLED', 'CANDID_PUBLIC_BASE_URL',
    'CANDID_DEVICE_AUTH',
    'CANDID_MEMORY_BACKEND', 'CANDID_MEMORY_SERVICE_URL', 'CANDID_MEMORY_SERVICE_KEY',
}


def load_service_environment(paths):
    # Shell environment takes precedence. Local files are never echoed or sent to the App.
    for path in paths:
        for line in path.read_text('utf8').splitlines():
            if not line.strip() or line.lstrip().startswith('#') or '=' not in line:
                continue
            key, value = line.split('=', 1)
            key, value = key.strip(), value.strip()
            if len(value) >= 2 and value[0] == value[-1] and value[0] in {'"', "'"}:
                value = value[1:-1]
            if key in ENV_KEYS:
                os.environ.setdefault(key, value)

if __name__=='__main__':
    p=argparse.ArgumentParser();p.add_argument('--lan',action='store_true');p.add_argument('--port',type=int,default=8000)
    p.add_argument('--env-file',type=Path,action='append',default=[],help='本机服务配置文件，可重复指定；密钥不会发给 App')
    args=p.parse_args()
    team_file = Path(__file__).resolve().parents[1] / '.env.team.local'
    soundcore_file = team_file.with_name('.env.soundcore.local')
    load_service_environment([*args.env_file, *[p for p in (team_file, soundcore_file) if p.exists()]])
    import app
    if app.MODE=='local':print('本机访问令牌保存在：'+str(app.TOKEN_PATH.resolve()))
    # Live captions require a server-side WebSocket protocol. Fail at startup
    # if the dependency is missing instead of serving HTTP with broken upgrades.
    uvicorn.run(app.app,host='0.0.0.0' if args.lan else '127.0.0.1',port=args.port,access_log=False,ws='wsproto')
