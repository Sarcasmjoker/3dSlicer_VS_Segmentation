import os
import sys
import shutil
import tempfile
import subprocess
import logging

import qt
import slicer
from slicer.ScriptedLoadableModule import *
from slicer.util import VTKObservationMixin


# ---------------------------------------------------------------------------
# Module metadata
# ---------------------------------------------------------------------------

class VSSegmentation(ScriptedLoadableModule):
    def __init__(self, parent):
        super().__init__(parent)
        self.parent.title = "VS Segmentation"
        self.parent.categories = ["Segmentation"]
        self.parent.dependencies = []
        self.parent.contributors = ["VS Segmentation Project"]
        self.parent.helpText = """
Automatic vestibular schwannoma (VS) segmentation from contrast-enhanced T1 (ceT1) MRI.

Steps performed automatically for each input:
1. Intensity normalization (0.5–99.9th percentile clipping, float32)
2. nnU-Net v2 inference (5-fold ensemble, 3d_fullres)
3. Optional keep-largest-region post-processing

Input modes:
- Select Volume nodes already loaded into the Slicer scene
- Add individual files (.nrrd/.nii.gz) or an entire folder from disk

Two models available:
- Dataset502 (1000 ep, recommended): CrossMoDA + cystic / varied-spacing cases
- Dataset501 (250 ep): CrossMoDA ceT1 only
"""
        self.parent.acknowledgementText = (
            "Built with nnU-Net v2 (Isensee et al., Nature Methods 2021)."
        )


# ---------------------------------------------------------------------------
# Worker thread  (keeps Slicer UI responsive during long inference)
# ---------------------------------------------------------------------------

class _SegWorker(qt.QObject):
    """Runs the inference queue in a QThread; communicates via Qt signals."""

    # item index, status string ("running" | "done" | "error" | "cancelled")
    itemStatusChanged = qt.Signal(int, str)
    # item index, short message
    itemMessage      = qt.Signal(int, str)
    # finished (all items processed or cancelled)
    finished         = qt.Signal()
    # log line
    logLine          = qt.Signal(str)

    def __init__(self, items, logic, parent=None):
        super().__init__(parent)
        self._items  = items   # list of dict: {type, node/path, name}
        self._logic  = logic
        self._cancel = False

    def requestCancel(self):
        self._cancel = True
        self._logic.cancelCurrent()

    def run(self):
        for idx, item in enumerate(self._items):
            if self._cancel:
                self.itemStatusChanged.emit(idx, "cancelled")
                continue

            self.itemStatusChanged.emit(idx, "running")
            try:
                seg_node = self._logic.processItem(
                    item,
                    logCallback=lambda line: self.logLine.emit(line),
                )
                msg = seg_node.GetName() if seg_node else "done (no output loaded)"
                self.itemStatusChanged.emit(idx, "done")
                self.itemMessage.emit(idx, msg)
            except Exception as exc:
                if self._cancel:
                    self.itemStatusChanged.emit(idx, "cancelled")
                else:
                    self.itemStatusChanged.emit(idx, "error")
                    self.itemMessage.emit(idx, str(exc)[:120])
                logging.exception(exc)

        self.finished.emit()


# ---------------------------------------------------------------------------
# Widget
# ---------------------------------------------------------------------------

_STATUS_COLORS = {
    "pending":   "#888888",
    "running":   "#1a7abf",
    "done":      "#2e9e44",
    "error":     "#cc3333",
    "cancelled": "#e07800",
}

