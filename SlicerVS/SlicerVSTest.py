import os
import unittest
import slicer


class SlicerVSTest(unittest.TestCase):
    def setUp(self):
        slicer.mrmlScene.Clear(0)

    def test_logic_init(self):
        from SlicerVS import SlicerVSLogic
        logic = SlicerVSLogic()
        self.assertIn("501", logic.DATASET_CONFIG)
        self.assertIn("502", logic.DATASET_CONFIG)

    def test_find_python_missing(self):
        from SlicerVS import SlicerVSLogic
        logic = SlicerVSLogic()
        with self.assertRaises(FileNotFoundError):
            logic._findPythonExe("/nonexistent/path")

    def test_dataset_config(self):
        from SlicerVS import SlicerVSLogic
        logic = SlicerVSLogic()
        cfg501 = logic.DATASET_CONFIG["501"]
        self.assertEqual(cfg501["trainer"], "nnUNetTrainer_250epochs")
        cfg502 = logic.DATASET_CONFIG["502"]
        self.assertEqual(cfg502["trainer"], "nnUNetTrainer")
