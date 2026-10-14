"""
Compare PP-OCRv6 (via transformers, CPU) with Tesseract 5 on scanned pages.

    uv run eval_ocr.py <image> <truth.txt> [<image> <truth.txt> ...]
    uv run eval_ocr.py samples/letter_300dpi.png samples/letter.txt samples/card_clean.jpg samples/card.txt

For each page and each degraded variant of it, prints the fraction of the
truth's words each engine found (as a multiset, so reading order does not
matter) and the time it took. Tesseract runs through the `tesseract` command
given by $TESSERACT (default: Tesseract_jll's, passed in by the caller) with
$TESSDATA.
"""

import os
import subprocess
import sys
import tempfile
import time
from collections import Counter

import cv2
import numpy as np
import torch
from transformers import AutoImageProcessor, AutoModelForObjectDetection, PPOCRV6SmallRecForTextRecognition

DET = "PaddlePaddle/PP-OCRv6_medium_det_safetensors"
REC = "PaddlePaddle/PP-OCRv6_medium_rec_safetensors"

torch.set_num_threads(8)


def load_models():
    det_proc = AutoImageProcessor.from_pretrained(DET)
    det = AutoModelForObjectDetection.from_pretrained(DET).eval()
    rec_proc = AutoImageProcessor.from_pretrained(REC)
    rec = PPOCRV6SmallRecForTextRecognition.from_pretrained(REC).eval()
    return det_proc, det, rec_proc, rec


def crop_quad(img, quad):
    """The text line inside `quad`, warped to an upright rectangle."""
    quad = np.asarray(quad, dtype=np.float32).reshape(4, 2)
    w = int(max(np.linalg.norm(quad[0] - quad[1]), np.linalg.norm(quad[2] - quad[3])))
    h = int(max(np.linalg.norm(quad[0] - quad[3]), np.linalg.norm(quad[1] - quad[2])))
    dst = np.float32([[0, 0], [w, 0], [w, h], [0, h]])
    m = cv2.getPerspectiveTransform(quad, dst)
    out = cv2.warpPerspective(img, m, (w, h), borderMode=cv2.BORDER_REPLICATE, flags=cv2.INTER_CUBIC)
    if h >= 1.5 * w:
        out = np.rot90(out)
    return out


def ppocr(models, img):
    det_proc, det, rec_proc, rec = models
    with torch.no_grad():
        inputs = det_proc(images=img, return_tensors="pt")
        out = det(pixel_values=inputs["pixel_values"])
        res = det_proc.post_process_object_detection(out, target_sizes=torch.tensor([img.shape[:2]]))[0]
        boxes = res["boxes"].cpu().numpy()
        if boxes.ndim == 2 and boxes.shape[1] == 4:   # corners (xmin, ymin, xmax, ymax)
            boxes = np.stack([[[a, b], [c, b], [c, d], [a, d]] for a, b, c, d in boxes]) if len(boxes) else boxes.reshape(0, 4, 2)
        lines = []
        crops = [crop_quad(img, b) for b in boxes]
        for b, c in zip(boxes, crops):
            if c.shape[0] < 4 or c.shape[1] < 4:
                continue
            ri = rec_proc(images=c, return_tensors="pt")
            ro = rec(**{k: v for k, v in ri.items() if k == "pixel_values"})
            text = rec_proc.post_process_text_recognition(ro)[0]["text"]
            q = np.asarray(b).reshape(4, 2)
            lines.append((q[:, 1].mean(), q[:, 0].min(), text))
    lines.sort()
    return " ".join(t for _, _, t in lines), len(boxes)


def tesseract(img):
    exe = os.environ["TESSERACT"]
    with tempfile.NamedTemporaryFile(suffix=".png") as f:
        cv2.imwrite(f.name, cv2.cvtColor(img, cv2.COLOR_RGB2BGR))
        out = subprocess.run([exe, "--tessdata-dir", os.environ["TESSDATA"], f.name, "-", "--psm", "3",
                              "--dpi", "300", "-l", "deu+eng"], capture_output=True, text=True,
                             env={**os.environ, "OMP_THREAD_LIMIT": "1"})
    return out.stdout


def recall(truth, text):
    t, o = Counter(truth.split()), Counter(text.split())
    return sum(min(n, o[w]) for w, n in t.items()) / max(1, sum(t.values()))


def variants(img):
    h, w = img.shape[:2]
    yield "300 dpi", img
    small = cv2.resize(img, (w // 2, h // 2), interpolation=cv2.INTER_AREA)
    yield "150 dpi", cv2.resize(small, (w, h), interpolation=cv2.INTER_LINEAR)
    yield "blur", cv2.GaussianBlur(img, (0, 0), 2.0)
    ok, jpg = cv2.imencode(".jpg", cv2.cvtColor(img, cv2.COLOR_RGB2BGR), [cv2.IMWRITE_JPEG_QUALITY, 25])
    yield "jpeg q25", cv2.cvtColor(cv2.imdecode(jpg, cv2.IMREAD_COLOR), cv2.COLOR_BGR2RGB)
    ramp = np.linspace(1.0, 0.45, w, dtype=np.float32)[None, :, None]
    yield "shadow", (img.astype(np.float32) * ramp).clip(0, 255).astype(np.uint8)


def main(pairs):
    models = load_models()
    for path, truth_path in pairs:
        img = cv2.cvtColor(cv2.imread(path), cv2.COLOR_BGR2RGB)
        truth = " ".join(open(truth_path).read().split())
        print(f"== {os.path.basename(path)} {img.shape[1]}x{img.shape[0]}, {len(truth.split())} words")
        for name, v in variants(img):
            t0 = time.time(); p, n = ppocr(models, v); tp = time.time() - t0
            t0 = time.time(); t = tesseract(v); tt = time.time() - t0
            print(f"  {name:9s} PP-OCRv6 {recall(truth, p):6.1%} ({n} lines, {tp:4.1f} s)   "
                  f"Tesseract {recall(truth, t):6.1%} ({tt:4.1f} s)")
            if name == "300 dpi":
                print("    PP-OCRv6 :", p[:300])
                print("    Tesseract:", " ".join(t.split())[:300])


if __name__ == "__main__":
    a = sys.argv[1:]
    main(list(zip(a[0::2], a[1::2])))
