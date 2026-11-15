import importlib.machinery
import importlib.util
import unittest
import ssl
from pathlib import Path


path = Path(__file__).resolve().parents[1] / 'ansible/roles/garage-monitor/files/garage-pve-metrics'
loader = importlib.machinery.SourceFileLoader('garage_pve_metrics', str(path))
spec = importlib.util.spec_from_loader(loader.name, loader)
module = importlib.util.module_from_spec(spec)
loader.exec_module(module)


class TestPveMetrics(unittest.TestCase):
    def test_context_accepts_proxmox_ca_but_still_verifies_peer_and_hostname(self):
        context = module.make_context(ssl.get_default_verify_paths().cafile)
        self.assertFalse(context.verify_flags & ssl.VERIFY_X509_STRICT)
        self.assertTrue(context.check_hostname)
        self.assertEqual(context.verify_mode, ssl.CERT_REQUIRED)

    def test_healthy_pool_and_storage(self):
        text = module.format_metrics([{'name': 'rpool', 'health': 'ONLINE'}], {'active': 1, 'total': 1000, 'avail': 350}, 1700000000)
        self.assertIn('garage_pve_zpool_healthy 1\n', text)
        self.assertIn('garage_pve_storage_available_bytes 350\n', text)
        self.assertIn('garage_pve_last_success_timestamp_seconds 1700000000\n', text)

    def test_degraded_pool_is_unhealthy(self):
        text = module.format_metrics([{'name': 'rpool', 'health': 'DEGRADED'}], {'active': 1, 'total': 100, 'avail': 5}, 1700000000)
        self.assertIn('garage_pve_zpool_healthy 0\n', text)

    def test_missing_pool_or_inactive_storage_is_failure(self):
        for pools, storage in [([], {'active': 1, 'total': 100, 'avail': 5}), ([{'name': 'rpool', 'health': 'ONLINE'}], {'active': 0, 'total': 100, 'avail': 5})]:
            with self.subTest(pools=pools, storage=storage), self.assertRaises(ValueError):
                module.format_metrics(pools, storage, 1700000000)


if __name__ == '__main__':
    unittest.main()
