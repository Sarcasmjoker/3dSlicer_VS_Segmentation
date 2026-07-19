#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""Normalize ceT1 images and run a trained nnU-Net v2 model."""

import argparse
import importlib.util
import multiprocessing
import os
import platform
import shutil
import subprocess
import sys
import tempfile

import numpy as np
import SimpleITK as sitk

try:
    sys.stdout.reconfigure(encoding="utf-8", line_buffering=True)
    sys.stderr.reconfigure(encoding="utf-8", line_buffering=True)
except Exception:
    pass


ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SUPPORTED_EXTS = (".nii.gz", ".nrrd", ".nii", ".mha", ".mhd")
LOW_VRAM_THRESHOLD_BYTES = 10 * 1024**3

# These are speed/accuracy profiles, not numerical quantization modes.
INFERENCE_PRESETS = {
    "fast": {
        "folds": ("2",),
        "step_size": 0.75,
        "disable_tta": True,
    },
    "accurate": {
        "folds": ("0", "1", "2", "3", "4"),
        "step_size": 0.5,
        "disable_tta": False,
    },
}


def split_stem(filename):
    """Split a supported filename into (stem, extension)."""
    lower = filename.lower()
    for ext in SUPPORTED_EXTS:
        if lower.endswith(ext):
            return filename[:-len(ext)], filename[-len(ext):]
    return os.path.splitext(filename)


def normalize(img, lo_pct=0.5, hi_pct=99.9):
    """Apply percentile clipping and preserve the source geometry."""
    array = sitk.GetArrayFromImage(img).astype(np.float32)
    lo, hi = np.percentile(array, lo_pct), np.percentile(array, hi_pct)
    output = sitk.GetImageFromArray(np.clip(array, lo, hi))
    output.CopyInformation(img)
    return output


def _mps_available(torch_module):
    try:
        return bool(torch_module.backends.mps.is_available())
    except (AttributeError, RuntimeError):
        return False


def _directml_available():
    try:
        module_spec = importlib.util.find_spec("torch_directml")
    except (ImportError, AttributeError, ValueError):
        return False
    return module_spec is not None


def resolve_device(requested, torch_module=None):
    """Resolve a requested project backend to a native or experimental path."""
    if torch_module is None:
        try:
            import torch as torch_module
        except ImportError as exc:
            raise RuntimeError(
                "PyTorch is not installed in the selected environment."
            ) from exc

    cuda_available = bool(torch_module.cuda.is_available())
    mps_available = _mps_available(torch_module)
    directml_available = False
    if requested == "dml" or (
            requested == "auto" and not cuda_available and not mps_available):
        directml_available = _directml_available()

    if requested == "auto":
        device = (
            "cuda" if cuda_available else
            "mps" if mps_available else
            "dml" if directml_available else
            "cpu"
        )
    else:
        device = requested

    if device == "cuda" and not cuda_available:
        raise RuntimeError(
            "CUDA/ROCm was requested, but this PyTorch environment cannot see "
            "a supported GPU. Choose Auto or CPU, or install the matching "
            "NVIDIA CUDA / AMD ROCm environment."
        )
    if device == "mps" and not mps_available:
        raise RuntimeError(
            "Apple MPS was requested, but it is unavailable in this environment."
        )
    directml_missing_fallback = device == "dml" and not directml_available
    if directml_missing_fallback:
        device = "cpu"

    if device == "cuda":
        name = torch_module.cuda.get_device_name(0)
        hip_version = getattr(torch_module.version, "hip", None)
        if hip_version:
            label = "AMD ROCm {} - {}".format(hip_version, name)
        else:
            cuda_version = getattr(torch_module.version, "cuda", None) or "unknown"
            label = "NVIDIA CUDA {} - {}".format(cuda_version, name)
    elif device == "mps":
        label = "Apple Metal (MPS)"
    elif device == "dml":
        label = "DirectML (experimental, automatic CPU fallback)"
    else:
        cpu_name = platform.processor() or platform.machine() or "CPU"
        label = "CPU - {}".format(cpu_name)
        if directml_missing_fallback:
            label += " (DirectML unavailable)"

    return device, label


