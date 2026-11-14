#!/usr/bin/env python3
"""清理逻辑必须识别仓库归属；未知占用者出现时零进程被终止。"""
from pathlib import Path
import unittest
from unittest.mock import patch
import manage_e2e_stack as manager


class StackOwnershipTests(unittest.TestCase):
    def test_absolute_and_relative_script_of_this_repo(self):
        root = Path('/tmp/仓库')
        for script in ('scripts/e2e_cloud_stack.py', '/tmp/仓库/scripts/e2e_cloud_stack.py'):
            self.assertTrue(manager.owns_stack((f'python3 -u {script} /tmp/fixtures', str(root)), root))

    def test_unknown_and_other_checkout_are_never_owned(self):
        root = Path('/tmp/仓库')
        for identity in (None, ('python3 -m http.server 18797', str(root)),
                         ('python3 -c "scripts/e2e_cloud_stack.py"', str(root)),
                         ('python3 scripts/e2e_cloud_stack.py', '/tmp/另一仓库'),
                         ('python3 /tmp/另一仓库/scripts/e2e_cloud_stack.py', str(root))):
            self.assertFalse(manager.owns_stack(identity, root), identity)

    def test_unknown_listener_blocks_all_cleanup(self):
        known = (f'python3 {manager.SCRIPT}', str(manager.ROOT))
        with patch.object(manager, 'listeners', return_value={1, 2}), \
             patch.object(manager, 'process_identity', side_effect=lambda pid: known if pid == 1 else ('python3 -m http.server', '/tmp')), \
             patch.object(manager, 'terminate_owned') as terminate:
            with self.assertRaisesRegex(RuntimeError, '未知进程'):
                manager.clean_listeners()
            terminate.assert_not_called()

    def test_multiple_ports_cleanup_each_owned_process_once(self):
        known = (f'python3 {manager.SCRIPT}', str(manager.ROOT))
        with patch.object(manager, 'listeners', return_value={123}), \
             patch.object(manager, 'process_identity', return_value=known), \
             patch.object(manager, 'terminate_owned') as terminate:
            manager.clean_listeners()
            terminate.assert_called_once_with(123)


if __name__ == '__main__':
    unittest.main()
