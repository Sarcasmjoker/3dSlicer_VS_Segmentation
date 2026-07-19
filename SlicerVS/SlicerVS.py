import os
import sys
import shutil
import tempfile
import subprocess
import logging
import re
import signal
import threading

import qt
import slicer
from slicer.ScriptedLoadableModule import *
from slicer.util import VTKObservationMixin


# ---------------------------------------------------------------------------
# Module metadata
# ---------------------------------------------------------------------------

class SlicerVS(ScriptedLoadableModule):
    def __init__(self, parent):
        super().__init__(parent)
        self.parent.title = "SlicerVS"
        self.parent.categories = ["Segmentation"]
        self.parent.dependencies = []
        self.parent.contributors = ["SlicerVS Project"]
        self.parent.helpText = """
Automatic vestibular schwannoma (VS) segmentation from contrast-enhanced T1 (ceT1) MRI.

Steps performed automatically for each input:
1. Intensity normalization (0.5-99.9th percentile clipping, float32)
2. nnU-Net v2 inference (fast single-fold or accurate 5-fold mode)
3. Optional keep-largest-region post-processing

Input modes:
- Select Volume nodes already loaded into the Slicer scene
- Add individual files (.nrrd/.nii.gz) or an entire folder from disk

Backends:
- NVIDIA CUDA and supported AMD ROCm GPUs (native ROCm path on Linux)
- Apple MPS
- Experimental DirectML with automatic CPU fallback
- CPU fallback for other GPUs and integrated graphics
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
    # item index, file-only inference result
    itemResultReady  = qt.Signal(int, object)
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
                result = self._logic.processItem(
                    item,
                    logCallback=lambda line: self.logLine.emit(line),
                )
                self.itemResultReady.emit(idx, result)
            except InferenceCancelled:
                self.itemStatusChanged.emit(idx, "cancelled")
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

_QUALITY_VALUES = ("fast", "accurate")
_DEVICE_VALUES = ("auto", "cuda", "cpu", "mps", "dml")


class InferenceCancelled(Exception):
    """Raised when the user cancels before a case has completed."""

class SlicerVSWidget(ScriptedLoadableModuleWidget, VTKObservationMixin):
    def __init__(self, parent=None):
        super().__init__(parent)
        VTKObservationMixin.__init__(self)
        self.logic   = None
        self._worker = None
        self._thread = None
        self._queue  = []   # list of item dicts
        self._runTempDir = None
        self._destroying = False

    # ------------------------------------------------------------------
    def setup(self):
        super().setup()
        uiWidget = slicer.util.loadUI(self.resourcePath("UI/SlicerVS.ui"))
        self.layout.addWidget(uiWidget)
        self.ui = slicer.util.childWidgetVariables(uiWidget)
        uiWidget.setMRMLScene(slicer.mrmlScene)
        self.ui.inputVolumeSelector.setMRMLScene(slicer.mrmlScene)
        self.logic = SlicerVSLogic()

        # Model is fixed to Dataset502 (1000 ep); no selector needed.

        # Discover the common conda layouts used by Miniforge/Conda.
        module_dir = os.path.dirname(os.path.abspath(__file__))
        user_home = os.path.expanduser("~")
        env_candidates = [
            os.environ.get("SLICERVS_ENV_PATH", ""),
            os.path.join(user_home, "miniforge3", "envs", "vs_seg"),
            os.path.join(user_home, "Miniforge3", "envs", "vs_seg"),
            os.path.join(user_home, ".conda", "envs", "vs_seg"),
            os.path.join(user_home, "miniconda3", "envs", "vs_seg"),
            os.path.join(user_home, "anaconda3", "envs", "vs_seg"),
        ]
        for path in env_candidates:
            if path and os.path.isfile(self.logic._findPythonCandidate(path)):
                self.ui.condaEnvEdit.text = os.path.normpath(path)
                break

        # Prefer a model root that already contains the fast-mode checkpoint.
        bundled_models = os.path.normpath(os.path.join(module_dir, "..", "models"))
        model_candidates = [
            os.environ.get("nnUNet_results", ""),
            bundled_models,
            r"D:\VS\crossmoda2022_training\nnUNet_results",
        ]
        existing_models = [p for p in model_candidates if p and os.path.isdir(p)]
        ready_models = [p for p in existing_models if self.logic.hasCheckpoint(p, "2")]
        if ready_models or existing_models:
            self.ui.resultsPathEdit.text = os.path.normpath(
                (ready_models or existing_models)[0]
            )

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
        self._destroying = True
        if self._worker:
            self._worker.requestCancel()
        if self._thread:
            self._thread.quit()
            self._thread.wait()
            self._thread = None
            self._worker = None
        if self._runTempDir:
            shutil.rmtree(self._runTempDir, ignore_errors=True)
            self._runTempDir = None
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
        running = self._thread is not None
        ready = (bool(self._queue)
                 and bool(self.ui.condaEnvEdit.text)
                 and bool(self.ui.resultsPathEdit.text)
                 and not running)
        self.ui.runButton.enabled = ready
        self.ui.cancelButton.enabled = running
        for name in (
                "inputVolumeSelector", "addVolumeButton", "addFilesButton",
                "addFolderButton", "removeButton", "clearButton",
                "qualityComboBox", "deviceComboBox", "postprocessCheckBox",
                "autoLoadCheckBox", "condaEnvEdit", "condaEnvBrowseButton",
                "resultsPathEdit", "resultsPathBrowseButton"):
            getattr(self.ui, name).enabled = not running
        self.ui.queueTable.enabled = not running

    def onRun(self):
        if not self._queue:
            return

        conda_env      = self.ui.condaEnvEdit.text.strip()
        nnunet_results = self.ui.resultsPathEdit.text.strip()
        dataset_id     = "502"   # fixed: Dataset502, 1000 ep
        postprocess    = self.ui.postprocessCheckBox.checked
        auto_load      = self.ui.autoLoadCheckBox.checked
        quality_index  = int(self.ui.qualityComboBox.currentIndex)
        device_index   = int(self.ui.deviceComboBox.currentIndex)
        preset         = _QUALITY_VALUES[quality_index]
        device         = _DEVICE_VALUES[device_index]

        try:
            self.logic.configure(
                conda_env=conda_env,
                nnunet_results=nnunet_results,
                dataset_id=dataset_id,
                postprocess=postprocess,
                auto_load=auto_load,
                preset=preset,
                device=device,
            )
        except Exception as exc:
            slicer.util.errorDisplay(str(exc))
            return

        # Export MRML inputs on Slicer's main thread. The worker receives only
        # file paths and never mutates the MRML scene.
        self._runTempDir = tempfile.mkdtemp(prefix="slicer_vs_run_")
        worker_items = []
        try:
            for index, item in enumerate(self._queue):
                worker_item = dict(item)
                if item["type"] == "node":
                    input_path = os.path.join(
                        self._runTempDir, f"input_{index:04d}.nrrd")
                    slicer.util.exportNode(item["node"], input_path)
                    worker_item = {
                        "type": "staged_node",
                        "path": input_path,
                        "name": item["name"],
                        "ref_node_id": item["node"].GetID(),
                        "result_path": os.path.join(
                            self._runTempDir, f"result_{index:04d}.nrrd"),
                    }
                worker_items.append(worker_item)
        except Exception as exc:
            shutil.rmtree(self._runTempDir, ignore_errors=True)
            self._runTempDir = None
            slicer.util.errorDisplay(f"Could not stage the input volume:\n{exc}")
            return

        # Reset all rows to Pending
        for r in range(self.ui.queueTable.rowCount):
            self._setRowStatus(r, "pending", "")

        self.ui.logTextEdit.clear()

        self._thread = qt.QThread()
        self._worker = _SegWorker(worker_items, self.logic)
        self._worker.moveToThread(self._thread)

        self._thread.started.connect(self._worker.run)
        self._worker.itemStatusChanged.connect(self._onItemStatus)
        self._worker.itemMessage.connect(self._onItemMessage)
        self._worker.itemResultReady.connect(self._onItemResult)
        self._worker.logLine.connect(self._appendLog)
        self._worker.finished.connect(self._onWorkerFinished)
        self._worker.finished.connect(self._thread.quit)
        self._worker.finished.connect(self._worker.deleteLater)
        self._thread.finished.connect(self._thread.deleteLater)

        self._thread.start()
        self._updateRunButton()

    def onCancel(self):
        if self._worker:
            self._worker.requestCancel()
        self.ui.cancelButton.enabled = False

    def _onItemStatus(self, idx, status):
        if self._destroying:
            return
        msg = self.ui.queueTable.item(idx, 2)
        self._setRowStatus(idx, status, msg.text() if msg else "")

    def _onItemMessage(self, idx, text):
        if self._destroying:
            return
        self._setRowStatus(
            idx,
            self.ui.queueTable.item(idx, 1).text().lower(),
            text)

    def _onItemResult(self, idx, result):
        if self._destroying:
            return
        message = result.get("display_message", result.get("output_path", "done"))
        try:
            if self.logic._auto_load:
                ref_node_id = result.get("ref_node_id")
                if ref_node_id:
                    ref_node = slicer.mrmlScene.GetNodeByID(ref_node_id)
                    if ref_node is None:
                        raise RuntimeError("The reference volume was removed from the scene.")
                else:
                    ref_node = slicer.util.loadVolume(result["source_path"])
                seg_node = self.logic.importSegmentation(
                    result["seg_file"], ref_node)
                message = seg_node.GetName()
            self._setRowStatus(idx, "done", message)
        except Exception as exc:
            logging.exception(exc)
            self._appendLog(f"[ERROR] Could not load result: {exc}")
            self._setRowStatus(idx, "error", str(exc)[:120])

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
        if self._destroying:
            return
        self.ui.logTextEdit.appendPlainText(line.rstrip())
        sb = self.ui.logTextEdit.verticalScrollBar()
        sb.setValue(sb.maximum)

    def _onWorkerFinished(self):
        if self._thread:
            self._thread.quit()
            self._thread.wait()
        self._thread = None
        self._worker = None
        if self._runTempDir:
            shutil.rmtree(self._runTempDir, ignore_errors=True)
            self._runTempDir = None
        if self._destroying:
            return
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

class SlicerVSLogic(ScriptedLoadableModuleLogic):
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
        self._cancel_event = threading.Event()
        self._conda_env   = ""
        self._nnunet_results = ""
        self._dataset_id  = "502"
        self._postprocess = True
        self._auto_load   = True
        self._preset      = "accurate"
        self._device      = "auto"

    # ------------------------------------------------------------------
    def configure(self, conda_env, nnunet_results, dataset_id,
                  postprocess, auto_load, preset="accurate", device="auto"):
        if dataset_id not in self.DATASET_CONFIG:
            raise ValueError(f"Unknown dataset_id: {dataset_id}")
        if preset not in _QUALITY_VALUES:
            raise ValueError(f"Unknown inference preset: {preset}")
        if device not in _DEVICE_VALUES:
            raise ValueError(f"Unknown inference device: {device}")
        self._findPythonExe(conda_env)          # validate early
        self._findNormalizeScript()              # validate early
        if not os.path.isdir(nnunet_results):
            raise FileNotFoundError(
                f"nnUNet_results directory not found: {nnunet_results}")
        required_folds = ("2",) if preset == "fast" else ("0", "1", "2", "3", "4")
        missing_folds = [
            fold for fold in required_folds
            if not self.hasCheckpoint(nnunet_results, fold, dataset_id)
        ]
        if missing_folds:
            raise FileNotFoundError(
                "Missing checkpoint_final.pth for fold(s) {} under:\n{}\n"
                "Download and extract the model weights from the GitHub release."
                .format(", ".join(missing_folds), nnunet_results)
            )
        self._conda_env      = conda_env
        self._nnunet_results = nnunet_results
        self._dataset_id     = dataset_id
        self._postprocess    = postprocess
        self._auto_load      = auto_load
        self._preset         = preset
        self._device         = device
        self._cancel_event.clear()

    def cancelCurrent(self):
        self._cancel_event.set()
        proc = self._activeProc
        if not proc or proc.poll() is not None:
            return
        self._terminateProcess(proc)

    @staticmethod
    def _terminateProcess(proc):
        try:
            if os.name == "nt":
                result = subprocess.run(
                    ["taskkill", "/PID", str(proc.pid), "/T", "/F"],
                    stdout=subprocess.DEVNULL,
                    stderr=subprocess.DEVNULL,
                    check=False,
                    creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0),
                )
                if result.returncode != 0 and proc.poll() is None:
                    logging.warning(
                        "taskkill could not terminate inference tree (rc=%s); "
                        "killing the wrapper process.", result.returncode)
                    proc.kill()
            else:
                os.killpg(os.getpgid(proc.pid), signal.SIGTERM)
        except Exception:
            proc.kill()

    # ------------------------------------------------------------------
    def processItem(self, item, logCallback=None):
        """Process one file-only queue item and return result paths."""
        if self._cancel_event.is_set():
            raise InferenceCancelled()
        cfg         = self.DATASET_CONFIG[self._dataset_id]
        python_exe  = self._findPythonExe(self._conda_env)
        script      = self._findNormalizeScript()

        work_dir = tempfile.mkdtemp(prefix="slicer_vs_")
        try:
            if self._cancel_event.is_set():
                raise InferenceCancelled()
            self._stageInputFile(item["path"], work_dir)

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
                          os.path.join(self._conda_env, "Library", "bin"),
                          os.path.join(self._conda_env, "bin")]
            env[path_key] = os.pathsep.join(
                [p for p in extra if os.path.isdir(p)] + [env.get(path_key, "")])
            env["nnUNet_results"]      = self._nnunet_results
            env["nnUNet_raw"]          = ""
            env["nnUNet_preprocessed"] = ""
            env["nnUNet_n_proc_DA"]    = "1"
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
                "--preset",       self._preset,
                "--device",       self._device,
                "--postprocess" if self._postprocess else "--no-postprocess",
            ]
            if logCallback:
                logCallback("Running: " + " ".join(cmd))

            process_options = {}
            if os.name == "nt":
                process_options["creationflags"] = getattr(
                    subprocess, "CREATE_NEW_PROCESS_GROUP", 0)
            else:
                process_options["start_new_session"] = True
            proc = subprocess.Popen(
                cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                text=True, encoding="utf-8", errors="replace", env=env,
                **process_options,
            )
            self._activeProc = proc
            if self._cancel_event.is_set():
                self._terminateProcess(proc)
                raise InferenceCancelled()
            output_lines = []
            try:
                for line in proc.stdout:
                    output_lines.append(line)
                    if "[BACKEND_FALLBACK]" in line:
                        # Do not retry a known-broken DirectML runtime for
                        # every remaining item in the same queue.
                        self._device = "cpu"
                    if logCallback:
                        logCallback(line.rstrip())
                proc.wait()
                rc = proc.returncode
            finally:
                self._activeProc = None

            if rc != 0:
                tail = "".join(output_lines[-30:])
                raise RuntimeError(
                    f"Inference failed (rc={rc}):\n{tail}")
            if self._cancel_event.is_set():
                raise InferenceCancelled()

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

            # Keep the result outside work_dir before its cleanup. File inputs
            # are written beside the source; staged scene inputs use runTempDir.
            if item["type"] == "file":
                orig_dir  = os.path.dirname(item["path"])
                base, _   = self._splitMedicalExtension(
                    os.path.basename(item["path"]))
                out_path  = os.path.join(orig_dir, base + "_seg.nrrd")
            else:
                out_path = item["result_path"]
            shutil.copy2(seg_file, out_path)
            if logCallback:
                logCallback(f"  Saved: {out_path}")

            return {
                "seg_file": out_path,
                "output_path": out_path,
                "display_message": (
                    out_path if item["type"] == "file" else "done (not loaded)"
                ),
                "source_path": item["path"],
                "ref_node_id": item.get("ref_node_id"),
            }

        finally:
            shutil.rmtree(work_dir, ignore_errors=True)

    # ------------------------------------------------------------------
    @staticmethod
    def _splitMedicalExtension(filename):
        lower = filename.lower()
        for extension in (".nii.gz", ".nrrd", ".nii", ".mha", ".mhd"):
            if lower.endswith(extension):
                return filename[:-len(extension)], filename[-len(extension):]
        return os.path.splitext(filename)

    def _stageInputFile(self, source, work_dir):
        """Copy one input into the isolated work folder, including MHD data."""
        _, extension = self._splitMedicalExtension(source)
        destination = os.path.join(work_dir, "input" + extension)
        if extension.lower() != ".mhd":
            shutil.copy2(source, destination)
            return destination

        with open(source, "r", encoding="latin-1") as stream:
            header = stream.read()
        match = re.search(
            r"(?im)^(\s*ElementDataFile\s*=\s*)(.+?)\s*$", header)
        if not match:
            raise ValueError(f"Invalid MHD header (ElementDataFile missing): {source}")

        data_reference = match.group(2).strip().strip('"')
        upper_reference = data_reference.upper()
        if upper_reference == "LOCAL":
            shutil.copy2(source, destination)
            return destination
        if upper_reference.startswith("LIST") or "%" in data_reference:
            raise ValueError(
                "MHD LIST/pattern sidecars are not supported. Convert this "
                "image to .mha, .nrrd, or .nii.gz before inference.")

        data_source = data_reference
        if not os.path.isabs(data_source):
            data_source = os.path.join(os.path.dirname(source), data_source)
        if not os.path.isfile(data_source):
            raise FileNotFoundError(
                f"MHD sidecar file not found: {data_source}")

        _, data_extension = os.path.splitext(data_source)
        data_name = "input" + (data_extension or ".raw")
        shutil.copy2(data_source, os.path.join(work_dir, data_name))
        staged_header = header[:match.start(2)] + data_name + header[match.end(2):]
        with open(destination, "w", encoding="latin-1", newline="") as stream:
            stream.write(staged_header)
        return destination

    @classmethod
    def hasCheckpoint(cls, results_root, fold, dataset_id="502"):
        cfg = cls.DATASET_CONFIG[dataset_id]
        checkpoint = os.path.join(
            results_root,
            cfg["name"],
            f'{cfg["trainer"]}__nnUNetPlans__3d_fullres',
            f"fold_{fold}",
            "checkpoint_final.pth",
        )
        return os.path.isfile(checkpoint)

    @staticmethod
    def _findPythonCandidate(conda_env):
        for relative_path in ("python.exe", "python", os.path.join("bin", "python")):
            candidate = os.path.join(conda_env, relative_path)
            if os.path.isfile(candidate):
                return candidate
        return ""

    def _findPythonExe(self, conda_env):
        candidate = self._findPythonCandidate(conda_env)
        if candidate:
            return candidate
        raise FileNotFoundError(
            f"Python executable not found in: {conda_env}\n"
            "Please verify the vs_seg environment path.")

    def _findNormalizeScript(self):
        # 1) Explicit override always wins.
        override = (os.environ.get("SLICERVS_SCRIPT_PATH")
                    or os.environ.get("VSSEG_SCRIPT_PATH"))
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
            "Set the SLICERVS_SCRIPT_PATH environment variable to its location."
            " (VSSEG_SCRIPT_PATH is also accepted for compatibility.)")

    def importSegmentation(self, seg_file, ref_node):
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