def should_use_cpu_accumulators(memory_mode, device, torch_module=None):
    """Return whether nnU-Net should keep sliding-window accumulators on CPU."""
    if device != "cuda":
        return False
    if memory_mode == "cpu":
        return True
    if memory_mode == "device":
        return False

    if torch_module is None:
        import torch as torch_module
    try:
        total_memory = int(torch_module.cuda.get_device_properties(0).total_memory)
    except (AttributeError, RuntimeError, TypeError, ValueError):
        return False
    return total_memory < LOW_VRAM_THRESHOLD_BYTES


def find_console_script(name):
    """Locate a console entry point in the active Python environment."""
    found = shutil.which(name)
    if found:
        return found

    candidates = [
        os.path.join(sys.prefix, "Scripts", name + ".exe"),
        os.path.join(sys.prefix, "Scripts", name),
        os.path.join(sys.prefix, "bin", name),
    ]
    for candidate in candidates:
        if os.path.isfile(candidate):
            return candidate
    raise FileNotFoundError(
        "{} was not found in the selected environment ({}).".format(
            name, sys.prefix
        )
    )


def build_predict_command(args, in_dir, out_dir, device, cpu_accumulators):
    if device == "dml":
        raise ValueError("DirectML uses the nnU-Net Python API, not its CLI.")
    preset = INFERENCE_PRESETS[args.preset]
    folds = tuple(args.folds) if args.folds else preset["folds"]
    command = [
        find_console_script("nnUNetv2_predict"),
        "-i", in_dir,
        "-o", out_dir,
        "-d", args.dataset,
        "-c", "3d_fullres",
        "-tr", args.trainer,
        "-p", "nnUNetPlans",
        "-f", *folds,
        "-step_size", str(preset["step_size"]),
        "-device", device,
        "-npp", str(args.workers),
        "-nps", str(args.workers),
    ]
    if preset["disable_tta"]:
        command.append("--disable_tta")
    if cpu_accumulators:
        command.append("--not_on_device")
    return command


def run_directml_prediction(args, in_dir, out_dir):
    """Run nnU-Net through its Python API on torch-directml."""
    import torch_directml
    from nnunetv2.inference.predict_from_raw_data import nnUNetPredictor

    preset = INFERENCE_PRESETS[args.preset]
    folds = tuple(args.folds) if args.folds else preset["folds"]
    dataset_name = args.dataset_name or "Dataset{:03d}_VSmix".format(
        int(args.dataset)
    )
    model_folder = os.path.join(
        os.environ["nnUNet_results"],
        dataset_name,
        "{}__nnUNetPlans__3d_fullres".format(args.trainer),
    )
    device = torch_directml.device()
    predictor = nnUNetPredictor(
        tile_step_size=preset["step_size"],
        use_gaussian=True,
        use_mirroring=not preset["disable_tta"],
        perform_everything_on_device=False,
        device=device,
        verbose=False,
        verbose_preprocessing=False,
        allow_tqdm=True,
    )
    predictor.initialize_from_trained_model_folder(
        model_folder,
        [int(fold) if str(fold).isdigit() else fold for fold in folds],
        "checkpoint_final.pth",
    )
    predictor.predict_from_files(
        in_dir,
        out_dir,
        save_probabilities=False,
        overwrite=True,
        num_processes_preprocessing=args.workers,
        num_processes_segmentation_export=args.workers,
        folder_with_segs_from_prev_stage=None,
        num_parts=1,
        part_id=0,
    )


def _directml_worker(args, in_dir, out_dir):
    """Child-process entry point so failed DirectML allocations are released."""
    run_directml_prediction(args, in_dir, out_dir)


def run_directml_isolated(args, in_dir, out_dir):
    context = multiprocessing.get_context("spawn")
    process = context.Process(
        target=_directml_worker,
        args=(args, in_dir, out_dir),
        name="SlicerVS-DirectML",
    )
    process.start()
    process.join()
    return process.exitcode


