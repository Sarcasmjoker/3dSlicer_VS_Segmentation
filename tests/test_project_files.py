import ast
from pathlib import Path
import unittest
import xml.etree.ElementTree as ElementTree

import yaml


REPO_ROOT = Path(__file__).resolve().parents[1]


class ProjectFileTests(unittest.TestCase):
    def test_environment_files_are_valid_and_share_the_expected_name(self):
        for filename in (
            "environment.yml",
            "environment-cpu.yml",
            "environment-directml.yml",
            "environment-amd-linux.yml",
            "environment-macos.yml",
        ):
            with self.subTest(filename=filename):
                data = yaml.safe_load((REPO_ROOT / filename).read_text("utf-8"))
                self.assertEqual(data["name"], "vs_seg")
                self.assertIn("pip", data["dependencies"])

    def test_directml_environment_uses_compatible_torch(self):
        data = yaml.safe_load(
            (REPO_ROOT / "environment-directml.yml").read_text("utf-8")
        )
        pip_packages = next(
            item["pip"] for item in data["dependencies"] if isinstance(item, dict)
        )
        self.assertIn("torch==2.3.1", pip_packages)
        self.assertIn("torch-directml==0.2.4.dev240815", pip_packages)

    def test_slicer_ui_contains_backend_and_quality_controls(self):
        root = ElementTree.parse(
            REPO_ROOT / "SlicerVS" / "Resources" / "UI" / "SlicerVS.ui"
        ).getroot()
        names = {element.attrib.get("name") for element in root.iter("widget")}
        self.assertIn("qualityComboBox", names)
        self.assertIn("deviceComboBox", names)

    def test_slicer_module_is_valid_python(self):
        source = (REPO_ROOT / "SlicerVS" / "SlicerVS.py").read_text("utf-8")
        ast.parse(source)


if __name__ == "__main__":
    unittest.main()
