# VS Segmentation — a 3D Slicer extension for vestibular schwannoma segmentation

Automatic segmentation of **vestibular schwannoma (VS)** on contrast-enhanced
T1 (ceT1) MRI, built on [nnU-Net v2](https://github.com/MIC-DKFZ/nnUNet) and
integrated into [3D Slicer](https://www.slicer.org/) as a scripted module.

- **Normalization**: 0.5th-99.9th percentile intensity clipping (matches the
  preprocessing used to train the models)
- **Inference**: nnU-Net v2, 5-fold ensemble, `3d_fullres`
- **Two selectable models**:
  - **Dataset502 (1000 epochs, recommended)** — trained on
    [CrossMoDA](https://crossmoda-challenge.ml/) ceT1 data plus additional
    cystic-tumor / varied-spacing cases (215 cases total)
  - **Dataset501 (250 epochs)** — trained on CrossMoDA ceT1 data only
    (154 cases)
- Batch queue with per-item progress, cancellation, and optional auto-load
  of results into the Slicer scene

This repository contains the **extension only**. Pretrained model weights
are **not** included — see [Model weights](#model-weights) below.

---

## Contents

- [Minimum hardware requirements](#minimum-hardware-requirements)
- [Prerequisites](#prerequisites)
- [Setting up the vs_seg environment](#setting-up-the-vs_seg-environment)
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

## Prerequisites

1. [3D Slicer](https://download.slicer.org/) ≥ 5.0
2. [Miniforge](https://github.com/conda-forge/miniforge) or another conda
   distribution, for the separate `vs_seg` Python environment (see below —
   this is **not** the same Python that ships inside Slicer)
3. A set of trained nnU-Net v2 model weights (see [Model weights](#model-weights))

## Setting up the vs_seg environment

3D Slicer embeds its own Python, which cannot `import torch`/`nnunetv2`
directly (see [Architecture](#architecture-why-a-subprocess)). This
extension instead calls out to a separate conda environment. Create it once:

```bash
conda env create -f environment.yml
conda activate vs_seg
```

Then verify GPU access:

```bash
python -c "import torch; print(torch.__version__, torch.cuda.is_available(), torch.cuda.get_device_name(0))"
```

Expected: `True` and your GPU's name. If `torch.cuda.is_available()` is
`False`, the most common cause is a torchvision/timm dependency silently
pulling in a CPU-only torch build — see the comments in `environment.yml`
and reinstall the pinned CUDA wheels together with `nnunetv2` in one `pip`
command.

## Model weights

**This repository ships code only — no pretrained weights.** nnU-Net
checkpoints are large binary files (~235 MB per fold, 5 folds per model)
that don't belong in a source-code repository.

To use this extension you need an `nnUNet_results` directory containing a
model trained with standard nnU-Net v2 tooling (`nnUNetv2_train`) on ceT1
VS-segmentation data, with the folder layout nnU-Net produces by default, e.g.:

```
nnUNet_results/
└── Dataset502_VSmix/
    └── nnUNetTrainer__nnUNetPlans__3d_fullres/
        ├── fold_0/checkpoint_final.pth
        ├── fold_1/ ... fold_4/
        └── crossval_results_folds_0_1_2_3_4/
            ├── postprocessing.pkl
            └── plans.json
```

See the [nnU-Net v2 documentation](https://github.com/MIC-DKFZ/nnUNet) for
the full training pipeline (data conversion, preprocessing, training,
`nnUNetv2_find_best_configuration`). If you'd like to reproduce the
Dataset501/Dataset502 models referenced in this UI, train on CrossMoDA ceT1
data (label 1 = tumor) with `3d_fullres`, 5-fold cross-validation.

## Installing the extension in Slicer

1. Clone or download this repository.
2. Open 3D Slicer.
3. **Edit → Application Settings → Modules**.
4. Under **Additional module paths**, click **Add** and select:
   ```
   <repo>/VSSegmentation
   ```
5. Click **OK**; Slicer will prompt for a restart.
6. After restarting, search for `VS Segmentation` in the module finder, or
   find it under **Segmentation → VS Segmentation**.

---

## Usage

1. **Add images to the queue** — three ways to add input:
   - **Add to queue**: pick a volume already loaded in the Slicer scene
     from the dropdown, then click "Add to queue"
   - **Add files…**: select one or more `.nrrd` / `.nii.gz` / `.nii` /
     `.mha` / `.mhd` files from disk
   - **Add folder…**: add every supported image file found in a folder
2. **Choose a model** — Dataset502 (1000 ep) is recommended by default;
   switch to Dataset501 (250 ep) if you specifically want the model trained
   on CrossMoDA data only.
3. **Set the environment paths** (first run only — remembered afterwards):
   - `vs_seg env directory`: the conda environment root, e.g.
     `C:\Users\you\.conda\envs\vs_seg`
   - `nnUNet_results directory`: path to your trained model weights
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