def parse_args(argv=None):
    parser = argparse.ArgumentParser(
        description="Normalize ceT1 images and run SlicerVS inference."
    )
    parser.add_argument(
        "--folder", default=os.path.join(ROOT, "external_origin_nrrd")
    )
    parser.add_argument("-d", "--dataset", default="502")
    parser.add_argument(
        "--dataset-name",
        default=None,
        help="Dataset folder name below nnUNet_results.",
    )
    parser.add_argument("-tr", "--trainer", default="nnUNetTrainer")
    parser.add_argument(
        "-f", "--folds", nargs="+", default=None,
        help="Advanced override for the folds selected by --preset.",
    )
    parser.add_argument("--suffix", default="_seg")
    parser.add_argument(
        "--preset", choices=tuple(INFERENCE_PRESETS), default="accurate"
    )
    parser.add_argument(
        "--device", choices=("auto", "cuda", "cpu", "mps", "dml"), default="auto"
    )
    parser.add_argument(
        "--memory-mode",
        choices=("auto", "device", "cpu"),
        default="auto",
        help="Where CUDA/ROCm sliding-window accumulators are stored.",
    )
    parser.add_argument(
        "--workers", type=int, default=1,
        help="nnU-Net preprocessing/export workers (default: 1 per Slicer case).",
    )
    postprocess = parser.add_mutually_exclusive_group()
    postprocess.add_argument(
        "--postprocess", dest="postprocess", action="store_true"
    )
    postprocess.add_argument(
        "--no-postprocess", dest="postprocess", action="store_false"
    )
    parser.set_defaults(postprocess=True)
    args = parser.parse_args(argv)
    if args.workers < 1:
        parser.error("--workers must be at least 1")
    return args


