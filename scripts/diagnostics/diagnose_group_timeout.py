import functools
import json
from pathlib import Path
import sys
import threading
import time
import traceback
import unittest

ROOT = Path(sys.argv[1]).resolve()
sys.path.insert(0, str(ROOT))
from test_phase1_support import CloudServerTestCase, FakeModelHandler
from test_phase7_groups import GroupServerTests

TRACE = Path(sys.argv[2]).resolve()
lock = threading.Lock()

def record(event, **data):
    row = dict(event=event, at=time.monotonic(), thread=threading.current_thread().name, **data)
    with lock, TRACE.open('a') as out:
        out.write(json.dumps(row, ensure_ascii=False, default=str) + '\n')

def gate_snapshot(srv):
    # Do not wait for the gate lock: a deadlock is one possible failure mode.
    if not srv.GATE.cond.acquire(timeout=0.2):
        return {'locked': True}
    try:
        return srv.GATE.status()
    finally:
        srv.GATE.cond.release()

original_setup = CloudServerTestCase.setUpClass.__func__
@classmethod
def setup(cls):
    srv = sys.modules.get('cloud_agent_server')
    if srv is not None:
        state = gate_snapshot(srv)
        if state.get('running') or state.get('queued') or state.get('locked'):
            record('fixture-before', fixture=cls.__name__, gate=state,
                   background=[t.name for t in threading.enumerate() if t is not threading.main_thread()])
    original_setup(cls)
CloudServerTestCase.setUpClass = setup

def snapshot(srv, reason):
    record('snapshot', reason=reason, gate=gate_snapshot(srv),
           frames={str(t.ident)+':'+t.name: traceback.format_stack(sys._current_frames()[t.ident])
                   for t in threading.enumerate() if t.ident in sys._current_frames()})
    try:
        conn = srv.get_db_connection()
        conn.execute('PRAGMA busy_timeout=1000')
        for table in ('group_messages', 'tasks', 'task_events'):
            cursor = conn.execute('SELECT * FROM '+table+' ORDER BY rowid DESC LIMIT 30')
            names = [d[0] for d in cursor.description]
            record('database', table=table, rows=[dict(zip(names,row)) for row in cursor.fetchall()])
        conn.close()
        record('model-requests', requests=[{'model':r.get('model'), 'stream':r.get('stream'),
               'last':str(r.get('messages', [{}])[-1].get('content'))[:300]}
               for r in FakeModelHandler.requests if r.get('model')=='m-group'])
    except Exception as e:
        record('snapshot-error', detail=repr(e))

original_test = GroupServerTests.test_group_api_and_flow
@functools.wraps(original_test)
def diagnosed(test):
    srv = test.srv
    originals = {}
    for name in ('_group_llm', '_group_start_task', 'run_agent_task', 'user_notify'):
        fn = getattr(srv, name)
        originals[name] = fn
        def wrapper(*args, _fn=fn, _name=name, **kwargs):
            record('enter', fn=_name)
            try:
                result = _fn(*args, **kwargs)
                record('exit', fn=_name, result=str(result)[:300] if _name=='_group_llm' else None)
                return result
            except BaseException as e:
                record('exception', fn=_name, error=repr(e))
                raise
        setattr(srv, name, wrapper)
    record('group-start', gate=gate_snapshot(srv), settings=srv.resource_settings())
    timer = threading.Timer(20, lambda: snapshot(srv, '20-second watchdog'))
    timer.daemon=True
    timer.start()
    try:
        return original_test(test)
    except BaseException:
        snapshot(srv, 'test failed')
        raise
    finally:
        timer.cancel()
        for name, fn in originals.items():
            setattr(srv, name, fn)
        record('group-end', gate=gate_snapshot(srv))
GroupServerTests.test_group_api_and_flow = diagnosed

TRACE.write_text('')
suite = unittest.defaultTestLoader.discover(str(ROOT), pattern='test*.py')
result = unittest.TextTestRunner(verbosity=2).run(suite)
raise SystemExit(not result.wasSuccessful())
