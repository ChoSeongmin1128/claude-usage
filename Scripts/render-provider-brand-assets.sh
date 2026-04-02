#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SOURCE_DIR="${SOURCE_DIR:-$ROOT_DIR/DesignAssets/ProviderBrandSources}"
ASSET_DIR="${ASSET_DIR:-$ROOT_DIR/ClaudeUsage/Assets.xcassets}"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/provider-icons.XXXXXX")"
trap 'rm -rf "$TMP_DIR"' EXIT

require() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "필수 명령을 찾지 못했습니다: $1" >&2
    exit 1
  }
}

require qlmanage
require sips
require python3

render_svg() {
  local name="$1"
  local svg_path="$SOURCE_DIR/$name.svg"
  local fixed_svg="$TMP_DIR/$name-fixed.svg"
  local rendered_png="$TMP_DIR/$name-fixed.svg.png"

  [[ -f "$svg_path" ]] || {
    echo "아이콘 소스 SVG를 찾지 못했습니다: $svg_path" >&2
    exit 1
  }

  python3 - "$svg_path" "$fixed_svg" <<'PY'
from pathlib import Path
import sys

source_path = Path(sys.argv[1])
target_path = Path(sys.argv[2])
svg = source_path.read_text()
svg = svg.replace('height="1em"', 'height="512"').replace('width="1em"', 'width="512"')
target_path.write_text(svg)
PY

  qlmanage -t -s 512 -o "$TMP_DIR" "$fixed_svg" >/dev/null 2>&1
  [[ -f "$rendered_png" ]] || {
    echo "SVG 렌더링에 실패했습니다: $svg_path" >&2
    exit 1
  }
}

write_imageset() {
  local name="$1"
  local imageset_path="$2"
  local base_png="$TMP_DIR/$name-fixed.svg.png"
  local one_x="$imageset_path/$name.png"
  local two_x="$imageset_path/$name@2x.png"

  mkdir -p "$imageset_path"
  python3 - "$base_png" "$one_x" "$two_x" <<'PY'
from collections import deque
from pathlib import Path
from PIL import Image
import sys

source = Path(sys.argv[1])
one_x = Path(sys.argv[2])
two_x = Path(sys.argv[3])

img = Image.open(source).convert("RGBA")
pixels = img.load()
width, height = img.size

def is_background(px):
    r, g, b, a = px
    return a > 0 and r >= 250 and g >= 250 and b >= 250

queue = deque()
visited = set()
for point in [(0, 0), (width - 1, 0), (0, height - 1), (width - 1, height - 1)]:
    if point not in visited and is_background(pixels[point]):
        queue.append(point)
        visited.add(point)

while queue:
    x, y = queue.popleft()
    r, g, b, _ = pixels[x, y]
    pixels[x, y] = (r, g, b, 0)
    for nx, ny in ((x - 1, y), (x + 1, y), (x, y - 1), (x, y + 1)):
        if 0 <= nx < width and 0 <= ny < height and (nx, ny) not in visited and is_background(pixels[nx, ny]):
            visited.add((nx, ny))
            queue.append((nx, ny))

alpha = img.getchannel("A")
bbox = alpha.getbbox()
if bbox:
    img = img.crop(bbox)

def pad_to_square(source_img, target_size):
    width, height = source_img.size
    canvas = Image.new("RGBA", (target_size, target_size), (0, 0, 0, 0))
    inner = int(target_size * 0.84)
    scale = min(inner / width, inner / height)
    resized = source_img.resize(
        (max(1, int(round(width * scale))), max(1, int(round(height * scale)))),
        Image.Resampling.LANCZOS,
    )
    offset = ((target_size - resized.width) // 2, (target_size - resized.height) // 2)
    canvas.alpha_composite(resized, offset)
    return canvas

pad_to_square(img, 64).save(one_x)
pad_to_square(img, 128).save(two_x)
PY
}

for name in claude codex gemini antigravity; do
  case "$name" in
    claude) imageset="ProviderClaudeIcon.imageset" ;;
    codex) imageset="ProviderCodexIcon.imageset" ;;
    gemini) imageset="ProviderGeminiIcon.imageset" ;;
    antigravity) imageset="ProviderAntigravityIcon.imageset" ;;
    *)
      echo "알 수 없는 provider입니다: $name" >&2
      exit 1
      ;;
  esac
  render_svg "$name"
  write_imageset "$name" "$ASSET_DIR/$imageset"
done

echo "Provider 브랜드 아이콘 렌더링 완료"