def main(argv=None):
    args = parse_args(argv)
    folder = os.path.abspath(args.folder)
    if not os.path.isdir(folder):
        sys.exit("[ERROR] Folder not found: {}".format(folder))
    if not os.environ.get("nnUNet_results"):
        sys.exit("[ERROR] nnUNet_results is not set. Please set it before running.")

    images = sorted(
        filename for filename in os.listdir(folder)
        if filename.lower().endswith(SUPPORTED_EXTS)
        and args.suffix not in filename
    )
    if not images:
        sys.exit("[ERROR] No supported input images found in: {}".format(folder))
    print("{} image(s) to process.".format(len(images)), flush=True)

    try:
        import torch
        device, device_label = resolve_device(args.device, torch)
        cpu_accumulators = should_use_cpu_accumulators(
            args.memory_mode, device, torch
        )
    except Exception as exc:
        sys.exit("[ERROR] Backend selection failed: {}".format(exc))

    preset = INFERENCE_PRESETS[args.preset]
    selected_folds = tuple(args.folds) if args.folds else preset["folds"]
    print("Backend: {} (nnU-Net device={})".format(device_label, device))
    if args.device == "dml" and device == "cpu":
        print(
            "[BACKEND_FALLBACK] DirectML unavailable; using CPU for this queue.",
            flush=True,
        )
    print(
        "Preset: {} | folds={} | step_size={} | TTA={}".format(
            args.preset,
            ",".join(selected_folds),
            preset["step_size"],
            "off" if preset["disable_tta"] else "on",
        )
    )
    if cpu_accumulators:
        print("Memory: low-VRAM mode (sliding-window accumulators on CPU)")

    in_dir = tempfile.mkdtemp(prefix="slicervs_in_")
    out_dir = tempfile.mkdtemp(prefix="slicervs_out_")
    out_pp = out_dir + "_pp"
    name_map = {}

    try:
        print("Normalizing ...")
        for index, filename in enumerate(images):
            stem, extension = split_stem(filename)
            case_id = "case{:04d}".format(index)
            name_map[case_id] = (stem, extension)
            image = sitk.ReadImage(os.path.join(folder, filename))
            normalized = normalize(image)
            sitk.WriteImage(
                normalized,
                os.path.join(in_dir, case_id + "_0000.nii.gz"),
                useCompression=True,
            )
            before = sitk.GetArrayViewFromImage(image)
            after = sitk.GetArrayViewFromImage(normalized)
            print(
                "  {} -> {}_0000.nii.gz  [{:.0f},{:.0f}] -> [{:.1f},{:.1f}]".format(
                    filename,
                    case_id,
                    float(before.min()),
                    float(before.max()),
                    float(after.min()),
                    float(after.max()),
                ),
                flush=True,
            )

        if device == "dml":
            print("\nInference: nnU-Net Python API on DirectML", flush=True)
            try:
                directml_exit_code = run_directml_isolated(
                    args, in_dir, out_dir
                )
            except Exception as exc:
                directml_exit_code = -1
                print("[WARN] DirectML worker could not start: {}".format(exc))
            if directml_exit_code == 0 and not any(
                    name.endswith(".nii.gz") for name in os.listdir(out_dir)):
                print("[WARN] DirectML worker produced no segmentation files.")
                directml_exit_code = 1
            if directml_exit_code != 0:
                print(
                    "[BACKEND_FALLBACK] DirectML inference failed (exit code {}); "
                    "retrying on CPU for this queue.".format(directml_exit_code),
                    flush=True,
                )
                shutil.rmtree(out_dir, ignore_errors=True)
                os.makedirs(out_dir, exist_ok=True)
                device = "cpu"
                command = build_predict_command(
                    args, in_dir, out_dir, device, False
                )
                print(
                    "Inference fallback: {}".format(
                        subprocess.list2cmdline(command)
                    ),
                    flush=True,
                )
                subprocess.run(command, check=True)
        else:
            command = build_predict_command(
                args, in_dir, out_dir, device, cpu_accumulators
            )
            print(
                "\nInference: {}".format(subprocess.list2cmdline(command)),
                flush=True,
            )
            subprocess.run(command, check=True)

        results = os.environ["nnUNet_results"]
        dataset_name = args.dataset_name or "Dataset{:03d}_VSmix".format(
            int(args.dataset)
        )
        cross_validation = os.path.join(
            results,
            dataset_name,
            "{}__nnUNetPlans__3d_fullres".format(args.trainer),
            "crossval_results_folds_0_1_2_3_4",
        )
        pp_pkl = os.path.join(cross_validation, "postprocessing.pkl")
        pp_json = os.path.join(cross_validation, "plans.json")
        segmentation_source = out_dir
        if args.postprocess:
            if os.path.isfile(pp_pkl) and os.path.isfile(pp_json):
                pp_command = [
                    find_console_script("nnUNetv2_apply_postprocessing"),
                    "-i", out_dir,
                    "-o", out_pp,
                    "-pp_pkl_file", pp_pkl,
                    "-np", "1",
                    "-plans_json", pp_json,
                ]
                print("Post-processing: enabled", flush=True)
                subprocess.run(pp_command, check=True)
                segmentation_source = out_pp
            else:
                print(
                    "[WARN] Post-processing requested, but its configuration "
                    "files are missing; using the raw prediction.",
                    flush=True,
                )
        else:
            print("Post-processing: disabled", flush=True)

        saved = 0
        for case_id, (stem, extension) in name_map.items():
            segmentation_nii = os.path.join(
                segmentation_source, case_id + ".nii.gz"
            )
            if not os.path.exists(segmentation_nii):
                print("[WARN] Missing output for: {}".format(stem))
                continue
            segmentation = sitk.Cast(
                sitk.ReadImage(segmentation_nii), sitk.sitkUInt8
            )
            reference = sitk.ReadImage(os.path.join(folder, stem + extension))
            segmentation.CopyInformation(reference)
            output_path = os.path.join(folder, stem + args.suffix + ".nrrd")
            sitk.WriteImage(segmentation, output_path, useCompression=True)
            saved += 1
            print("  saved: {}".format(os.path.basename(output_path)), flush=True)

        print(
            "\nDone. {}/{} segmentation(s) saved to: {}".format(
                saved, len(images), folder
            )
        )
        print("  (value 1 = vestibular schwannoma, value 0 = background)")

    finally:
        shutil.rmtree(in_dir, ignore_errors=True)
        shutil.rmtree(out_dir, ignore_errors=True)
        shutil.rmtree(out_pp, ignore_errors=True)


if __name__ == "__main__":
    main()