class VSSegmentationWidget(ScriptedLoadableModuleWidget, VTKObservationMixin):
    def __init__(self, parent=None):
        super().__init__(parent)
        VTKObservationMixin.__init__(self)
        self.logic   = None
        self._worker = None
        self._thread = None
        self._queue  = []   # list of item dicts

    # ------------------------------------------------------------------
    def setup(self):
        super().setup()
        uiWidget = slicer.util.loadUI(self.resourcePath("UI/VSSegmentation.ui"))
        self.layout.addWidget(uiWidget)
        self.ui = slicer.util.childWidgetVariables(uiWidget)
        uiWidget.setMRMLScene(slicer.mrmlScene)
        self.ui.inputVolumeSelector.setMRMLScene(slicer.mrmlScene)
        self.logic = VSSegmentationLogic()

        # Model combo
        self.ui.modelSelector.clear()
        self.ui.modelSelector.addItem(
            "Dataset502 — 1000 ep  (recommended: CrossMoDA + cystic)", "502")
        self.ui.modelSelector.addItem(
            "Dataset501 — 250 ep  (CrossMoDA ceT1 only)", "501")
        self.ui.modelSelector.setCurrentIndex(0)

        # Default paths: prefer the models/ directory bundled in this repo,
        # then fall back to the original dev-machine path.
        module_dir = os.path.dirname(os.path.abspath(__file__))
        bundled_models = os.path.normpath(os.path.join(module_dir, "..", "models"))
        for path, widget in [
            (r"C:\Users\wuche\.conda\envs\vs_seg", self.ui.condaEnvEdit),
            (bundled_models,                         self.ui.resultsPathEdit),
            (r"D:\VS\crossmoda2022_training\nnUNet_results", self.ui.resultsPathEdit),
        ]:
            if os.path.isdir(path) and not widget.text:
                widget.text = path

        # Queue table
        self.ui.queueTable.setColumnCount(3)
        self.ui.queueTable.setHorizontalHeaderLabels(["Name", "Status", "Output / Message"])
        self.ui.queueTable.horizontalHeader().setStretchLastSection(True)
        self.ui.queueTable.setSelectionBehavior(qt.QAbstractItemView.SelectRows)
        self.ui.queueTable.setEditTriggers(qt.QAbstractItemView.NoEditTriggers)

        # Signals
        self.ui.addVolumeButton.clicked.connect(self.onAddVolume)
        self.ui.addFilesButton.clicked.connect(self.onAddFiles)
        self.ui.addFolderButton.clicked.connect(self.onAddFolder)
        self.ui.removeButton.clicked.connect(self.onRemoveSelected)
        self.ui.clearButton.clicked.connect(self.onClearQueue)
        self.ui.runButton.clicked.connect(self.onRun)
        self.ui.cancelButton.clicked.connect(self.onCancel)
        self.ui.condaEnvBrowseButton.clicked.connect(self.onBrowseCondaEnv)
        self.ui.resultsPathBrowseButton.clicked.connect(self.onBrowseResultsPath)

        self._updateRunButton()

    # ------------------------------------------------------------------
    def cleanup(self):
        self.removeObservers()

    # ------------------------------------------------------------------
    # Queue management
    # ------------------------------------------------------------------

    def _addItem(self, item):
        self._queue.append(item)
        row = self.ui.queueTable.rowCount
        self.ui.queueTable.insertRow(row)
        self.ui.queueTable.setItem(row, 0, qt.QTableWidgetItem(item["name"]))
        status_item = qt.QTableWidgetItem("Pending")
        status_item.setForeground(qt.QColor(_STATUS_COLORS["pending"]))
        self.ui.queueTable.setItem(row, 1, status_item)
        self.ui.queueTable.setItem(row, 2, qt.QTableWidgetItem(""))
        self._updateRunButton()

    def onAddVolume(self):
        node = self.ui.inputVolumeSelector.currentNode()
        if not node:
            slicer.util.warningDisplay("No volume node selected in the dropdown.")
            return
        self._addItem({"type": "node", "node": node, "name": node.GetName()})

    def onAddFiles(self):
        paths, _ = qt.QFileDialog.getOpenFileNames(
            self.parent,
            "Select ceT1 image files",
            "",
            "Medical images (*.nrrd *.nii.gz *.nii *.mha *.mhd);;All files (*)"
        )
        for p in paths:
            self._addItem({"type": "file", "path": p,
                           "name": os.path.basename(p)})

    def onAddFolder(self):
        folder = qt.QFileDialog.getExistingDirectory(
            self.parent, "Select folder containing ceT1 images")
        if not folder:
            return
        exts = (".nrrd", ".nii.gz", ".nii", ".mha", ".mhd")
        files = sorted(f for f in os.listdir(folder)
                       if any(f.lower().endswith(e) for e in exts)
                       and "_seg" not in f)
        if not files:
            slicer.util.warningDisplay(
                f"No supported image files found in:\n{folder}")
            return
        for fn in files:
            self._addItem({"type": "file",
                           "path": os.path.join(folder, fn),
                           "name": fn})

    def onRemoveSelected(self):
        rows = sorted(
            {idx.row() for idx in self.ui.queueTable.selectedIndexes()},
            reverse=True)
        for r in rows:
            self.ui.queueTable.removeRow(r)
            self._queue.pop(r)
        self._updateRunButton()

    def onClearQueue(self):
        self.ui.queueTable.setRowCount(0)
        self._queue.clear()
        self._updateRunButton()

    # ------------------------------------------------------------------
    # Run / Cancel
    # ------------------------------------------------------------------

    def _updateRunButton(self):
        ready = (bool(self._queue)
                 and bool(self.ui.condaEnvEdit.text)
                 and bool(self.ui.resultsPathEdit.text)
                 and self._thread is None)
        self.ui.runButton.enabled = ready
        self.ui.cancelButton.enabled = self._thread is not None

    def onRun(self):
        if not self._queue:
            return

        conda_env     = self.ui.condaEnvEdit.text.strip()
        nnunet_results = self.ui.resultsPathEdit.text.strip()
        dataset_id    = self.ui.modelSelector.currentData
        postprocess   = self.ui.postprocessCheckBox.checked
        auto_load     = self.ui.autoLoadCheckBox.checked

        try:
            self.logic.configure(
                conda_env=conda_env,
                nnunet_results=nnunet_results,
                dataset_id=dataset_id,
                postprocess=postprocess,
                auto_load=auto_load,
            )
        except Exception as exc:
            slicer.util.errorDisplay(str(exc))
            return

        # Reset all rows to Pending
        for r in range(self.ui.queueTable.rowCount):
            self._setRowStatus(r, "pending", "")

        self.ui.logTextEdit.clear()

        self._thread = qt.QThread()
        self._worker = _SegWorker(list(self._queue), self.logic)
        self._worker.moveToThread(self._thread)

        self._thread.started.connect(self._worker.run)
        self._worker.itemStatusChanged.connect(self._onItemStatus)
        self._worker.itemMessage.connect(self._onItemMessage)
        self._worker.logLine.connect(self._appendLog)
        self._worker.finished.connect(self._onWorkerFinished)

        self._thread.start()
        self._updateRunButton()

    def onCancel(self):
        if self._worker:
            self._worker.requestCancel()
        self.ui.cancelButton.enabled = False

    def _onItemStatus(self, idx, status):
        msg = self.ui.queueTable.item(idx, 2)
        self._setRowStatus(idx, status, msg.text() if msg else "")

    def _onItemMessage(self, idx, text):
        self._setRowStatus(
            idx,
            self.ui.queueTable.item(idx, 1).text().lower(),
            text)

    def _setRowStatus(self, row, status, message):
        color = _STATUS_COLORS.get(status, "#888888")
        label = status.capitalize()
        si = self.ui.queueTable.item(row, 1)
        if not si:
            si = qt.QTableWidgetItem()
            self.ui.queueTable.setItem(row, 1, si)
        si.setText(label)
        si.setForeground(qt.QColor(color))
        mi = self.ui.queueTable.item(row, 2)
        if not mi:
            mi = qt.QTableWidgetItem()
            self.ui.queueTable.setItem(row, 2, mi)
        mi.setText(message)

    def _appendLog(self, line):
        self.ui.logTextEdit.appendPlainText(line.rstrip())
        sb = self.ui.logTextEdit.verticalScrollBar()
        sb.setValue(sb.maximum)

    def _onWorkerFinished(self):
        self._thread.quit()
        self._thread.wait()
        self._thread = None
        self._worker = None
        self._updateRunButton()
        slicer.app.layoutManager().setLayout(
            slicer.vtkMRMLLayoutNode.SlicerLayoutFourUpView)

    # ------------------------------------------------------------------
    # Environment path browsers
    # ------------------------------------------------------------------

    def onBrowseCondaEnv(self):
        path = qt.QFileDialog.getExistingDirectory(
            self.parent, "Select vs_seg conda environment directory")
        if path:
            self.ui.condaEnvEdit.text = path
            self._updateRunButton()

    def onBrowseResultsPath(self):
        path = qt.QFileDialog.getExistingDirectory(
            self.parent, "Select nnUNet_results directory")
        if path:
            self.ui.resultsPathEdit.text = path
            self._updateRunButton()


