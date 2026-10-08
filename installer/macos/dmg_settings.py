# dmgbuild settings for the FlightOut macOS disk image (used by .github/workflows/macos-dmg.yml).
# Window 720x440, app on the left, Applications on the right, themed background with an arrow between them.
import os.path

application = defines.get("app", "FlightOut.app")
appname = os.path.basename(application)

format = "UDZO"
filesystem = "HFS+"
files = [application]
symlinks = {"Applications": "/Applications"}
icon = defines.get("volicon")
background = defines.get("background")

window_rect = ((200, 120), (720, 440))
default_view = "icon-view"
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
show_icon_preview = False
include_icon_view_settings = True
arrange_by = None
icon_size = 128
text_size = 14
icon_locations = {appname: (180, 235), "Applications": (540, 235)}
