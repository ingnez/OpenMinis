"""Controlled real-HTTP regression for the fixture shutdown race; fake inputs only."""
import http.client
import json
import os
import socket
import sys
import threading
import time
import unittest
from pathlib import Path

sys.path.insert(0, os.environ.get('GROUP_REPRO_SOURCE', '/workspace/OpenMinis/cloud-agent'))
from test_phase1_support import CloudServerTestCase, FakeModelHandler
from test_phase7_groups import GroupServerTests

mode = sys.argv[1]
assert mode in ('current', 'drain-before-model-shutdown')
if mode == 'drain-before-model-shutdown':
    @classmethod
    def teardown(cls):
        cls.api_server.shutdown()
        cls._drain_background()
        for server in (cls.model_server, cls.notify_server):
            server.shutdown()
        for server in (cls.api_server, cls.model_server, cls.notify_server):
            server.server_close()
        if hasattr(cls.srv, 'stop_scheduler'):
            cls.srv.stop_scheduler()
        import os
        for k in list(cls.extra_env.keys())+['OPENMINIS_MASTER_KEY_FILE']:
            os.environ.pop(k,None)
        cls.tmp.cleanup()
    CloudServerTestCase.tearDownClass = teardown

class PreviousFixture(CloudServerTestCase):
    pass

PreviousFixture.setUpClass()
test = PreviousFixture()
srv = test.srv
old_port = PreviousFixture.model_server.server_port
model_stopped = threading.Event()
entered = set()
delayed_sessions = set()
connections = []
original_inner = srv._run_agent_task_inner
original_response = http.client.HTTPConnection.getresponse
original_shutdown = PreviousFixture.model_server.shutdown

def delayed_inner(tid, sid, *args, **kwargs):
    if sid in delayed_sessions:
        entered.add(tid)
        while not model_stopped.wait(0.01):
            if srv.is_task_cancelled(tid):
                return
    return original_inner(tid, sid, *args, **kwargs)

def response(conn, *args, **kwargs):
    if conn.port == old_port:
        connections.append(conn)
    return original_response(conn, *args, **kwargs)

def stop_model():
    original_shutdown()
    model_stopped.set()
    if mode == 'current':
        # All prepared tasks now cross the same gap: the model stopped,
        # but fixture teardown has not cancelled background tasks yet.
        deadline=time.monotonic()+3
        while len(connections)<3 and time.monotonic()<deadline and srv.GATE.status()["running"]:
            time.sleep(0.01)

srv._run_agent_task_inner = delayed_inner
http.client.HTTPConnection.getresponse = response
PreviousFixture.model_server.shutdown = stop_model
FakeModelHandler.scripts['m-old-fixture'] = lambda d: {'role':'assistant','content':'old-done'}
for index in range(3):
    sid = test.new_session('old-fixture-'+str(index))
    delayed_sessions.add(sid)
    status, task = test.submit(sid, 'fake old task', 'm-old-fixture')
    assert status == 202, (status, task)
deadline=time.monotonic()+5
while len(entered)<3 and time.monotonic()<deadline:
    time.sleep(0.01)
assert len(entered)==3, entered
started=time.monotonic()
PreviousFixture.tearDownClass()
print(json.dumps({'mode':mode,'teardown_seconds':round(time.monotonic()-started,3),
                  'gate_after_previous_fixture':srv.GATE.status(),
                  'inflight_calls_to_stopped_model':len(connections)}),flush=True)

suite=unittest.TestSuite([GroupServerTests('test_group_api_and_flow')])
# Leave cleanup until the stalled calls have been released; normal unittest
# would otherwise delete the new fixture while its group task is still queued.
original_next_teardown=GroupServerTests.tearDownClass
GroupServerTests.tearDownClass=classmethod(lambda cls: None)
result=unittest.TextTestRunner(verbosity=2).run(suite)
print(json.dumps({'mode':mode,'group_test_passed':result.wasSuccessful(),
                  'gate_after_group':srv.GATE.status()}),flush=True)
for conn in connections:
    try:
        if conn.sock:
            conn.sock.shutdown(socket.SHUT_RDWR)
            conn.sock.close()
    except OSError:
        pass
srv._run_agent_task_inner=original_inner
http.client.HTTPConnection.getresponse=original_response
time.sleep(0.5)
original_next_teardown()
if mode=='current' and os.environ.get('EXPECT_GROUP_PASS')!='1':
    assert not result.wasSuccessful(), 'The original cleanup order did not reproduce the race'
else:
    assert result.wasSuccessful(), 'Draining before stopping the model did not prevent the race'