# ---------------------------------------------------------------------------
# Logic
# ---------------------------------------------------------------------------

class VSSegmentationLogic(ScriptedLoadableModuleLogic):
    """
    Core inference logic.  Call configure() once, then processItem() per case.
    Subprocess handle is stored in _activeProc so the worker can cancel it.
    """

    DATASET_CONFIG = {
        "501": {"name": "Dataset501_VSceT1",  "trainer": "nnUNetTrainer_250epochs"},
        "502": {"name": "Dataset502_VSmix",   "trainer": "nnUNetTrainer"},
    }

    def __init__(self):
        super().__init__()
        self._activeProc  = None   # current Popen; used for cancellation
        self._conda_env   = ""
        self._nnunet_results = ""
        self._dataset_id  = "502"
        self._postprocess = True
        self._auto_load   = True

    # ------------------------------------------------------------------
    def configure(self, conda_env, nnunet_results, dataset_id,
                  postprocess, auto_load):
        if dataset_id not in self.DATASET_CONFIG:
            raise ValueError(f"Unknown dataset_id: {dataset_id}")
        self._findPythonExe(conda_env)          # validate early
        self._findNormalizeScript()              # validate early
        self._conda_env      = conda_env
        self._nnunet_results = nnunet_results
        self._dataset_id     = dataset_id
        self._postprocess    = postprocess
        self._auto_load      = auto_load

    def cancelCurrent(self):
        if self._activeProc and self._activeProc.poll() is None:
            self._activeProc.kill()

    # ------------------------------------------------------------------
    def processItem(self, item, logCallback=None):
        """Process one queue item; returns vtkMRMLSegmentationNode or None."""
        cfg         = self.DATASET_CONFIG[self._dataset_id]
        python_exe  = self._findPythonExe(self._conda_env)
        script      = self._findNormalizeScript()

        work_dir = tempfile.mkdtemp(prefix="slicer_vs_")
        try:
            # ---- Export input to a temp nrrd ----
            if item["type"] == "node":
                input_nrrd = os.path.join(work_dir, "input.nrrd")
                slicer.util.exportNode(item["node"], input_nrrd)
                ref_path = input_nrrd
            else:
                # Copy the file so the script works in an isolated dir
                src  = item["path"]
                ext  = ".nrrd" if src.lower().endswith(".nrrd") else \
                       ".nii.gz" if src.lower().endswith(".nii.gz") else \
                       os.path.splitext(src)[1]
                dst  = os.path.join(work_dir, "input" + ext)
                shutil.copy2(src, dst)
                ref_path = dst

            # ---- Build subprocess environment ----
            env = os.environ.copy()
            for var in ("PYTHONHOME", "PYTHONPATH", "PYTHONNOUSERSITE",
                       # Slicer-specific variables that must NOT leak into the
                       # vs_seg subprocess: its own SimpleITK/ITK build tries
                       # to load Slicer's ITK factory plugins (version
                       # mismatch -> harmless but noisy "Possible incompatible
                       # factory load" / "ImageIO factory did not return an
                       # ImageIOBase" warnings on every run).
                       "ITK_AUTOLOAD_PATH", "QT_PLUGIN_PATH", "SLICER_HOME"):
                env.pop(var, None)
            path_key   = next((k for k in env if k.upper() == "PATH"), "PATH")
            extra      = [self._conda_env,
                          os.path.join(self._conda_env, "Scripts"),
                          os.path.join(self._conda_env, "Library", "bin")]
            env[path_key] = os.pathsep.join(
                [p for p in extra if os.path.isdir(p)] + [env.get(path_key, "")])
            env["nnUNet_results"]      = self._nnunet_results
            env["nnUNet_raw"]          = ""
            env["nnUNet_preprocessed"] = ""
            env["nnUNet_n_proc_DA"]    = "4"
            # Force UTF-8 stdout/stderr regardless of the Windows console
            # code page, so the parent-side decode below always matches.
            env["PYTHONIOENCODING"]    = "utf-8"
            env["PYTHONUTF8"]          = "1"

            # ---- Determine the input folder the script will use ----
            # The script scans its --folder for *.nrrd; we pass work_dir
            # which contains exactly one file named input.*
            cmd = [
                python_exe, script,
                "--folder",       work_dir,
                "-d",             self._dataset_id,
                "-tr",            cfg["trainer"],
                "--dataset-name", cfg["name"],
                "--suffix",       "_seg",
            ]
            if logCallback:
                logCallback("Running: " + " ".join(cmd))

            self._activeProc = subprocess.Popen(
                cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                text=True, encoding="utf-8", errors="replace", env=env,
            )
            output_lines = []
            for line in self._activeProc.stdout:
                output_lines.append(line)
                if logCallback:
                    logCallback(line.rstrip())
            self._activeProc.wait()
            rc = self._activeProc.returncode
            self._activeProc = None

            if rc != 0:
                tail = "".join(output_lines[-30:])
                raise RuntimeError(
                    f"Inference failed (rc={rc}):\n{tail}")

            # ---- Locate the output _seg file ----
            # script saves as <stem>_seg<ext>; stem is "input"
            seg_candidates = [
                f for f in os.listdir(work_dir)
                if "_seg" in f and not f.endswith(".nii.gz.nii.gz")
            ]
            if not seg_candidates:
                raise FileNotFoundError(
                    "Inference finished but no _seg file found in work_dir.\n"
                    + "".join(output_lines[-10:]))
            seg_file = os.path.join(work_dir, seg_candidates[0])

            # ---- Optionally write back to original folder ----
            if item["type"] == "file":
                orig_dir  = os.path.dirname(item["path"])
                base      = os.path.splitext(os.path.basename(item["path"]))[0]
                if base.endswith(".nii"):      # handle .nii.gz double-ext
                    base = base[:-4]
                out_path  = os.path.join(orig_dir, base + "_seg.nrrd")
                shutil.copy2(seg_file, out_path)
                if logCallback:
                    logCallback(f"  Saved: {out_path}")

            # ---- Load into Slicer scene ----
            if not self._auto_load:
                return None

            if item["type"] == "node":
                ref_node = item["node"]
            else:
                ref_node = slicer.util.loadVolume(item["path"])

            return self._importSegmentation(seg_file, ref_node)

        finally:
            shutil.rmtree(work_dir, ignore_errors=True)

    # ------------------------------------------------------------------
    def _findPythonExe(self, conda_env):
        for candidate in [os.path.join(conda_env, "python.exe"),
                          os.path.join(conda_env, "python")]:
            if os.path.isfile(candidate):
                return candidate
        raise FileNotFoundError(
            f"python.exe not found in: {conda_env}\n"
            "Please verify the vs_seg environment path.")

    def _findNormalizeScript(self):
        # 1) Explicit override always wins.
        override = os.environ.get("VSSEG_SCRIPT_PATH")
        if override and os.path.isfile(override):
            return override

        module_dir = os.path.dirname(os.path.abspath(__file__))
        # 2) Bundled copy shipped with the extension itself -- this is what
        #    makes the extension self-contained after `git clone`; no other
        #    file from any external repository is required.
        bundled = os.path.join(module_dir, "Resources", "Scripts",
                               "normalize_and_predict.py")
        if os.path.isfile(bundled):
            return os.path.normpath(bundled)

        # 3) Legacy fallbacks for the original development checkout.
        for rel in [
            os.path.join(module_dir, "..", "..", "..", "scripts",
                         "06_normalize_and_predict.py"),
            os.path.join(module_dir, "..", "..", "scripts",
                         "06_normalize_and_predict.py"),
            r"D:\VS\crossmoda2022_training\scripts\06_normalize_and_predict.py",
        ]:
            if os.path.isfile(rel):
                return os.path.normpath(rel)

        raise FileNotFoundError(
            "normalize_and_predict.py not found (checked the bundled "
            "Resources/Scripts copy and legacy paths).\n"
            "Set the VSSEG_SCRIPT_PATH environment variable to its location.")

    def _importSegmentation(self, seg_file, ref_node):
        label_node = slicer.util.loadLabelVolume(seg_file)
        label_node.SetName(ref_node.GetName() + "_VS_seg")

        seg_node = slicer.mrmlScene.AddNewNodeByClass("vtkMRMLSegmentationNode")
        seg_node.SetName(ref_node.GetName() + "_VS_segmentation")
        slicer.modules.segmentations.logic().ImportLabelmapToSegmentationNode(
            label_node, seg_node)
        seg_node.CreateClosedSurfaceRepresentation()

        seg = seg_node.GetSegmentation()
        if seg.GetNumberOfSegments() > 0:
            s = seg.GetNthSegment(0)
            s.SetName("Vestibular Schwannoma")
            s.SetColor(0.9, 0.3, 0.3)

        slicer.mrmlScene.RemoveNode(label_node)
        seg_node.SetReferenceImageGeometryParameterFromVolumeNode(ref_node)
        return seg_node
