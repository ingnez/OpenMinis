"""只在已安装云电脑的Linux中运行；本机CI单元测试不伪造浏览器成功。"""
import os, pathlib, threading, tempfile, json
import unittest

@unittest.skipUnless(os.environ.get('OPENMINIS_REAL_BROWSER_TEST')=='1','真实浏览器验证由Linux云电脑CI显式运行')
class RealBrowserTests(unittest.TestCase):
    def test_persistent_browser_across_task_threads(self):
        import cloud_browser
        with tempfile.TemporaryDirectory() as directory:
            root=pathlib.Path(directory)
            html=root/'page.html'
            html.write_text('<html><title>OpenMinis真实浏览器验证</title><input id="name"><button id="go" onclick="document.getElementById(\'result\').textContent=document.getElementById(\'name\').value;localStorage.setItem(\'proof\',\'persisted\')">提交</button><p id="result"></p></html>')
            session='real_browser_ci'
            results=[]
            def run(arguments):
                results.append(cloud_browser.execute_browser_action(session,str(root),arguments))
            def execute(arguments):
                thread=threading.Thread(target=run,args=(arguments,));thread.start();thread.join(45)
                self.assertFalse(thread.is_alive(),'浏览器动作未在时限内完成')
                result=results[-1]
                self.assertNotIn('error',result,str(result))
                return result
            execute({'action':'navigate','url':html.as_uri()})
            execute({'action':'type','selector':'#name','text':'手机已断开，服务器完成操作'})
            execute({'action':'click','selector':'#go'})
            text=execute({'action':'get_text','selector':'#result'})
            self.assertIn('手机已断开',text['text'])
            shot=execute({'action':'screenshot'})
            path=root/shot['file_path']
            self.assertTrue(path.is_file())
            self.assertEqual(path.read_bytes()[:8],b'\x89PNG\r\n\x1a\n')
            execute({'action':'navigate','url':html.as_uri()})
            execute({'action':'get_text','selector':'body'})
            tabs=execute({'action':'tabs'})
            self.assertGreaterEqual(tabs.get('count',len(tabs.get('tabs',[]))),1)
            print('真实Chromium跨任务线程：导航、输入、点击、读回、截图、再次访问通过')

    def test_vault_fill_login_form(self):
        import cloud_browser
        with tempfile.TemporaryDirectory() as directory:
            root=pathlib.Path(directory)
            html=root/'login.html'
            html.write_text('<html><input id="q" placeholder="search"><form><input id="u" name="email" type="text"><input id="p" type="password">'
                            '<input id="otp" autocomplete="one-time-code"></form><button id="go" onclick="document.getElementById(\'r\').textContent='
                            'document.getElementById(\'u\').value+\'|\'+document.getElementById(\'p\').value.length+\'|\'+document.getElementById(\'q\').value">x</button><p id="r"></p></html>')
            session='real_vault_ci'
            out=[]
            def run(a):
                t=threading.Thread(target=lambda:out.append(cloud_browser.execute_browser_action(session,str(root),a)));t.start();t.join(45)
                return out[-1]
            run({'action':'navigate','url':html.as_uri()})
            res=run({'action':'__vault_fill__','fields':{'username':'fake.user@example.com','password':'FakePass-123456'}})
            self.assertEqual(sorted(res['filled']),['password','username'],res)
            run({'action':'click','selector':'#go'})
            self.assertEqual(run({'action':'get_text','selector':'#r'})['text'],'fake.user@example.com|15|')
            print('真实Chromium保管库填写：用户名进了表单里的框、没进搜索框，密码已填')

if __name__=='__main__':unittest.main(verbosity=2)
