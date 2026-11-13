import unittest
from check_ui_coverage import expected, verify


class CoverageGateTests(unittest.TestCase):
    def test_missing_failed_skipped_or_empty_results_cannot_pass(self):
        name = "E2EFlowsUITests.test01_sendText"
        for verdict in ("failed", "skipped", ""):
            log = f"Test Case '-[MinisUITests.E2EFlowsUITests test01_sendText]' {verdict}"
            with self.subTest(verdict=verdict), self.assertRaises(ValueError):
                verify(log, {name})
        with self.assertRaises(ValueError): verify("", set())

    def test_final_retry_is_used_and_a_later_failure_is_not_hidden(self):
        name = "E2EFlowsUITests.test01_sendText"
        line = "Test Case '-[MinisUITests.E2EFlowsUITests test01_sendText]' "
        self.assertEqual(verify(line + "failed\n" + line + "passed", {name}), 1)
        with self.assertRaises(ValueError): verify(line + "passed\n" + line + "failed", {name})

    def test_unknown_selectors_do_not_silently_run_zero_cases(self):
        with self.assertRaises(ValueError): expected(["MinisUITests/E2EFlowsUITests/typo"])
        with self.assertRaises(ValueError): expected(["MinisTests/SomeTests"])
        self.assertEqual(expected(["MinisUITests/E2EFlowsUITests/test01_sendText"]), {"E2EFlowsUITests.test01_sendText"})


if __name__ == "__main__": unittest.main()
