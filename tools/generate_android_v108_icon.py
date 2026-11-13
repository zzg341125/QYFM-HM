from pathlib import Path

from PIL import Image, ImageDraw


ROOT = Path(__file__).resolve().parents[1]
SCALE = 8
SIZE = 108
RED = "#C62A2A"
WHITE = "#FFFFFF"


def scaled(value: float) -> int:
    return round(value * SCALE)


def render() -> Image.Image:
    image = Image.new("RGB", (SIZE * SCALE, SIZE * SCALE), RED)
    draw = ImageDraw.Draw(image)

    draw.line(
        [(scaled(60), scaled(47)), (scaled(78), scaled(33))],
        fill=WHITE,
        width=scaled(3.2),
    )
    draw.rounded_rectangle(
        [scaled(28), scaled(46), scaled(80), scaled(76)],
        radius=scaled(6),
        fill=WHITE,
    )
    draw.rectangle([scaled(33), scaled(51), scaled(56), scaled(57)], fill=RED)
    draw.rectangle([scaled(60), scaled(51), scaled(75), scaled(57)], fill=RED)

    for y in (63, 67, 71):
        draw.line(
            [(scaled(33), scaled(y)), (scaled(49), scaled(y))],
            fill=RED,
            width=scaled(2.2),
        )

    center_x = scaled(68)
    center_y = scaled(62)
    radius = scaled(5.5)
    stroke = scaled(2.4)
    draw.ellipse(
        [
            center_x - radius,
            center_y - radius,
            center_x + radius,
            center_y + radius,
        ],
        outline=RED,
        width=stroke,
    )

    return image.resize((512, 512), Image.Resampling.LANCZOS)


def main() -> None:
    icon = render()
    icon.save(ROOT / "AppScope/resources/base/media/icon.png", optimize=True)
    icon.save(ROOT / "entry/src/main/resources/base/media/icon.png", optimize=True)
    icon.save(ROOT / "entry/src/main/resources/base/media/startIcon.png", optimize=True)


if __name__ == "__main__":
    main()
