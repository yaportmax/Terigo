#!/usr/bin/env python3

import argparse
import json
from pathlib import Path

from PIL import Image, ImageDraw


ROOT = Path(__file__).resolve().parents[1]
SHOT_MANIFEST = ROOT / "AppStore" / "SubmissionAssets" / "screenshots" / "shot_manifest.json"
TEMPLATE_ROOT = ROOT / "AppStore" / "SubmissionAssets" / "screenshots" / "6_9_inch_templates"


def rounded_mask(size: tuple[int, int], radius: int) -> Image.Image:
    mask = Image.new("L", size, 0)
    draw = ImageDraw.Draw(mask)
    draw.rounded_rectangle((0, 0, size[0], size[1]), radius=radius, fill=255)
    return mask


def fit_capture(capture: Image.Image, frame: dict, *, fit_mode: str = "cover") -> Image.Image:
    target_size = (frame["width"], frame["height"])
    capture = capture.convert("RGB")
    crop_x_bias = min(max(frame.get("crop_x_bias", 0.5), 0), 1)
    crop_y_bias = min(max(frame.get("crop_y_bias", 0.5), 0), 1)

    width_ratio = target_size[0] / capture.width
    height_ratio = target_size[1] / capture.height
    scale = min(width_ratio, height_ratio) if fit_mode == "contain" else max(width_ratio, height_ratio)

    resized = capture.resize(
        (int(capture.width * scale), int(capture.height * scale)),
        Image.Resampling.LANCZOS,
    )

    if fit_mode == "contain":
        fitted = Image.new("RGB", target_size, (0, 0, 0))
        x = max(int(round((target_size[0] - resized.width) * crop_x_bias)), 0)
        y = max(int(round((target_size[1] - resized.height) * crop_y_bias)), 0)
        fitted.paste(resized, (x, y))
        return fitted

    left = max(int(round((resized.width - target_size[0]) * crop_x_bias)), 0)
    top = max(int(round((resized.height - target_size[1]) * crop_y_bias)), 0)
    return resized.crop((left, top, left + target_size[0], top + target_size[1]))


def load_spec(template_name: str) -> dict:
    specs = json.loads(SHOT_MANIFEST.read_text())
    normalized_name = template_name if template_name.endswith(".png") else f"{template_name}.png"
    for spec in specs:
        if spec["filename"] == normalized_name:
            return spec
    raise SystemExit(f"Template '{template_name}' was not found in {SHOT_MANIFEST}")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Composite a real app capture into a Terigo App Store screenshot template."
    )
    parser.add_argument("--template", required=True, help="Template filename or basename from shot_manifest.json")
    parser.add_argument("--capture", required=True, help="Path to the real app screenshot capture")
    parser.add_argument("--output", required=True, help="Path to write the final composite PNG")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    spec = load_spec(args.template)
    frame = spec["capture_frame"]
    frame["fit_mode"] = spec.get("fit_mode", "cover")
    frame["crop_x_bias"] = spec.get("crop_x_bias", 0.5)
    frame["crop_y_bias"] = spec.get("crop_y_bias", 0.5)

    template_path = TEMPLATE_ROOT / spec["filename"]
    capture_path = Path(args.capture)
    output_path = Path(args.output)
    output_path.parent.mkdir(parents=True, exist_ok=True)

    template = Image.open(template_path).convert("RGBA")
    fitted_capture = fit_capture(
        Image.open(capture_path),
        frame,
        fit_mode=spec.get("fit_mode", "cover"),
    ).convert("RGBA")

    final_image = Image.new("RGBA", template.size, (0, 0, 0, 0))
    final_image.alpha_composite(template)
    mask = rounded_mask((frame["width"], frame["height"]), frame["corner_radius"])
    fitted_capture.putalpha(mask)
    final_image.alpha_composite(fitted_capture, (frame["x"], frame["y"]))

    draw = ImageDraw.Draw(final_image)
    draw.rounded_rectangle(
        (
            frame["x"] - 1,
            frame["y"] - 1,
            frame["x"] + frame["width"] + 1,
            frame["y"] + frame["height"] + 1,
        ),
        radius=frame["corner_radius"] + 1,
        outline=(255, 255, 255, 210),
        width=2,
    )

    final_image.convert("RGB").save(output_path, format="PNG", optimize=True)
    print(f"Wrote {output_path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
