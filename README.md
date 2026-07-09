# VS Segmentation — a 3D Slicer extension for vestibular schwannoma segmentation

Automatic segmentation of **vestibular schwannoma (VS)** on contrast-enhanced
T1 (ceT1) MRI, built on [nnU-Net v2](https://github.com/MIC-DKFZ/nnUNet) and
integrated into [3D Slicer](https://www.slicer.org/) as a scripted module.

- **Normalization**: 0.5th-99.9th percentile intensity clipping (matches the
  preprocessing used to train the model)
- **Inference**: nnU-Net v2, 5-fold ensemble, `3d_fullres`
- **Model**: Dataset502 (1000 epochs) — trained on
  [CrossMoDA](https://crossmoda-challenge.ml/) ceT1 data plus additional
  cystic-tumor / varied-spacing cases (215 cases total)
- Batch queue with per-item progress, cancellation, and optional auto-load
  of results into the Slicer scene

**Pretrained weights** (Dataset502, 1000 ep) are available on the
[Releases page](https://github.com/Sarcasmjoker/3dSlicer_VS_Segmentation/releases)
as `Dataset502_VSmix_checkpoints.zip`. See [Model weights](#model-weights)
for installation instructions.

---

## Contents

- [Minimum hardware requirements](#minimum-hardware-requirements)
- [Quick start (one-click installer)](#quick-start-one-click-installer)
- [Manual environment setup](#manual-environment-setup)
- [Model weights](#model-weights)
- [Installing the extension in Slicer](#installing-the-extension-in-slicer)
- [Usage](#usage)
- [Architecture](#architecture-why-a-subprocess)
- [Troubleshooting](#troubleshooting)
- [License](#license)

---

## Minimum hardware requirements

Inference runs nnU-Net's 5-fold `3d_fullres` ensemble, which is
compute-intensive. Please read this section before installing.

| Resource | Minimum | Notes |
|---|---|---|
| **GPU** | NVIDIA CUDA-capable GPU, **≥ 8 GB VRAM recommended** | The 5-fold ensemble loads a model and 3D patches per fold; less VRAM risks `CUDA out of memory`. Developed and validated on an RTX 5060 Ti (16 GB). CPU-only inference is *theoretically* possible (nnU-Net supports it) but **has not been tested** with this extension and will be substantially slower — plan for many times longer per case. Treat CPU inference as unverified, not a supported configuration. |
| **RAM** | ≥ 16 GB recommended | Slicer, the vs_seg subprocess, and image I/O run concurrently. Inference is far lighter than training, but headroom avoids memory pressure on typical Windows systems. |
| **Disk** | ~6-8 GB for the conda environment (PyTorch + CUDA runtime) + ~235 MB per fold checkpoint per model (5 folds/model) | |
| **OS** | Verified on **Windows** | The subprocess launcher assumes Windows-style paths (`python.exe`, a `Scripts\` directory). It has **not** been tested on macOS/Linux; adapting `_findPythonExe()` in `VSSegmentation.py` would be required there. |

---

## Quick start (one-click installer)

> **No programming experience required.** The installer handles everything
> automatically.

**Prerequisites (required before running the installer):**

1. A 64-bit Windows PC with an NVIDIA GPU (≥ 8 GB VRAM recommended — see
   [Minimum hardware requirements](#minimum-hardware-requirements))
2. [3D Slicer](https://download.slicer.org/) ≥ 5.0 installed
3. An internet connection for the first-time package download (~4-6 GB)

**Steps:**

1. **Clone or download this repository** (green "Code" button → "Download ZIP",
   then extract to a folder such as `C:\VS_Segmentation`).
2. **Download the pretrained weights** from the
   [Releases page](https://github.com/Sarcasmjoker/3dSlicer_VS_Segmentation/releases)
   (`Dataset502_VSmix_checkpoints.zip`) and extract the five `.pth` files into
   the matching `models/` subdirectories (see [Model weights](#model-weights)).
3. **Double-click `scripts\install_vs_seg.bat`** in the repository folder.
   The installer will:
   - Download and silently install
     [Miniforge](https://github.com/conda-forge/miniforge) (a free, minimal
     Python distribution) into your user folder — **no administrator rights
     needed** and your existing Python/software is not affected.
   - Create a dedicated `vs_seg` Python environment with all required packages
     (PyTorch with CUDA, nnU-Net v2, SimpleITK, etc.).
   - Run a GPU self-test and print a clear **PASS / FAIL** result.
   - Print the exact folder path to paste into the extension's
     **"vs_seg env directory"** field in Slicer.
4. **Register the extension in Slicer** (see
   [Installing the extension in Slicer](#installing-the-extension-in-slicer)).

> **Slow or blocked internet?** The installer will ask if you want to use a
> mirror (e.g. Aliyun for mainland China networks). Just answer `y` and press
> Enter when prompted.

---

## Manual environment setup

If you prefer to set up the environment manually (e.g. on macOS/Linux, or
if you already have conda installed), run:

```bash
conda env create -f environment.yml
conda activate vs_seg
python -c "import torch; print(torch.__version__, torch.cuda.is_available(), torch.cuda.get_device_name(0))"
```

Expected output: `True` followed by your GPU's name. If
`torch.cuda.is_available()` returns `False`, the most common cause is a
dependency silently replacing the CUDA-enabled torch with a CPU-only build.
See the comments in `environment.yml` and reinstall the pinned CUDA wheels
together with `nnunetv2` in a single `pip` command.

## Model weights

The pretrained Dataset502 (1000 epochs) checkpoint weights are provided via
**GitHub Releases** because each fold's `.pth` file is ~235 MB and GitHub's
100 MB per-file limit prevents committing them directly.

### Download and install

1. Go to the [Releases page](https://github.com/Sarcasmjoker/3dSlicer_VS_Segmentation/releases)
   and download `Dataset502_VSmix_checkpoints.zip`.
2. Extract the zip. You will get five `checkpoint_final.pth` files, one per
   fold.
3. Place each file in the matching `models/` subdirectory of your local clone:

```
3dSlicer_VS_Segmentation/
└── models/
    └── Dataset502_VSmix/
        └── nnUNetTrainer__nnUNetPlans__3d_fullres/
            ├── fold_0/checkpoint_final.pth    ← put here
            ├── fold_1/checkpoint_final.pth
            ├── fold_2/checkpoint_final.pth
            ├── fold_3/checkpoint_final.pth
            └── fold_4/checkpoint_final.pth
```

4. In the Slicer extension, set the **nnUNet_results directory** field to
   the `models/` folder inside your clone, e.g.:
   ```
   C:\Users\you\3dSlicer_VS_Segmentation\models
   ```

The small configuration files (`plans.json`, `postprocessing.pkl`,
`nnUNetPlans.json`) are already included in the repository under `models/`,
so only the `.pth` checkpoint files need to be downloaded separately.

### Model performance (Dataset502, 1000 epochs)

Trained on **215 cases** (CrossMoDA ceT1 + additional cystic/varied-spacing
cases), evaluated on a held-out test set of 36 cases:

| Subset | n | Dice mean | Dice median | ASSD median |
|---|---|---|---|---|
| Overall | 36 | 0.941 | 0.946 | 0.126 mm |
| CrossMoDA subset | 27 | 0.943 | 0.950 | 0.098 mm |
| Cystic/new data subset | 9 | 0.937 | 0.942 | 0.230 mm |

### Training from scratch

If you prefer to train your own model, see the
[nnU-Net v2 documentation](https://github.com/MIC-DKFZ/nnUNet) for the full
pipeline. Train on ceT1 VS data (label 1 = tumor, label 0 = background)
with `3d_fullres`, 5-fold cross-validation, and point the
`nnUNet_results directory` in the extension to your own output directory.

## Installing the extension in Slicer

1. Clone or download this repository (if you haven't already — the one-click
   installer also needs this folder).
2. Download `Dataset502_VSmix_checkpoints.zip` from the
   [Releases page](https://github.com/Sarcasmjoker/3dSlicer_VS_Segmentation/releases)
   and extract the five `checkpoint_final.pth` files into the matching
   `models/` subdirectories (see [Model weights](#model-weights)).
3. **Run `scripts\install_vs_seg.bat`** (double-click) to set up Python — or
   follow the [Manual environment setup](#manual-environment-setup) if you
   prefer the command line.
4. Open 3D Slicer.
5. **Edit → Application Settings → Modules**.
6. Under **Additional module paths**, click **Add** and select:
   ```
   <repo>\VSSegmentation
   ```
7. Click **OK**; Slicer will prompt for a restart.
8. After restarting, search for `VS Segmentation` in the module finder, or
   find it under **Segmentation → VS Segmentation**.
9. In the **"vs_seg env directory"** field, paste the path printed by the
   installer at the end of step 3.

> **Tip**: The extension automatically detects the `models/` folder inside
> the cloned repository and pre-fills the `nnUNet_results directory` field.
> As long as you extracted the checkpoints into `models/` (step 2), no
> manual path configuration is needed for the weights.

---

## Usage

1. **Add images to the queue** — three ways to add input:
   - **Add to queue**: pick a volume already loaded in the Slicer scene
     from the dropdown, then click "Add to queue"
   - **Add files…**: select one or more `.nrrd` / `.nii.gz` / `.nii` /
     `.mha` / `.mhd` files from disk
   - **Add folder…**: add every supported image file found in a folder
2. **Choose a model** — Dataset502 (1000 ep) is the only bundled model.
3. **Set the environment paths** (first run only — auto-filled if loading
   from the cloned repo with weights already placed in `models/`):
   - `vs_seg env directory`: the conda environment root, e.g.
     `C:\Users\you\.conda\envs\vs_seg`
   - `nnUNet_results directory`: the `models/` folder inside your clone
     (auto-detected when the extension loads from the repo)
4. **Click "▶ Run segmentation"**. Each queued item is processed in turn;
   the queue table shows live status per item (Pending → Running → Done /
   Error / Cancelled), with a scrollable log panel below for details.
5. **Click "■ Cancel"** at any time to stop after the current item
   finishes — remaining queued items are marked Cancelled without running.
6. For file/folder inputs, the resulting segmentation is always written
   back next to the original image as `<name>_seg.nrrd`, regardless of the
   "Auto-load results into Slicer scene" setting. Uncheck that option for
   large batches to avoid accumulating many segmentation nodes in memory.

Completed results appear as `<name>_VS_segmentation` nodes in the scene
(red mask, tumor = 1, background = 0), and the layout automatically
switches to a four-up view once the queue finishes.

---

## Architecture (why a subprocess)

3D Slicer embeds its own Python interpreter, which does not have `torch` or
`nnunetv2` installed and is not meant to. Rather than trying to install
PyTorch/CUDA into Slicer's own Python, this extension shells out to the
separate `vs_seg` conda environment for the actual inference, then imports
the result back into the scene:

```
Slicer Python (UI, QThread worker)
      │  subprocess.Popen(...)
      ▼
vs_seg Python (torch + nnunetv2)
  normalize_and_predict.py:
    normalize -> nnUNetv2_predict (5-fold ensemble) -> postprocess -> write <name>_seg.nrrd
      │
      ▼
Slicer Python (load segmentation nrrd -> vtkMRMLSegmentationNode)
```

The bundled script, `VSSegmentation/Resources/Scripts/normalize_and_predict.py`,
is self-contained — it only depends on `numpy` and `SimpleITK`, both
present in the `vs_seg` environment.

Inference runs in a background `QThread` so the Slicer UI stays responsive;
cancellation kills the active subprocess.

---

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `python.exe not found in: ...` | Wrong conda environment path | Verify the `vs_seg env directory` field points at the environment root (containing `python.exe`) |
| `Inference failed (rc=1)` | GPU/environment issue | Expand the "Log" panel to see the subprocess's stderr tail |
| `normalize_and_predict.py not found` | Extension files were only partially copied, or `VSSEG_SCRIPT_PATH` points somewhere invalid | Re-check the repo layout; `Resources/Scripts/normalize_and_predict.py` should exist next to `VSSegmentation.py` |
| `'utf-8' codec can't decode byte ...` | Fixed in this version — the subprocess environment now forces `PYTHONIOENCODING=utf-8` regardless of the Windows console code page | Update to the latest version if you still see this |
| Log full of `Possible incompatible factory load` / `Error ImageIO factory did not return an ImageIOBase: MRMLIDImageIO` | Harmless noise from earlier versions: Slicer's `ITK_AUTOLOAD_PATH` environment variable was leaking into the `vs_seg` subprocess, causing its own SimpleITK/ITK build to attempt (and fail) to load Slicer's ITK factory plugins | Fixed in this version — the subprocess environment now strips `ITK_AUTOLOAD_PATH`/`QT_PLUGIN_PATH`/`SLICER_HOME` before launching |
| Empty segmentation mask | Input isn't a ceT1 sequence, or intensities are unusual | Confirm the input is a contrast-enhanced T1 series |
| `CUDA out of memory` | Insufficient VRAM for the 5-fold ensemble | See [Minimum hardware requirements](#minimum-hardware-requirements); no workaround is provided by this extension today |

---

## License

Licensed under the **GNU General Public License v3.0** — see [LICENSE](LICENSE).

Built on [nnU-Net v2](https://github.com/MIC-DKFZ/nnUNet):

> Isensee, F., Jaeger, P. F., Kohl, S. A., Petersen, J., & Maier-Hein, K. H.
> (2021). nnU-Net: a self-configuring method for deep learning-based
> biomedical image segmentation. *Nature Methods*, 18(2), 203-211.
