#!/usr/bin/env python3

import json
from pathlib import Path

import math
import random

from PIL import Image, ImageDraw, ImageFilter, ImageFont


ROOT = Path(__file__).resolve().parents[1]
ASSET_ROOT = ROOT / "AppStore" / "SubmissionAssets"
SCREENSHOT_ROOT = ASSET_ROOT / "screenshots" / "6_9_inch_templates"
ICON_PATH = ROOT / "StravaVault" / "Assets.xcassets" / "AppIcon.appiconset" / "AppIcon-ios-marketing-1024x1024-1x.png"
MARK_PATH = ROOT / "StravaVault" / "Assets.xcassets" / "TerigoMark.imageset" / "terigo-mark-light.png"

CANVAS_SIZE = (1320, 2868)
CAPTURE_FRAME = {
    "x": 258,
    "y": 792,
    "width": 804,
    "height": 1748,
    "corner_radius": 56,
}
COPY_LEFT = 96
COPY_RIGHT = 1224
EYEBROW_TOP = 118
HEADLINE_TOP = 190
COPY_BOTTOM = CAPTURE_FRAME["y"] - 54

SHOT_SPECS = [
    {
        "filename": "01-lists-sharing-template.png",
        "eyebrow": "LISTS",
        "headline": "Build lists for the way you plan.",
        "subheadline": "Group routes into training blocks, races, weekend ideas, or collections you can share.",
        "chips": [],
        "crop_y_bias": 0.5,
        "scene": "alpine",
    },
    {
        "filename": "02-map-browse-template.png",
        "eyebrow": "MAP BROWSE",
        "headline": "Browse routes by where they start.",
        "subheadline": "Explore route clusters on the map, compare nearby options, and open the one that fits the day.",
        "chips": [],
        "crop_y_bias": 0.5,
        "scene": "forest",
    },
    {
        "filename": "03-stackable-filters-template.png",
        "eyebrow": "FILTERS",
        "headline": "Stack filters until the right route appears.",
        "subheadline": "Narrow by movement type, sport, surface, distance, elevation gain, and start area.",
        "chips": [],
        "crop_y_bias": 0.5,
        "scene": "canyon",
    },
    {
        "filename": "04-live-navigation-template.png",
        "eyebrow": "LIVE NAVIGATION",
        "headline": "Follow the line on rich 3D maps.",
        "subheadline": "Use satellite terrain, elevation profiles, off-route visibility, and route-aware live tracking.",
        "chips": [],
        "crop_y_bias": 0.5,
        "scene": "coast",
    },
]


def ensure_dirs() -> None:
    SCREENSHOT_ROOT.mkdir(parents=True, exist_ok=True)
    for png_path in SCREENSHOT_ROOT.glob("*.png"):
        png_path.unlink()


def load_font(size: int, *, bold: bool = False) -> ImageFont.FreeTypeFont:
    candidates = [
        "/System/Library/Fonts/Supplemental/Avenir Next.ttc",
        "/System/Library/Fonts/Supplemental/Helvetica.ttc",
        "/System/Library/Fonts/Supplemental/Arial.ttf",
    ]
    for candidate in candidates:
        try:
            return ImageFont.truetype(candidate, size=size, index=1 if bold else 0)
        except OSError:
            continue

    return ImageFont.load_default()


def draw_vertical_gradient(image: Image.Image, top: tuple[int, int, int], bottom: tuple[int, int, int]) -> None:
    draw = ImageDraw.Draw(image)
    width, height = image.size
    for y in range(height):
        ratio = y / max(height - 1, 1)
        color = tuple(int(top[i] + ((bottom[i] - top[i]) * ratio)) for i in range(3))
        draw.line((0, y, width, y), fill=color)


def lerp_color(a: tuple[int, int, int], b: tuple[int, int, int], ratio: float) -> tuple[int, int, int]:
    return tuple(int(a[i] + (b[i] - a[i]) * ratio) for i in range(3))


