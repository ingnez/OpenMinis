#!/usr/bin/env python3
"""验证 UI 假模型遵守流式协议，以及后台摘要不改变 Bot 转交意图。"""
import json
from pathlib import Path
import sys
import time
import unittest
import urllib.request
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'cloud-agent'))
import e2e_cloud_stack as fixture
import cloud_workers
from test_phase1_support import FakeModelHandler, CloudServerTestCase, _serve, tool_call


class StreamingFixtureTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.server, cls.port = _serve(FakeModelHandler)
        FakeModelHandler.scripts.update({fixture.LOCAL_BACK_MODEL: fixture.back_script,
                                        fixture.LOCAL_FRONT_MODEL: fixture.local_front_script})

    @classmethod
    def tearDownClass(cls):
        cls.server.shutdown()
        cls.server.server_close()

    def stream(self, model, messages):
        request = urllib.request.Request(f'http://127.0.0.1:{self.port}/v1/chat/completions',
            data=json.dumps({'model': model, 'stream': True, 'messages': messages}).encode(),
            headers={'Content-Type': 'application/json'})
        with urllib.request.build_opener(urllib.request.ProxyHandler({})).open(request, timeout=10) as response:
            self.assertEqual(response.headers.get_content_type(), 'text/event-stream')
            lines = response.read().decode().splitlines()
        self.assertIn('data: [DONE]', lines)
        return [json.loads(line[6:]) for line in lines if line.startswith('data: ') and line != 'data: [DONE]']

    def test_background_tools_have_indices_and_finish_reason(self):
        events = self.stream(fixture.LOCAL_BACK_MODEL, [{'role': 'user', 'content': '查一下资料'}])
        call = events[0]['choices'][0]['delta']['tool_calls'][0]
        self.assertEqual((call['index'], call['function']['name']), (0, 'shell_execute'))
        self.assertEqual(events[-1]['choices'][0]['finish_reason'], 'tool_calls')

    def test_multiple_tools_keep_separate_stream_indices(self):
        FakeModelHandler.scripts['two-tools'] = lambda data: {'role': 'assistant', 'content': None, 'tool_calls': [
            tool_call('one', 'task_status', {'id': 'one'})['tool_calls'][0],
            tool_call('two', 'task_status', {'id': 'two'})['tool_calls'][0]]}
        events = self.stream('two-tools', [{'role': 'user', 'content': '两件事的进度'}])
        calls = events[0]['choices'][0]['delta']['tool_calls']
        self.assertEqual([(call['index'], call['id']) for call in calls], [(0, 'one'), (1, 'two')])

    def test_front_finishes_after_tool_result_with_actual_text(self):
        messages = [{'role': 'user', 'content': '查一下慢活'},
                    tool_call('front', 'spawn_task', {'goal': '查一下慢活'}),
                    {'role': 'tool', 'tool_call_id': 'front', 'content': '{"status":"running"}'}]
        events = self.stream(fixture.LOCAL_FRONT_MODEL, messages)
        text = ''.join(event['choices'][0].get('delta', {}).get('content') or '' for event in events)
        self.assertIn('后台已收到', text)
        self.assertEqual(events[-1]['choices'][0]['finish_reason'], 'stop')


class ThreadSummaryFixtureTests(CloudServerTestCase):
    def test_completed_worker_summary_preserves_notice_and_delegation(self):
        self.request('PUT', '/v1/credentials/e2e-thread', {'api_key': 'sk-fixture-only', 'base_url': self.model_base})
        for bot, name in ((fixture.BOT_ID, fixture.BOT_NAME), (fixture.MAKER_ID, fixture.MAKER_NAME)):
            status, result = self.request('PUT', f'/v1/bots/{bot}', {
                'name': name, 'instructions': '执行假数据测试任务', 'model': fixture.MODEL, 'credential': 'e2e-thread'})
            self.assertEqual(status, 201, result)
            self.request('PUT', f'/v1/bots/{bot}/reply', {'mode': 'verbose'})
        FakeModelHandler.scripts[fixture.MODEL] = fixture.script
        sid = self.request('POST', '/v1/sessions', {'title': '摘要后的转交', 'persona_id': fixture.BOT_ID})[1]['session_id']
        conn = self.srv.get_db_connection()
        try:
            worker = cloud_workers.create(conn, fixture.BOT_ID, sid, '上一轮资料')
            cloud_workers.set_status(conn, worker['worker_id'], 'completed', result='资料已整理', finished_at=time.time())
        finally:
            conn.close()
        for text in ('通知工匠', '交给工匠做海报'):
            status, task = self.submit(sid, text, fixture.MODEL)
            self.assertEqual(status, 202)
            self.wait_status(task['task_id'], {'completed'}, timeout=30)
            rows = self.request('GET', f'/v1/sessions/{sid}/bot-threads')[1]['threads']
            self.assertEqual(rows[0]['peer'], fixture.MAKER_ID)
            self.assertGreaterEqual(rows[0]['count'], 1)
        thread = self.request('GET', f'/v1/bot-threads/{fixture.BOT_ID}/{fixture.MAKER_ID}')[1]
        self.assertTrue(any(message['text'] == '记下这条工匠通知' for message in thread['messages']))
        self.assertTrue(any(message['kind'] == 'task' and '做一张海报' in message['text'] for message in thread['messages']))
        self.assertTrue(any(message['kind'] == 'result' and '海报长消息结束' in message['text'] for message in thread['messages']))
        requests = [request for request in FakeModelHandler.requests if request['model'] == fixture.MODEL]
        self.assertTrue(any('[这个对话的后台任务' in fixture.last_user_text(request) for request in requests))


if __name__ == '__main__':
    unittest.main()
