from pathlib import Path

from PIL import Image, ImageDraw


ROOT = Path(__file__).resolve().parents[1]
SCALE = 8
SIZE = 108
RED = "#C62A2A"
WHITE = "#FFFFFF"
CONTENT_SCALE = 1.55
CENTER = 54


def scaled(value: float) -> int:
    return round(value * SCALE)


def content_scaled(value: float) -> int:
    return scaled(CENTER + (value - CENTER) * CONTENT_SCALE)


def render() -> Image.Image:
    image = Image.new("RGB", (SIZE * SCALE, SIZE * SCALE), RED)
    draw = ImageDraw.Draw(image)

    draw.line(
        [(content_scaled(60), content_scaled(47)), (content_scaled(78), content_scaled(33))],
        fill=WHITE,
        width=scaled(3.2 * CONTENT_SCALE),
    )
    draw.rounded_rectangle(
        [
            content_scaled(28),
            content_scaled(46),
            content_scaled(80),
            content_scaled(76),
        ],
        radius=scaled(6 * CONTENT_SCALE),
        fill=WHITE,
    )
    draw.rectangle(
        [content_scaled(33), content_scaled(51), content_scaled(56), content_scaled(57)],
        fill=RED,
    )
    draw.rectangle(
        [content_scaled(60), content_scaled(51), content_scaled(75), content_scaled(57)],
        fill=RED,
    )

    for y in (63, 67, 71):
        draw.line(
            [(content_scaled(33), content_scaled(y)), (content_scaled(49), content_scaled(y))],
            fill=RED,
            width=scaled(2.2 * CONTENT_SCALE),
        )

    center_x = content_scaled(68)
    center_y = content_scaled(62)
    radius = scaled(5.5 * CONTENT_SCALE)
    stroke = scaled(2.4 * CONTENT_SCALE)
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
