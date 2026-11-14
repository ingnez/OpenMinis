#!/usr/bin/env python3
"""Exercise real queued cancellation before UI fixtures reuse server history."""
import json
import time
import urllib.request


def api(path, body=None, method=None):
    request = urllib.request.Request('http://127.0.0.1:18765' + path,
        data=None if body is None else json.dumps(body).encode(),
        method=method,
        headers={'Authorization': 'Bearer e2e-fake-token-0000000000000000',
                 'Content-Type': 'application/json'})
    return json.load(urllib.request.urlopen(request, timeout=10))


def probe(path):
    return json.load(urllib.request.urlopen('http://127.0.0.1:18799' + path, timeout=10))


def main():
    settings = api('/v1/resources')['settings']
    original = settings.get('bot_overrides', {}).get('e2ebot', {})
    api('/v1/resources', {'bot_overrides': {'e2ebot': dict(original, max_tasks_per_bot=1)}}, method='PUT')
    sessions, tasks = [], []
    try:
        for _ in range(2):
            sid = api('/v1/sessions', {'title': 'synthetic reset regression', 'persona_id': 'e2ebot'})['session_id']
            sessions.append(sid)
            tasks.append(api('/v1/sessions/' + sid + '/messages',
                {'content': '慢任务', 'model': 'e2e-vision-model', 'provider': {}})['task_id'])
        queued = False
        deadline = time.monotonic() + 3
        while time.monotonic() < deadline:
            queued = any(any(e['type'] == 'queued' for e in api('/v1/tasks/' + tid)['events']) for tid in tasks)
            if queued:
                break
            time.sleep(.05)
        assert queued, 'The real gate did not queue the second fixture task'
        probe('/_e2e/reset')
        time.sleep(.6)
        for sid in sessions:
            assert api('/v1/sessions/' + sid)['messages'] == [], 'Late task output entered cleared fixture history'
        print('PASS: real queued and running tasks cancel; reset history stays empty.')
    finally:
        for tid in tasks:
            api('/v1/tasks/' + tid + '/cancel', {})
        api('/v1/resources', {'bot_overrides': {'e2ebot': original}}, method='PUT')

    probe('/_e2e/reply?mode=instant')
    try:
        sid = api('/v1/sessions', {'title': 'synthetic restart regression', 'persona_id': 'e2ebot'})['session_id']
        api('/v1/sessions/' + sid + '/messages', {'content': '慢活 查一下资料', 'model': 'e2e-vision-model', 'provider': {}})
        deadline = time.monotonic() + 5
        worker = None
        while time.monotonic() < deadline:
            workers = api('/v1/workers?session_id=' + sid)['workers']
            if workers and workers[0].get('task_id'):
                worker = workers[0]
                if any(e['type'] == 'tool_call' for e in api('/v1/tasks/' + worker['task_id'])['events']):
                    break
            time.sleep(.05)
        assert worker and worker.get('task_id'), 'The real background execution did not start'
        probe('/_e2e/restart')
        assert any(m.get('choice') and '要继续吗' in m.get('content', '') for m in api('/v1/sessions/' + sid)['messages'])
        api('/v1/workers/' + worker['worker_id'] + '/resume', {})
        probe('/_e2e/reset')
        time.sleep(.6)
        assert api('/v1/sessions/' + sid)['messages'] == [], 'Pre-restart execution outlived the reset'
        print('PASS: restart preserves its question, terminates old execution, and resumes safely.')
    finally:
        probe('/_e2e/reply?mode=verbose')

    # The phone can remember an older conversation while another fixture has
    # created a newer one. Both history probes must target the phone's actual ID.
    probe('/_e2e/reset')
    older = api('/v1/sessions', {'title': 'synthetic selected history', 'persona_id': 'e2ebot'})['session_id']
    newer = api('/v1/sessions', {'title': 'synthetic sibling history', 'persona_id': 'e2ebot'})['session_id']
    assert probe('/_e2e/swipe_history?session_id=' + older)['seeded'] == 3
    assert len(api('/v1/sessions/' + older)['messages']) == 3
    assert api('/v1/sessions/' + newer)['messages'] == []
    assert probe('/_e2e/scroll_history?session_id=' + older)['seeded'] == 48
    assert len(api('/v1/sessions/' + older)['messages']) == 99
    assert api('/v1/sessions/' + newer)['messages'] == []
    probe('/_e2e/reply?mode=instant')
    probe('/_e2e/reset')
    assert api('/v1/bots/e2ebot/reply')['reply']['mode'] == 'verbose'
    print('PASS: history seeds the selected conversation; reset restores the verbose baseline.')

    probe('/_e2e/reply?mode=instant')
    try:
        sid = api('/v1/sessions', {'title': 'synthetic safe-point pause', 'persona_id': 'e2ebot'})['session_id']
        api('/v1/sessions/' + sid + '/messages', {'content': '查一下资料', 'model': 'e2e-vision-model', 'provider': {}})
        deadline = time.monotonic() + 5
        worker = None
        while time.monotonic() < deadline:
            workers = api('/v1/workers?session_id=' + sid)['workers']
            if workers and workers[0].get('task_id'):
                worker = workers[0]
                if any(e['type'] == 'tool_call' for e in api('/v1/tasks/' + worker['task_id'])['events']):
                    break
            time.sleep(.05)
        assert worker and worker.get('task_id'), 'Background tool did not start before pause'
        path = '/v1/workers/' + worker['worker_id']
        pending = api(path + '/pause', {})['worker']
        assert pending['status'] == 'running' and not pending['can_resume'], pending
        deadline = time.monotonic() + 10
        while time.monotonic() < deadline:
            parked = api(path)['worker']
            if parked['status'] == 'paused':
                break
            time.sleep(.1)
        assert parked['status'] == 'paused' and parked['can_resume'], parked
        task = api('/v1/tasks/' + worker['task_id'])
        assert any(e['type'] == 'tool_result' and 'e2e-back-step0' in str(e['payload']) for e in task['events']), task
        api(path + '/resume', {})
        # 第一步已在暂停前完成；恢复后两步各8秒，沿用原来的7秒调度余量。
        # 这是受控夹具的执行预算，仍必须等到真实completed，不接受running。
        deadline = time.monotonic() + (2 * 8 + 7)
        while time.monotonic() < deadline:
            resumed = api(path)['worker']
            if resumed['status'] == 'completed':
                break
            time.sleep(.1)
        assert resumed['status'] == 'completed', resumed
        print('PASS: pause finishes the current tool, checkpoints, and resumes to completion without stopping it.')
    finally:
        probe('/_e2e/reply?mode=verbose')


if __name__ == '__main__':
    main()
