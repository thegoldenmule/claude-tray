# dmgbuild settings for the release disk image: ClaudeTray.app beside an Applications link,
# over Resources/dmg-background.png. Used by scripts/release.sh:
#
#   dmgbuild -s scripts/dmg-settings.py -D app=<path/to/ClaudeTray.app> ClaudeTray <out.dmg>
#
# dmgbuild writes the Finder layout (.DS_Store) itself, so no Finder scripting is involved.
# Icon positions must match the centers in scripts/make-dmg-background.swift.
import os.path

app = defines["app"]  # noqa: F821 (provided by dmgbuild)
app_name = os.path.basename(app)

format = "UDZO"
filesystem = "HFS+"
files = [app]
symlinks = {"Applications": "/Applications"}
badge_icon = "Resources/AppIcon.icns"
hide_extension = [app_name]

background = "Resources/dmg-background.png"  # @2x picked up automatically
window_rect = ((200, 120), (600, 380))
default_view = "icon-view"
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
icon_size = 128
text_size = 13
icon_locations = {
    app_name: (150, 170),
    "Applications": (450, 170),
}
