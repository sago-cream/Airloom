import importlib.util
import os
import resource
import time
import unittest
from pathlib import Path

spec = importlib.util.spec_from_file_location("measure", Path(__file__).parents[1] / "Scripts/measure.py")
measure = importlib.util.module_from_spec(spec)
spec.loader.exec_module(measure)


class MeasurementTests(unittest.TestCase):
    def test_cpu_counters_match_kernel_rusage(self):
        start = measure.snapshot(os.getpid())[1][os.getpid()]["cpu_ns"]
        reference = resource.getrusage(resource.RUSAGE_SELF)
        started = time.monotonic()
        while time.monotonic() - started < 0.2:
            sum(i * i for i in range(1000))
        end = measure.snapshot(os.getpid())[1][os.getpid()]["cpu_ns"]
        actual = resource.getrusage(resource.RUSAGE_SELF)
        expected = actual.ru_utime + actual.ru_stime - reference.ru_utime - reference.ru_stime
        self.assertAlmostEqual((end - start) / 1e9, expected, delta=0.02)

    def test_own_process_tree_and_footprint(self):
        values = measure.snapshot(os.getpid())[1]
        self.assertIn(os.getpid(), values)
        self.assertGreater(values[os.getpid()]["footprint_bytes"], 0)


if __name__ == "__main__":
    unittest.main()
