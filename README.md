# SlicerVS — a 3D Slicer extension for vestibular schwannoma segmentation

Automatic segmentation of **vestibular schwannoma (VS)** on contrast-enhanced
T1 (ceT1) MRI, built on [nnU-Net v2](https://github.com/MIC-DKFZ/nnUNet) and
integrated into [3D Slicer](https://www.slicer.org/) as a scripted module.

- **Normalization**: 0.5th-99.9th percentile intensity clipping (matches the
  preprocessing used to train the model)
- **Inference**: nnU-Net v2 `3d_fullres`, with fast single-fold and accurate
  5-fold modes
- **Model**: Dataset502 (1000 epochs) — trained on
  [CrossMoDA](https://crossmoda-challenge.ml/) ceT1 data plus additional
  cystic-tumor / varied-spacing cases (215 cases total)
- Automatic CUDA/ROCm/MPS/DirectML selection with a reliable CPU fallback and
  low-VRAM handling
- Batch queue with per-item progress, process-tree cancellation, and optional
  auto-load of results into the Slicer scene

**Pretrained weights** (Dataset502, 1000 ep) are available on the
[Releases page](https://github.com/Sarcasmjoker/3dSlicer_VS_Segmentation/releases)
as `Dataset502_VSmix_checkpoints.zip`. See [Model weights](#model-weights)
for installation instructions.

---

## Contents

- [Minimum hardware requirements](#minimum-hardware-requirements)
- [Inference backends and quality modes](#inference-backends-and-quality-modes)
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

Accurate inference runs nnU-Net's 5-fold `3d_fullres` ensemble and is
compute-intensive. Fast mode reduces that workload substantially.

| Resource | Minimum | Notes |
|---|---|---|
| **GPU** | Optional; **10 GB VRAM recommended** for accurate mode | NVIDIA CUDA and Linux AMD ROCm use nnU-Net's native GPU path. DirectML is experimental on Windows AMD/Intel adapters. CUDA/ROCm devices below 10 GB automatically keep sliding-window accumulators on CPU. |
| **RAM** | ≥ 16 GB recommended | Slicer, the vs_seg subprocess, and image I/O run concurrently. Inference is far lighter than training, but headroom avoids memory pressure on typical Windows systems. |
| **CPU** | Any modern x86-64 CPU; 16 GB RAM recommended | CPU inference completed the normalization, real Dataset502 prediction, and export smoke pipeline. It is substantially slower than GPU inference, especially in accurate mode. |
| **Disk** | ~3-8 GB for the environment, depending on backend, plus ~235 MB per fold checkpoint | Accurate mode requires all five checkpoints; fast mode requires fold 2. |
| **OS** | Windows 11 recommended | The one-click installer targets Windows. The subprocess launcher also supports conventional Linux/macOS conda layouts, but those platforms require manual environment setup. |

## Inference backends and quality modes

### Compute backends

| UI choice | Behavior |
|---|---|
| **Auto** | Uses CUDA (NVIDIA or AMD ROCm) first, then Apple MPS, installed DirectML, then CPU. The selected backend is printed in the log. |
| **GPU (NVIDIA CUDA / AMD ROCm)** | Requires a compatible GPU-enabled PyTorch environment and fails clearly if the GPU is unavailable. |
| **CPU** | Works on all supported PCs, including systems with unsupported AMD/Intel integrated graphics. |
| **Apple GPU (MPS)** | Uses PyTorch MPS on supported Apple Silicon environments; not available on Windows. |
| **DirectML (experimental)** | Tries the nnU-Net Python API on a DirectML-compatible Windows adapter. Any unsupported operator automatically retries the complete case on CPU. |

ROCm exposes supported AMD devices through PyTorch's `torch.cuda` API, so
nnU-Net receives `-device cuda` for both NVIDIA and AMD GPUs. Native AMD ROCm
on Linux is supported through `environment-amd-linux.yml`. AMD's current native
Windows ROCm 7.2.1 wheel requires PyTorch 2.9.1, while nnU-Net 2.8.1 explicitly
excludes PyTorch 2.9.x; SlicerVS therefore does not publish that conflicting
combination as a stable environment. Windows AMD/Intel users can use the
experimental DirectML environment or the reliable CPU environment. Intel XPU
is not accepted by the nnU-Net 2.8.1 CLI. See Microsoft's
[PyTorch with DirectML guide](https://learn.microsoft.com/windows/ai/directml/pytorch-windows)
for the underlying Windows backend.

### Quality modes

| Mode | nnU-Net settings | Intended use |
|---|---|---|
| **Fast** | fold 2, `step_size=0.75`, TTA disabled | Interactive review, CPU/iGPU fallback, or time-sensitive batches |
| **Accurate** | folds 0-4, `step_size=0.5`, mirror TTA enabled | Final results when runtime is less important |

These are speed/accuracy presets, not INT8/FP16 quantization modes. They use
nnU-Net's validated inference path; on CUDA/ROCm, nnU-Net applies its standard
automatic mixed precision internally. Post-processing remains independently
controllable in both modes. Fold 2 is the provisional single-fold choice based
on the recorded cross-validation scores; because each fold used a different
validation subset, fast-mode accuracy should still be confirmed on the target
site's held-out data.

---

## Quick start (one-click installer)

> **No programming experience required.** The installer handles everything
> automatically.

**Prerequisites (required before running the installer):**

1. A 64-bit Windows PC. A compatible NVIDIA/AMD GPU is optional; every system
   can use CPU inference (see
   [Inference backends and quality modes](#inference-backends-and-quality-modes)).
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
   - Ask you to choose NVIDIA CUDA, experimental DirectML, or portable CPU.
   - Create a dedicated `vs_seg` Python environment with the matching PyTorch,
     nnU-Net v2, SimpleITK, and NumPy packages.
   - Run a compute self-test and report the GPU backend or CPU fallback.
   - Print the exact folder path to paste into the extension's
     **"vs_seg env directory"** field in Slicer.
4. **Register the extension in Slicer** (see
   [Installing the extension in Slicer](#installing-the-extension-in-slicer)).

> **Slow or blocked internet?** The installer will ask if you want to use a
> mirror (e.g. Aliyun for mainland China networks). Just answer `y` and press
> Enter when prompted.

---

## Manual environment setup

Choose exactly one environment file for the target backend:

```bash
# NVIDIA CUDA 12.8
conda env create -f environment.yml

# Portable CPU (AMD/Intel/NVIDIA systems, no supported GPU required)
conda env create -f environment-cpu.yml

# Experimental DirectML on Windows AMD/Intel/NVIDIA adapters
conda env create -f environment-directml.yml

# Native AMD ROCm on Linux
conda env create -f environment-amd-linux.yml

# Apple Silicon (MPS with CPU fallback)
conda env create -f environment-macos.yml
```

Then verify the environment:

```bash
conda activate vs_seg
python -c "import torch; print(torch.__version__); print('GPU:', torch.cuda.is_available()); print(torch.cuda.get_device_name(0) if torch.cuda.is_available() else 'CPU fallback')"
```

For Apple MPS use:

```bash
python -c "import torch; print(torch.backends.mps.is_available())"
```

For DirectML use:

```bash
python -c "import torch, torch_directml; d=torch_directml.device(); print(d); print((torch.tensor([1]).to(d)+torch.tensor([2]).to(d)).to('cpu').item())"
```

For Linux ROCm, confirm that ROCm 6.4 matches the installed driver and GPU; if
not, create an equivalent environment with the PyTorch build recommended by
AMD. The plugin identifies ROCm automatically. The DirectML environment uses
Microsoft's documented PyTorch 2.3.1 ceiling and is deliberately isolated from
the CUDA/ROCm environments.

CUDA, ROCm, DirectML, macOS, and CPU PyTorch builds should not be mixed. When
changing backend, remove/re-create `vs_seg` or use a separate conda environment
and point the plugin to that environment directory.

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
   <repo>\SlicerVS
   ```
7. Click **OK**; Slicer will prompt for a restart.
8. After restarting, search for `SlicerVS` in the module finder, or
   find it under **Segmentation → SlicerVS**.
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
2. **Choose inference settings**:
   - `Inference quality`: Fast for responsiveness or Accurate for the full
     five-fold/TTA pipeline
   - `Compute device`: Auto is recommended; choose CPU to force the portable
     path, GPU to require CUDA/ROCm, or DirectML for the experimental path
   - `Post-processing`: enabled by default and now honored by the inference
     wrapper
3. **Set the environment paths** (first run only — auto-filled if loading
   from the cloned repo with weights already placed in `models/`):
   - `vs_seg env directory`: the conda environment root, e.g.
     `C:\Users\you\.conda\envs\vs_seg`
   - `nnUNet_results directory`: the `models/` folder inside your clone
     (auto-detected when the extension loads from the repo)
4. **Click "▶ Run segmentation"**. Each queued item is processed in turn;
   the queue table shows live status per item (Pending → Running → Done /
   Error / Cancelled), with a scrollable log panel below for details.
5. **Click "■ Cancel"** to terminate the active wrapper and its nnU-Net
   child process; remaining queued items are marked Cancelled without running.
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
Slicer main thread (export MRML input to a temporary file)
      │
Slicer QThread worker (subprocess.Popen)
      ▼
vs_seg Python (torch + nnunetv2)
  normalize_and_predict.py:
    normalize -> select backend/profile -> nnU-Net CLI/Python API -> optional postprocess -> write <name>_seg.nrrd
      │
      ▼
Slicer main thread (load segmentation nrrd -> vtkMRMLSegmentationNode)
```

The bundled script, `SlicerVS/Resources/Scripts/normalize_and_predict.py`,
is self-contained and uses the PyTorch, nnU-Net, NumPy, and SimpleITK packages
from the selected `vs_seg` environment.

File/subprocess work runs in a background `QThread` so the Slicer UI stays
responsive. All MRML/VTK scene operations remain on Slicer's main thread, and
cancellation terminates the active process tree.

---

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `Python executable not found in: ...` | Wrong conda environment path | Verify the `vs_seg env directory` points at the environment root (containing `python.exe` on Windows or `python` on Linux/macOS) |
| `CUDA/ROCm was requested ... unavailable` | The selected environment does not support the installed GPU | Use Auto/CPU, or re-create `vs_seg` from the matching NVIDIA CUDA or Linux AMD ROCm environment file |
| AMD/Intel adapter is present but Auto selects CPU | DirectML is not installed/available, or ROCm is unavailable | Use the experimental DirectML environment on Windows, a compatible ROCm environment on Linux, or the reliable CPU path |
| DirectML fails during prediction | One or more nnU-Net operators are unsupported by the adapter/runtime | No action is required: the wrapper logs the error and retries the complete case on CPU |
| `Inference failed (rc=1)` | Model, input, or compute-environment issue | Expand the Log panel and inspect the final subprocess lines |
| `normalize_and_predict.py not found` | Extension files were only partially copied, or `SLICERVS_SCRIPT_PATH` points somewhere invalid | Re-check the repo layout; `Resources/Scripts/normalize_and_predict.py` should exist next to `SlicerVS.py` |
| `'utf-8' codec can't decode byte ...` | Fixed in this version — the subprocess environment now forces `PYTHONIOENCODING=utf-8` regardless of the Windows console code page | Update to the latest version if you still see this |
| Log full of `Possible incompatible factory load` / `Error ImageIO factory did not return an ImageIOBase: MRMLIDImageIO` | Harmless noise from earlier versions: Slicer's `ITK_AUTOLOAD_PATH` environment variable was leaking into the `vs_seg` subprocess, causing its own SimpleITK/ITK build to attempt (and fail) to load Slicer's ITK factory plugins | Fixed in this version — the subprocess environment now strips `ITK_AUTOLOAD_PATH`/`QT_PLUGIN_PATH`/`SLICER_HOME` before launching |
| Empty segmentation mask | Input isn't a ceT1 sequence, or intensities are unusual | Confirm the input is a contrast-enhanced T1 series |
| `CUDA out of memory` / `HIP out of memory` | The case exceeds available GPU memory even after automatic low-VRAM handling | Try Fast mode, force CPU, and close other GPU-heavy applications |

---

## License

Licensed under the **GNU General Public License v3.0** — see [LICENSE](LICENSE).

Built on [nnU-Net v2](https://github.com/MIC-DKFZ/nnUNet):

> Isensee, F., Jaeger, P. F., Kohl, S. A., Petersen, J., & Maier-Hein, K. H.
> (2021). nnU-Net: a self-configuring method for deep learning-based
> biomedical image segmentation. *Nature Methods*, 18(2), 203-211.
