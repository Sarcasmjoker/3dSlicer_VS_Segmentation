import os
import unittest
import slicer


class VSSegmentationTest(unittest.TestCase):
    def setUp(self):
        slicer.mrmlScene.Clear(0)

    def test_logic_init(self):
        from VSSegmentation import VSSegmentationLogic
        logic = VSSegmentationLogic()
        self.assertIn("501", logic.DATASET_CONFIG)
        self.assertIn("502", logic.DATASET_CONFIG)

    def test_find_python_missing(self):
        from VSSegmentation import VSSegmentationLogic
        logic = VSSegmentationLogic()
        with self.assertRaises(FileNotFoundError):
            logic._findPythonExe("/nonexistent/path")

    def test_dataset_config(self):
        from VSSegmentation import VSSegmentationLogic
        logic = VSSegmentationLogic()
        cfg501 = logic.DATASET_CONFIG["501"]
        self.assertEqual(cfg501["trainer"], "nnUNetTrainer_250epochs")
        cfg502 = logic.DATASET_CONFIG["502"]
        self.assertEqual(cfg502["trainer"], "nnUNetTrainer")
