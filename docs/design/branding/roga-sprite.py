# /// script
# requires-python = ">=3.11"
# dependencies = ["pillow"]
# ///
"""Draw the Roga house as a 32x32 sprite, in the 8-bit style.

FRAME is the artwork: one character per pixel, with the ink outline added
around its silhouette afterward. Edit it and run

    uv run docs/design/branding/roga-sprite.py

to rewrite roga-sprite.svg, roga-sprite.png (32x32) and roga-sprite-512.png
next to this file.
"""

from pathlib import Path

from PIL import Image, ImageColor

HERE = Path(__file__).parent
SIZE = 32

PALETTE = {
    "K": "#2A1408",  # outline and window frame
    "R": "#D54802",  # roof, the mark's orange
    "H": "#FF8426",  # lit side of the roof
    "D": "#8C2C00",  # shingles and the shaded side of the roof
    "T": "#F2B872",  # logs and chimney
    "B": "#A65A1E",  # seams between logs, chimney cap
    "Y": "#FFE066",  # lit window
    "A": "#FFA826",  # bottom of a window pane
    "L": "#FFC233",  # legs
    "M": "#C9700F",  # shaded side of a leg
}

FRAME = [
    "",
    ".................RD",
    ".................RD..BBBBBB",
    "................HRRD.BBBBBB",
    "................HRRD..TTTB",
    "...............HRRRRD.TTTB",
    "..............HRDDRRRDTTTB",
    ".............HRRRRRRRRDTTB",
    "...........HHRRRDDRRRRDDDB",
    "........HHHRRRRRRRRRRRRRRDDD",
    "....HHHRDDRRRDDRRRDDRRRDDRDDD",
    "......DDDDDDDDDDDDDDDDDDDDDDDDD",
    ".........TTTKKKKKKKKKKKTTT",
    ".........TTTKYYYYKYYYYKTTT",
    "........BBBBKYYYYKYYYYKTTT",
    ".........TTTKAAAAKAAAAKTTT",
    ".........TTTKKKKKKKKKKKBBBB",
    ".........TTTKYYYYKYYYYKTTT",
    "........BBBBKYYYYKYYYYKTTT",
    ".........TTTKAAAAKAAAAKTTT",
    ".........TTTKKKKKKKKKKKBBBB",
    "..........TTTTTTTTTTTTTTT",
    "...........BBBBBBBBBBBBB",
    "............LLM....LLM",
    "...........LLLM....LLM",
    "..LL.....LLLM.......LLM",
    "...LLL..LLLM........LLM....LL",
    ".....LLLLLM.........LLM..LLL",
    ".LLLLLLLLM..........LLLLLL",
    ".....LLM...........LLLLLLLLLL",
    "..................LLL.LLLLLLL",
    "",
]


def cells_with_outline() -> list[list[str]]:
    assert len(FRAME) == SIZE, f"FRAME has {len(FRAME)} rows"
    assert all(len(row) <= SIZE for row in FRAME), "a row is too wide"
    cells = [list(row.ljust(SIZE, ".")) for row in FRAME]
    outlined = [row[:] for row in cells]
    for y in range(SIZE):
        for x in range(SIZE):
            if cells[y][x] != ".":
                continue
            for dx, dy in ((1, 0), (-1, 0), (0, 1), (0, -1)):
                nx, ny = x + dx, y + dy
                if 0 <= nx < SIZE and 0 <= ny < SIZE and cells[ny][nx] != ".":
                    outlined[y][x] = "K"
                    break
    return outlined


def write_png(cells: list[list[str]]) -> None:
    image = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
    for y, row in enumerate(cells):
        for x, key in enumerate(row):
            if key != ".":
                image.putpixel((x, y), ImageColor.getrgb(PALETTE[key]) + (255,))
    image.save(HERE / "roga-sprite.png")
    image.resize((512, 512), Image.NEAREST).save(HERE / "roga-sprite-512.png")


def write_svg(cells: list[list[str]]) -> None:
    runs: dict[str, list[str]] = {key: [] for key in PALETTE}
    for y, row in enumerate(cells):
        x = 0
        while x < SIZE:
            key = row[x]
            end = x
            while end < SIZE and row[end] == key:
                end += 1
            if key != ".":
                runs[key].append(f"M{x} {y}h{end - x}v1h-{end - x}z")
            x = end
    paths = "\n".join(
        f'  <path fill="{PALETTE[key]}" d="{"".join(parts)}"/>'
        for key, parts in runs.items()
        if parts
    )
    (HERE / "roga-sprite.svg").write_text(
        f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {SIZE} {SIZE}" '
        f'width="512" height="512" shape-rendering="crispEdges" role="img">\n'
        "  <title>Roga sprite</title>\n"
        "  <desc>The Roga house on chicken legs, drawn as a 32 by 32 pixel sprite.</desc>\n"
        f"{paths}\n</svg>\n"
    )


if __name__ == "__main__":
    artwork = cells_with_outline()
    write_png(artwork)
    write_svg(artwork)
