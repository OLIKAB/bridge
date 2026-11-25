# dmgbuild settings for Bridge's installer window. Used by build.sh --dist:
#   uvx --from dmgbuild==1.6.7 dmgbuild -s scripts/bridge-dmg-settings.py \
#       -D app=build/Bridge.app -D background=... -D icon=... "Bridge" out.dmg
# dmgbuild writes the window layout itself, so unlike scripting Finder it needs no Automation permission.
# Icon positions match the course plotted in scripts/make-bridge-dmg-background.swift.
import os.path

app = defines["app"]  # noqa: F821 (provided by dmgbuild)
app_name = os.path.basename(app)

format = "UDZO"
filesystem = "HFS+"
size = None

files = [app]
symlinks = {"Applications": "/Applications"}
hide_extensions = [app_name]
icon = defines["icon"]  # noqa: F821

background = defines["background"]  # noqa: F821
window_rect = ((220, 160), (640, 460))
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
default_view = "icon-view"

icon_size = 100
text_size = 12
arrange_by = None
icon_locations = {
    app_name: (170, 200),
    "Applications": (470, 200),
    # Out of sight for people who show hidden files in Finder.
    ".background.tiff": (320, 900),
    ".VolumeIcon.icns": (420, 900),
}
