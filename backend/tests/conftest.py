"""Keep API fixtures and their injected adapters on the same temporary database."""
import pytest
import tempfile


@pytest.fixture(scope='session', autouse=True)
def offline_application_environment():
    # Direct pytest invocation must never reuse the running demo's DB or keys.
    with tempfile.TemporaryDirectory(prefix='candid-pytest-') as folder:
        with pytest.MonkeyPatch.context() as env:
            for key in ('DEEPSEEK_API_KEY','ANKER_AI_API_KEY','DASHSCOPE_API_KEY',
                        'MONID_API_KEY','CANDID_MEMORY_SERVICE_KEY','SOUNDCORE_APP_KEY'):
                env.delenv(key,raising=False)
            env.setenv('CANDID_DATA_DIR',folder)
            env.setenv('CANDID_AUTH_MODE','local')
            env.setenv('CANDID_LOCAL_TOKEN','offline-test-token')
            env.setenv('CANDID_MEMORY_BACKEND','sqlite')
            env.setenv('CANDID_SPEECH_ENABLED','0')
            yield


@pytest.fixture
def bind_app_store(monkeypatch):
    resources=[]
    def bind(module, store):
        from adapters.sqlite_memory import SQLiteMemoryAdapter
        from agent import TextAgent
        from tasks.business import BusinessJobs
        from tasks.recordings import Recordings
        adapter=SQLiteMemoryAdapter(store)
        agent=TextAgent(store,memory_adapter=adapter)
        business=BusinessJobs(store,agent.gateway,agent.workspaces)
        recordings=Recordings(store,business,module.speech)
        for name,value in {'store':store,'memory_service':adapter,'agent':agent,
                           'business':business,'recordings':recordings,'LOCAL_TOKEN':'test-token'}.items():
            monkeypatch.setattr(module,name,value)
        resources.append((agent,business))
    yield bind
    for agent,business in resources:
        business.close();agent.close()
