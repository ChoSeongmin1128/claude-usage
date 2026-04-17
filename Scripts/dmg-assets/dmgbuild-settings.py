# ClaudeUsage DMG build settings (consumed by dmgbuild).
#
# dmgbuild 이 이 파일을 import 한 뒤 최상위 변수를 DMG 구성값으로 사용합니다.
# make-dmg.sh 가 환경변수로 입력을 주입합니다. (AppleScript 를 사용하지 않고
# .DS_Store 를 바이너리로 직접 기록하므로 Finder 캐시 영향을 받지 않습니다.)
#
# 기대 환경변수:
#   DMG_APP_PATH        : 감쌀 .app 절대 경로 (필수)
#   DMG_BACKGROUND_PNG  : 배경 이미지 경로 (선택, 없으면 배경 없음)
#   DMG_WINDOW_W / H    : 창 크기 (기본 540, 380)
#   DMG_APP_ICON_X / Y  : 앱 아이콘 좌표 (기본 150, 190)
#   DMG_APPS_ICON_X / Y : Applications alias 좌표 (기본 390, 190)

import os

app_path = os.environ["DMG_APP_PATH"]
app_name = os.path.basename(app_path)

window_w = int(os.environ.get("DMG_WINDOW_W", "540"))
window_h = int(os.environ.get("DMG_WINDOW_H", "380"))
app_icon_x = int(os.environ.get("DMG_APP_ICON_X", "150"))
app_icon_y = int(os.environ.get("DMG_APP_ICON_Y", "190"))
apps_icon_x = int(os.environ.get("DMG_APPS_ICON_X", "390"))
apps_icon_y = int(os.environ.get("DMG_APPS_ICON_Y", "190"))

background_path = os.environ.get("DMG_BACKGROUND_PNG", "")
if background_path and not os.path.isfile(background_path):
    background_path = ""

# dmgbuild settings
# https://dmgbuild.readthedocs.io/en/latest/settings.html

format = "UDZO"
compression_level = 9
filesystem = "HFS+"
size = None  # auto (app 용량 기준)

files = [app_path]
symlinks = {"Applications": "/Applications"}

# 창/아이콘 배치
window_rect = ((200, 120), (window_w, window_h))
default_view = "icon-view"
show_icon_preview = False
show_toolbar = False
show_statusbar = False
show_pathbar = False
show_sidebar = False
sidebar_width = 180
icon_size = 96
text_size = 12
include_icon_view_settings = "auto"
include_list_view_settings = "auto"

icon_locations = {
    app_name: (app_icon_x, app_icon_y),
    "Applications": (apps_icon_x, apps_icon_y),
}

# 배경 이미지 (있으면 적용)
if background_path:
    background = background_path
else:
    background = "builtin-arrow"

# 내부 자동 라이선스/bless 는 비활성 (우리가 수동 서명)
license = None
