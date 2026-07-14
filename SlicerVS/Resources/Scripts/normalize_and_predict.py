#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""
Normalize ceT1 medical images and segment them with a trained nnU-Net v2 model.

Normalization (matches training preprocessing):
  1. Percentile intensity clipping (0.5th-99.9th, removes scanner outliers)
  2. Cast to float32
  3. Preserve original spacing / origin / direction

Inference: 5-fold ensemble, 3d_fullres.
Segmentation results are written back to the input folder as
<original stem><suffix><ext>.

This script is bundled with the SlicerVS extension
(Resources/Scripts/normalize_and_predict.py) so the extension is
self-contained after `git clone` -- it has no dependency on any other
file from the original training repository.

Usage (Dataset502, 1000ep, recommended):
    python normalize_and_predict.py --folder my_images \
        -d 502 -tr nnUNetTrainer --suffix _seg

Usage (Dataset501, 250ep):
    python normalize_and_predict.py --folder my_images \
        -d 501 -tr nnUNetTrainer_250epochs --dataset-name Dataset501_VSceT1 --suffix _seg
"""
import os, sys, shutil, tempfile, argparse, subprocess
import numpy as np
import SimpleITK as sitk

try:
    sys.stdout.reconfigure(encoding="utf-8"); sys.stderr.reconfigure(encoding="utf-8")
except Exception:
    pass

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# Supported input extensions, longest suffix first so ".nii.gz" is matched
# before the generic ".gz"/".nii" would be.
SUPPORTED_EXTS = (".nii.gz", ".nrrd", ".nii", ".mha", ".mhd")


def split_stem(filename: str):
    """Split filename into (stem, ext) using SUPPORTED_EXTS (case-insensitive)."""
    lower = filename.lower()
    for ext in SUPPORTED_EXTS:
        if lower.endswith(ext):
            return filename[: -len(ext)], filename[-len(ext):]
    stem, ext = os.path.splitext(filename)
    return stem, ext


def normalize(img: sitk.Image, lo_pct: float = 0.5, hi_pct: float = 99.9) -> sitk.Image:
    """Percentile intensity clipping + cast to float32, geometry preserved."""
    a = sitk.GetArrayFromImage(img).astype(np.float32)
    lo, hi = np.percentile(a, lo_pct), np.percentile(a, hi_pct)
    a = np.clip(a, lo, hi)
    out = sitk.GetImageFromArray(a)
    out.CopyInformation(img)
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--folder", default=os.path.join(ROOT, "external_origin_nrrd"))
    ap.add_argument("-d", "--dataset", default="502")
    ap.add_argument("--dataset-name", default=None,
                    help="Dataset folder name under nnUNet_results "
                         "(default: auto-built as DatasetNNN_VSmix)")
    ap.add_argument("-tr", "--trainer", default="nnUNetTrainer")
    ap.add_argument("-f", "--folds", nargs="+", default=["0", "1", "2", "3", "4"])
    ap.add_argument("--suffix", default="_seg")
    args = ap.parse_args()

    folder = os.path.abspath(args.folder)
    if not os.path.isdir(folder):
        sys.exit(f"[ERROR] Folder not found: {folder}")
    if not os.environ.get("nnUNet_results"):
        sys.exit("[ERROR] nnUNet_results is not set. Please set it before running.")

    images = sorted(
        f for f in os.listdir(folder)
        if f.lower().endswith(SUPPORTED_EXTS) and args.suffix not in f
    )
    print(f"{len(images)} image(s) to process.")

    in_dir = tempfile.mkdtemp(prefix="ext_in_")
    out_dir = tempfile.mkdtemp(prefix="ext_out_")
    out_pp = out_dir + "_pp"
    name_map = {}  # case_id -> (stem, ext)

    try:
        # Step 1: normalize + convert to nii.gz
        print("Normalizing ...")
        for i, fn in enumerate(images):
            stem, ext = split_stem(fn)
            cid = f"case{i:04d}"
            name_map[cid] = (stem, ext)
            img = sitk.ReadImage(os.path.join(folder, fn))
            norm = normalize(img)
            sitk.WriteImage(norm, os.path.join(in_dir, f"{cid}_0000.nii.gz"),
                            useCompression=True)
            print(f"  {fn} -> {cid}_0000.nii.gz  "
                  f"[{float(sitk.GetArrayViewFromImage(img).min()):.0f},{float(sitk.GetArrayViewFromImage(img).max()):.0f}] "
                  f"-> [{float(sitk.GetArrayViewFromImage(norm).min()):.1f},{float(sitk.GetArrayViewFromImage(norm).max()):.1f}]")

        # Step 2: nnU-Net inference
        cmd = ["nnUNetv2_predict", "-i", in_dir, "-o", out_dir,
               "-d", args.dataset, "-c", "3d_fullres",
               "-tr", args.trainer, "-p", "nnUNetPlans",
               "-f", *args.folds]
        print("\nInference:", " ".join(cmd))
        subprocess.run(cmd, check=True)

        # Step 3: post-processing
        results = os.environ["nnUNet_results"]
        dataset_name = args.dataset_name if args.dataset_name else f"Dataset{int(args.dataset):03d}_VSmix"
        cv = os.path.join(results, dataset_name,
                          f"{args.trainer}__nnUNetPlans__3d_fullres",
                          "crossval_results_folds_0_1_2_3_4")
        pp_pkl = os.path.join(cv, "postprocessing.pkl")
        pp_json = os.path.join(cv, "plans.json")
        seg_src = out_dir
        if os.path.exists(pp_pkl):
            cmd2 = ["nnUNetv2_apply_postprocessing", "-i", out_dir, "-o", out_pp,
                    "-pp_pkl_file", pp_pkl, "-np", "6", "-plans_json", pp_json]
            subprocess.run(cmd2, check=True)
            seg_src = out_pp

        # Step 4: write segmentation back as <stem><suffix>.nrrd
        n_saved = 0
        for cid, (stem, ext) in name_map.items():
            seg_nii = os.path.join(seg_src, f"{cid}.nii.gz")
            if not os.path.exists(seg_nii):
                print(f"[WARN] Missing output for: {stem}"); continue
            seg = sitk.Cast(sitk.ReadImage(seg_nii), sitk.sitkUInt8)
            ref = sitk.ReadImage(os.path.join(folder, stem + ext))
            seg.CopyInformation(ref)   # align geometry to the original image
            out_path = os.path.join(folder, stem + args.suffix + ".nrrd")
            sitk.WriteImage(seg, out_path, useCompression=True)
            n_saved += 1
            print(f"  saved: {os.path.basename(out_path)}")

        print(f"\nDone. {n_saved}/{len(images)} segmentation(s) saved to: {folder}")
        print("  (value 1 = vestibular schwannoma, value 0 = background)")

    finally:
        shutil.rmtree(in_dir, ignore_errors=True)
        shutil.rmtree(out_dir, ignore_errors=True)
        shutil.rmtree(out_pp, ignore_errors=True)


if __name__ == "__main__":
    main()