def draw_polygon_range(
    draw: ImageDraw.ImageDraw,
    rng: random.Random,
    *,
    base_y: int,
    height: int,
    fill: tuple[int, int, int, int],
    peaks: int,
    phase: float,
) -> None:
    points = [(0, CANVAS_SIZE[1]), (0, base_y)]
    step = CANVAS_SIZE[0] / max(peaks, 1)
    for i in range(peaks + 1):
        x = int(i * step)
        wave = math.sin((i + phase) * 1.45) * 0.28 + math.sin((i + phase) * 0.72) * 0.18
        jitter = rng.randint(-44, 44)
        y = int(base_y - height * (0.52 + wave) + jitter)
        points.append((x, y))
    points.extend([(CANVAS_SIZE[0], base_y), (CANVAS_SIZE[0], CANVAS_SIZE[1])])
    draw.polygon(points, fill=fill)


def draw_tree(draw: ImageDraw.ImageDraw, x: int, y: int, scale: float, color: tuple[int, int, int, int]) -> None:
    trunk_w = max(5, int(8 * scale))
    trunk_h = int(80 * scale)
    draw.rounded_rectangle((x - trunk_w // 2, y - trunk_h, x + trunk_w // 2, y), radius=trunk_w // 2, fill=(47, 33, 24, color[3]))
    for level in range(4):
        top = y - trunk_h - int(level * 46 * scale)
        half = int((52 - level * 7) * scale)
        draw.polygon([(x, top - int(64 * scale)), (x - half, top + int(20 * scale)), (x + half, top + int(20 * scale))], fill=color)


def draw_hiking_background(image: Image.Image, spec: dict) -> None:
    scene = spec.get("scene", "forest")
    palettes = {
        "alpine": {
            "sky": ((29, 53, 82), (145, 174, 188)),
            "far": (78, 103, 112, 190),
            "mid": (48, 86, 78, 210),
            "near": (27, 58, 45, 235),
            "trail": (214, 147, 88, 185),
            "glow": (255, 183, 107, 72),
        },
        "forest": {
            "sky": ((22, 58, 48), (130, 169, 130)),
            "far": (63, 103, 82, 190),
            "mid": (34, 84, 58, 214),
            "near": (17, 54, 39, 238),
            "trail": (182, 139, 88, 180),
            "glow": (181, 223, 138, 74),
        },
        "canyon": {
            "sky": ((54, 36, 72), (176, 123, 97)),
            "far": (105, 70, 92, 190),
            "mid": (122, 78, 58, 214),
            "near": (76, 50, 38, 238),
            "trail": (238, 155, 93, 184),
            "glow": (255, 177, 104, 76),
        },
        "coast": {
            "sky": ((27, 47, 68), (98, 151, 142)),
            "far": (54, 96, 98, 190),
            "mid": (36, 85, 73, 214),
            "near": (31, 53, 40, 238),
            "trail": (230, 186, 103, 184),
            "glow": (255, 210, 120, 76),
        },
    }
    palette = palettes[scene]
    rng = random.Random(spec["filename"])

    draw_vertical_gradient(image, *palette["sky"])
    draw = ImageDraw.Draw(image, "RGBA")

    glow = palette["glow"]
    draw.ellipse((824, -218, 1548, 520), fill=glow)
    draw.ellipse((-220, 1980, 720, 3100), fill=(*palette["trail"][:3], 58))

    if scene == "coast":
        draw.polygon([(0, 1550), (560, 1360), (1320, 1500), (1320, 2868), (0, 2868)], fill=(28, 96, 105, 142))
        draw.polygon([(0, 1700), (530, 1498), (1320, 1630), (1320, 2868), (0, 2868)], fill=(38, 126, 126, 88))

    draw_polygon_range(draw, rng, base_y=1290, height=450, fill=palette["far"], peaks=8, phase=0.3)
    draw_polygon_range(draw, rng, base_y=1620, height=520, fill=palette["mid"], peaks=7, phase=1.1)
    draw_polygon_range(draw, rng, base_y=2060, height=420, fill=palette["near"], peaks=9, phase=2.2)

    trail = [
        (620, 2868),
        (590, 2580),
        (644, 2320),
        (594, 2050),
        (672, 1786),
        (632, 1510),
        (684, 1308),
    ]
    trail_widths = [310, 248, 190, 146, 108, 74, 42]
    for (x, y), width in zip(trail, trail_widths):
        draw.ellipse((x - width // 2, y - width // 3, x + width // 2, y + width // 3), fill=palette["trail"])

    if scene in {"alpine", "forest"}:
        for i in range(24):
            x = rng.choice(list(range(26, 250)) + list(range(1070, 1294)))
            y = rng.randint(1680, 2650)
            scale = rng.uniform(0.52, 1.12)
            alpha = rng.randint(92, 152)
            draw_tree(draw, x, y, scale, (*palette["near"][:3], alpha))

    vignette = Image.new("RGBA", CANVAS_SIZE, (0, 0, 0, 0))
    vignette_draw = ImageDraw.Draw(vignette)
    vignette_draw.rectangle((0, 0, CANVAS_SIZE[0], CANVAS_SIZE[1]), fill=(0, 0, 0, 42))
    vignette_draw.ellipse((-420, -260, 1740, 2760), fill=(0, 0, 0, 0))
    image.alpha_composite(vignette.filter(ImageFilter.GaussianBlur(80)))


def wrap_text_lines(draw: ImageDraw.ImageDraw, text: str, font: ImageFont.FreeTypeFont, max_width: int) -> list[str]:
    words = text.split()
    lines: list[str] = []
    current: list[str] = []

    for word in words:
        candidate = " ".join(current + [word])
        box = draw.textbbox((0, 0), candidate, font=font)
        if current and (box[2] - box[0]) > max_width:
            lines.append(" ".join(current))
            current = [word]
        else:
            current.append(word)

    if current:
        lines.append(" ".join(current))

    return lines


def multiline_height(draw: ImageDraw.ImageDraw, lines: list[str], font: ImageFont.FreeTypeFont, spacing: int) -> int:
    text = "\n".join(lines)
    box = draw.multiline_textbbox((0, 0), text, font=font, spacing=spacing)
    return box[3] - box[1]


def layout_chip_rows(
    draw: ImageDraw.ImageDraw,
    chips: list[str],
    font: ImageFont.FreeTypeFont,
    max_width: int,
    *,
    horizontal_padding: int,
    vertical_padding: int,
    row_spacing: int,
    chip_spacing: int,
) -> tuple[list[list[dict]], int]:
    rows: list[list[dict]] = []
    current_row: list[dict] = []
    current_width = 0
    chip_height = 0

    for chip in chips:
        text_box = draw.textbbox((0, 0), chip, font=font)
        width = text_box[2] - text_box[0] + (horizontal_padding * 2)
        height = text_box[3] - text_box[1] + (vertical_padding * 2)
        chip_height = max(chip_height, height)
        chip_spec = {"label": chip, "width": width, "height": height}

        next_width = width if not current_row else current_width + chip_spacing + width
        if current_row and next_width > max_width:
            rows.append(current_row)
            current_row = [chip_spec]
            current_width = width
        else:
            current_row.append(chip_spec)
            current_width = next_width

    if current_row:
        rows.append(current_row)

    total_height = 0
    if rows:
        total_height = len(rows) * chip_height + (len(rows) - 1) * row_spacing

    return rows, total_height


def fit_copy_layout(draw: ImageDraw.ImageDraw, spec: dict) -> dict:
    for reduction_step in range(0, 12):
        headline_font = load_font(max(66, 86 - reduction_step * 2), bold=True)
        subheadline_font = load_font(max(32, 42 - reduction_step), bold=False)
        chip_font = load_font(max(22, 28 - reduction_step), bold=True)
        headline_spacing = max(4, 8 - reduction_step // 2)
        subheadline_spacing = max(8, 12 - reduction_step // 2)
        chip_horizontal_padding = max(14, 18 - reduction_step // 2)
        chip_vertical_padding = max(10, 13 - reduction_step // 2)
        chip_spacing = max(10, 16 - reduction_step // 2)
        row_spacing = max(10, 14 - reduction_step // 2)

        headline_lines = wrap_text_lines(draw, spec["headline"], headline_font, 900 + reduction_step * 12)
        subheadline_lines = wrap_text_lines(draw, spec["subheadline"], subheadline_font, 930 + reduction_step * 12)

        headline_height = multiline_height(draw, headline_lines, headline_font, headline_spacing)
        subheadline_height = multiline_height(draw, subheadline_lines, subheadline_font, subheadline_spacing)
        chip_rows, chip_height = layout_chip_rows(
            draw,
            spec["chips"],
            chip_font,
            COPY_RIGHT - COPY_LEFT,
            horizontal_padding=chip_horizontal_padding,
            vertical_padding=chip_vertical_padding,
            row_spacing=row_spacing,
            chip_spacing=chip_spacing,
        )

        headline_y = HEADLINE_TOP
        subheadline_y = headline_y + headline_height + max(22, 30 - reduction_step)
        chips_y = subheadline_y + subheadline_height + max(24, 32 - reduction_step)
        copy_bottom = chips_y + chip_height

        if copy_bottom <= COPY_BOTTOM:
            return {
                "headline_font": headline_font,
                "subheadline_font": subheadline_font,
                "chip_font": chip_font,
                "headline_text": "\n".join(headline_lines),
                "subheadline_text": "\n".join(subheadline_lines),
                "headline_spacing": headline_spacing,
                "subheadline_spacing": subheadline_spacing,
                "chip_rows": chip_rows,
                "headline_y": headline_y,
                "subheadline_y": subheadline_y,
                "chips_y": chips_y,
                "chip_horizontal_padding": chip_horizontal_padding,
                "chip_vertical_padding": chip_vertical_padding,
                "chip_spacing": chip_spacing,
                "chip_row_spacing": row_spacing,
            }

    raise RuntimeError(f"Could not fit screenshot copy for {spec['filename']}")


def paste_mark(base: Image.Image) -> None:
    if not MARK_PATH.exists():
        return

    mark = Image.open(MARK_PATH).convert("RGBA")
    mark.thumbnail((108, 108), Image.Resampling.LANCZOS)
    base.alpha_composite(mark, (96, 110))


def rounded_shadow(size: tuple[int, int], radius: int, blur: int, alpha: int) -> Image.Image:
    shadow = Image.new("RGBA", size, (0, 0, 0, 0))
    draw = ImageDraw.Draw(shadow)
    draw.rounded_rectangle((0, 0, size[0], size[1]), radius=radius, fill=(0, 0, 0, alpha))
    return shadow.filter(ImageFilter.GaussianBlur(blur))


def create_template(spec: dict) -> None:
    capture_frame = spec.get("capture_frame", CAPTURE_FRAME)
    image = Image.new("RGBA", CANVAS_SIZE, (255, 255, 255, 255))
    draw_hiking_background(image, spec)
    overlay = ImageDraw.Draw(image)

    paste_mark(image)

    eyebrow_font = load_font(36, bold=True)
    copy_layout = fit_copy_layout(overlay, spec)

    overlay.text((220, EYEBROW_TOP), spec["eyebrow"], font=eyebrow_font, fill=(255, 214, 189))

    overlay.multiline_text(
        (COPY_LEFT, copy_layout["headline_y"]),
        copy_layout["headline_text"],
        font=copy_layout["headline_font"],
        fill=(255, 255, 255),
        spacing=copy_layout["headline_spacing"],
    )
    overlay.multiline_text(
        (COPY_LEFT, copy_layout["subheadline_y"]),
        copy_layout["subheadline_text"],
        font=copy_layout["subheadline_font"],
        fill=(233, 239, 247),
        spacing=copy_layout["subheadline_spacing"],
    )

    chip_y = copy_layout["chips_y"]
    for row in copy_layout["chip_rows"]:
        chip_x = COPY_LEFT
        row_height = max(chip["height"] for chip in row)
        for chip in row:
            overlay.rounded_rectangle(
                (chip_x, chip_y, chip_x + chip["width"], chip_y + row_height),
                radius=row_height // 2,
                fill=(255, 255, 255, 208),
                outline=(255, 255, 255, 232),
                width=2,
            )
            overlay.text(
                (chip_x + copy_layout["chip_horizontal_padding"], chip_y + copy_layout["chip_vertical_padding"]),
                chip["label"],
                font=copy_layout["chip_font"],
                fill=(28, 35, 46),
            )
            chip_x += chip["width"] + copy_layout["chip_spacing"]
        chip_y += row_height + copy_layout["chip_row_spacing"]

    shadow_padding = 42
    shadow = rounded_shadow(
        (capture_frame["width"] + shadow_padding * 2, capture_frame["height"] + shadow_padding * 2),
        capture_frame["corner_radius"] + shadow_padding,
        18,
        108,
    )
    image.alpha_composite(
        shadow,
        (
            capture_frame["x"] - shadow_padding + 10,
            capture_frame["y"] - shadow_padding + 16,
        ),
    )

    output_path = SCREENSHOT_ROOT / spec["filename"]
    image.convert("RGB").save(output_path, format="PNG", optimize=True)


def write_manifest() -> None:
    manifest = {
        "app_name": "Terigo",
        "subtitle": "Organize Strava routes",
        "existing_assets": {
            "marketing_icon": str(ICON_PATH.relative_to(ROOT)),
            "support_doc": "AppStore/SUPPORT.md",
            "privacy_policy_doc": "AppStore/PRIVACY_POLICY.md",
            "site_sources": [
                "AppStore/Site/index.html",
                "AppStore/Site/support.html",
                "AppStore/Site/privacy.html",
                "AppStore/Site/styles.css",
            ],
        },
        "generated_assets": {
            "screenshot_templates": [
                str((SCREENSHOT_ROOT / spec["filename"]).relative_to(ROOT)) for spec in SHOT_SPECS
            ],
            "screenshot_composer": "Scripts/compose_app_store_screenshot.py",
            "screenshot_capture_script": "Scripts/capture_app_store_screenshots.py",
            "metadata_json": "AppStore/SubmissionAssets/metadata/AppStoreConnectMetadata.json",
            "screenshot_docs": [
                "AppStore/SubmissionAssets/screenshots/README.md",
                "AppStore/SubmissionAssets/screenshots/CaptureChecklist.md",
                "AppStore/SubmissionAssets/screenshots/AppStoreScreenshotSpec.md",
                "AppStore/SubmissionAssets/screenshots/shot_manifest.json",
            ],
        },
    }
    (ASSET_ROOT / "asset_manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
    (ASSET_ROOT / "screenshots" / "shot_manifest.json").write_text(
        json.dumps(
            [
                {
                    "filename": spec["filename"],
                    "required_display_class": "6.9-inch iPhone",
                    "accepted_portrait_sizes": ["1290x2796", "1320x2868"],
                    "eyebrow": spec["eyebrow"],
                    "headline": spec["headline"],
                    "subheadline": spec["subheadline"],
                    "chips": spec["chips"],
                    "size": {"width": CANVAS_SIZE[0], "height": CANVAS_SIZE[1]},
                    "capture_frame": spec.get("capture_frame", CAPTURE_FRAME),
                    "fit_mode": spec.get("fit_mode", "contain"),
                    "crop_x_bias": spec.get("crop_x_bias", 0.5),
                    "crop_y_bias": spec["crop_y_bias"],
                }
                for spec in SHOT_SPECS
            ],
            indent=2,
        ) + "\n"
    )


def main() -> int:
    ensure_dirs()
    for spec in SHOT_SPECS:
        create_template(spec)
    write_manifest()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
