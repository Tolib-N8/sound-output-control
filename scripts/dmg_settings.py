# dmgbuild settings for the Soundflow installer window.
# Used by scripts/make_dmg.sh: dmgbuild -s scripts/dmg_settings.py -D app=… -D background=… -D icon=… NAME OUT.dmg
import os.path

application = defines["app"]  # noqa: F821 (provided by dmgbuild)
app_name = os.path.basename(application)

format = "UDZO"
filesystem = "HFS+"
files = [application]
symlinks = {"Программы": "/Applications"}
icon = defines.get("icon")  # noqa: F821
background = defines["background"]  # noqa: F821

# 420 pt of background + Finder titlebar (32) + status bar (28), which newer Finder always shows.
window_rect = ((200, 140), (660, 480))
default_view = "icon-view"
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
show_icon_preview = False
include_icon_view_settings = True

icon_size = 128
text_size = 13
arrange_by = None
icon_locations = {app_name: (170, 180), "Программы": (490, 180)}
