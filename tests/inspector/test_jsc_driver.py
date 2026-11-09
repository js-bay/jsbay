import unittest
from unittest import mock

from jsc_driver import SimulatorProcess, apps, listing_has_connection, listing_is_detached


class ApplicationDiscoveryTests(unittest.TestCase):
    def test_application_list(self):
        metadata = {"WIRApplicationNameKey": "jsc-safari-demo"}
        message = {"__argument": {"WIRApplicationDictionaryKey": {"PID:123": metadata}}}
        self.assertEqual(apps(message), [("PID:123", metadata)])

    def test_application_connected_after_initial_list(self):
        self.assertEqual(apps({"__argument": {"WIRApplicationDictionaryKey": {}}}), [])
        metadata = {
            "WIRApplicationIdentifierKey": "PID:123",
            "WIRApplicationNameKey": "jsc-safari-demo",
        }
        self.assertEqual(apps({"__selector": "_rpc_applicationConnected:", "__argument": metadata}), [("PID:123", metadata)])


class MonitorListingTests(unittest.TestCase):
    def test_detached_listing_does_not_match_an_active_connection(self):
        message = {"__argument": {"WIRApplicationIdentifierKey": "PID:123", "WIRListingKey": {"1": {"WIRTitleKey": "js-bay-demo", "WIRTypeKey": "WIRTypeJavaScript"}}}}
        self.assertFalse(listing_has_connection(message, "PID:123", "js-bay-demo", "connection-1"))
        self.assertTrue(listing_is_detached(message, "PID:123", "js-bay-demo"))


class SimulatorCleanupTests(unittest.TestCase):
    def test_clean_wrapper_exit_does_not_signal_a_reused_process_identifier(self):
        process = SimulatorProcess.__new__(SimulatorProcess)
        process.demo_pid = 123
        process.output = ["CLEAN_EXIT\n"]
        process.process = mock.Mock()
        process.process.poll.return_value = 0
        process._state = mock.Mock(return_value="different")
        with mock.patch("jsc_driver.os.kill") as kill:
            process._stop_demo()
        kill.assert_not_called()


if __name__ == "__main__":
    unittest.main()
