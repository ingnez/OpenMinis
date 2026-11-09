import json, pathlib, socket, time, unittest
import test_integration

class TestCloudV2Edges(test_integration.TestCloudComputerRobustness):
    # 此处只运行新增断线场景，基类十项由test_integration独立执行。
    for _test_name in unittest.defaultTestLoader.getTestCaseNames(test_integration.TestCloudComputerRobustness):
        locals()[_test_name] = None
    def test_08_disconnect_after_submission(self):
        _, created=self._request('POST','/v1/sessions',{'title':'客户端断开验收'})
        sid=created['session_id']
        body=json.dumps({'content':'offline autonomous','model':'gpt-test','client_nonce':'disconnect-proof','provider':{'base_url':f'http://127.0.0.1:{self.mock_llm_port}/v1','api_key':'test-key'}}).encode()
        # TCP 客户端发完请求后不等待响应就关闭，服务端不能因BrokenPipe丢弃任务。
        host=getattr(self,'server_port',None) or getattr(self,'agent_server_port',None) or getattr(self,'agent_port',None)
        self.assertIsNotNone(host,'测试支架需公开实际服务端口')
        token=getattr(self,'test_token',None) or getattr(self,'token',None)
        self.assertIsNotNone(token,'测试支架需公开测试Token')
        connection=socket.create_connection(('127.0.0.1',host),timeout=5)
        header=f'POST /v1/sessions/{sid}/messages HTTP/1.1\r\nHost: localhost\r\nAuthorization: Bearer {token}\r\nContent-Type: application/json\r\nContent-Length: {len(body)}\r\nConnection: close\r\n\r\n'.encode()
        connection.sendall(header+body);connection.close()
        deadline=time.monotonic()+10
        detail={}
        while time.monotonic()<deadline:
            _,detail=self._request('GET',f'/v1/sessions/{sid}')
            tasks=detail.get('tasks',[])
            if tasks and tasks[0]['status'] not in ['running','queued']:break
            time.sleep(.05)
        self.assertTrue(detail.get('tasks'),'客户端关闭后任务必须已持久化')
        self.assertEqual(detail['tasks'][0]['status'],'completed',detail)

if __name__=='__main__':unittest.main(verbosity=2)
