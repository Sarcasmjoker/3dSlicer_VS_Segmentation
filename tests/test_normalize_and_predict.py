import importlib.util
import os
from pathlib import Path
from types import SimpleNamespace
import unittest
from unittest import mock

import numpy as np
import SimpleITK as sitk


REPO_ROOT = Path(__file__).resolve().parents[1]
SCRIPT_PATH = (
    REPO_ROOT
    / "SlicerVS"
    / "Resources"
    / "Scripts"
    / "normalize_and_predict.py"
)
SPEC = importlib.util.spec_from_file_location("slicervs_predict", SCRIPT_PATH)
PREDICT = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(PREDICT)


class FakeCuda:
    def __init__(self, available=False, name="Test GPU", memory_gib=12):
        self._available = available
        self._name = name
        self._memory = memory_gib * 1024**3

    def is_available(self):
        return self._available

    def get_device_name(self, _index):
        return self._name

    def get_device_properties(self, _index):
        return SimpleNamespace(total_memory=self._memory)


class FakeMps:
    def __init__(self, available=False):
        self._available = available

    def is_available(self):
        return self._available


def fake_torch(cuda=False, mps=False, hip=None, memory_gib=12):
    return SimpleNamespace(
        cuda=FakeCuda(cuda, "Fake Accelerator", memory_gib),
        backends=SimpleNamespace(mps=FakeMps(mps)),
        version=SimpleNamespace(cuda="12.8", hip=hip),
    )


class DeviceTests(unittest.TestCase):
    def test_auto_prefers_nvidia_cuda(self):
        device, label = PREDICT.resolve_device("auto", fake_torch(cuda=True))
        self.assertEqual(device, "cuda")
        self.assertIn("NVIDIA CUDA", label)

    def test_rocm_uses_nnunet_cuda_device(self):
        device, label = PREDICT.resolve_device(
            "auto", fake_torch(cuda=True, hip="7.2.1")
        )
        self.assertEqual(device, "cuda")
        self.assertIn("AMD ROCm 7.2.1", label)

    def test_auto_uses_mps_then_cpu(self):
        self.assertEqual(
            PREDICT.resolve_device("auto", fake_torch(mps=True))[0], "mps"
        )
        self.assertEqual(
            PREDICT.resolve_device("auto", fake_torch())[0], "cpu"
        )

    def test_explicit_unavailable_gpu_fails_clearly(self):
        with self.assertRaisesRegex(RuntimeError, "CUDA/ROCm was requested"):
            PREDICT.resolve_device("cuda", fake_torch())

    def test_auto_can_select_installed_directml(self):
        with mock.patch.object(PREDICT, "_directml_available", return_value=True):
            device, label = PREDICT.resolve_device("auto", fake_torch())
        self.assertEqual(device, "dml")
        self.assertIn("DirectML", label)

    def test_unavailable_directml_falls_back_to_cpu(self):
        with mock.patch.object(PREDICT, "_directml_available", return_value=False):
            device, label = PREDICT.resolve_device("dml", fake_torch())
        self.assertEqual(device, "cpu")
        self.assertIn("DirectML unavailable", label)

    def test_auto_enables_cpu_accumulators_below_ten_gib(self):
        self.assertTrue(
            PREDICT.should_use_cpu_accumulators(
                "auto", "cuda", fake_torch(cuda=True, memory_gib=8)
            )
        )
        self.assertFalse(
            PREDICT.should_use_cpu_accumulators(
                "auto", "cuda", fake_torch(cuda=True, memory_gib=12)
            )
        )


class CommandTests(unittest.TestCase):
    def build(self, argv, device="cpu", cpu_accumulators=False):
        args = PREDICT.parse_args(argv)
        with mock.patch.object(
            PREDICT, "find_console_script", return_value="nnUNetv2_predict"
        ):
            return PREDICT.build_predict_command(
                args, "input", "output", device, cpu_accumulators
            )

    def test_fast_profile(self):
        command = self.build(["--preset", "fast", "--device", "cpu"])
        self.assertEqual(command[command.index("-f") + 1], "2")
        self.assertEqual(command[command.index("-step_size") + 1], "0.75")
        self.assertIn("--disable_tta", command)
        self.assertEqual(command[command.index("-npp") + 1], "1")
        self.assertEqual(command[command.index("-nps") + 1], "1")

    def test_accurate_profile(self):
        command = self.build(["--preset", "accurate"])
        fold_index = command.index("-f")
        self.assertEqual(
            command[fold_index + 1:fold_index + 6], ["0", "1", "2", "3", "4"]
        )
        self.assertEqual(command[command.index("-step_size") + 1], "0.5")
        self.assertNotIn("--disable_tta", command)

    def test_low_vram_flag_and_postprocess_parser(self):
        command = self.build(["--preset", "fast"], "cuda", True)
        self.assertIn("--not_on_device", command)
        self.assertFalse(PREDICT.parse_args(["--no-postprocess"]).postprocess)
        self.assertTrue(PREDICT.parse_args(["--postprocess"]).postprocess)

    def test_directml_attempt_runs_in_an_isolated_process(self):
        process = mock.Mock(exitcode=7)
        context = mock.Mock()
        context.Process.return_value = process
        args = PREDICT.parse_args(["--device", "dml"])
        with mock.patch.object(
            PREDICT.multiprocessing, "get_context", return_value=context
        ):
            exit_code = PREDICT.run_directml_isolated(args, "input", "output")
        self.assertEqual(exit_code, 7)
        process.start.assert_called_once_with()
        process.join.assert_called_once_with()


class ImageTests(unittest.TestCase):
    def test_normalize_preserves_geometry_and_float32(self):
        image = sitk.GetImageFromArray(np.arange(64, dtype=np.int16).reshape(4, 4, 4))
        image.SetSpacing((0.8, 0.9, 1.5))
        image.SetOrigin((1.0, 2.0, 3.0))
        output = PREDICT.normalize(image)
        self.assertEqual(output.GetSpacing(), image.GetSpacing())
        self.assertEqual(output.GetOrigin(), image.GetOrigin())
        self.assertEqual(output.GetPixelID(), sitk.sitkFloat32)

    def test_split_stem_handles_nii_gz(self):
        self.assertEqual(PREDICT.split_stem("case.nii.gz"), ("case", ".nii.gz"))


if __name__ == "__main__":
    unittest.main()
