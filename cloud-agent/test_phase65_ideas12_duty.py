import time
import unittest

from test_phase1_support import CloudServerTestCase


class DutyExternalPushTests(CloudServerTestCase):
    def test_duty_skips_external_push_except_digest(self):
        self.request("PUT", "/v1/resources", {"duty_until": time.time() + 3600})
        try:
            self.assertTrue(self.srv.on_duty())
            self.assertFalse(self.srv.allow_external_push("task_completed"))
            self.assertFalse(self.srv.allow_external_push("group_message"))
            self.assertTrue(self.srv.allow_external_push("duty_digest"))
            self.assertIn("结论", self.srv.DUTY_NOTE)
            self.assertIn("单位", self.srv.DUTY_NOTE)
        finally:
            self.request("PUT", "/v1/resources", {"duty_until": 0})
        self.assertFalse(self.srv.on_duty())
        self.assertTrue(self.srv.allow_external_push("task_completed"))


if __name__ == "__main__":
    unittest.main()
