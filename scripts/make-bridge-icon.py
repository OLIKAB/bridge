# Renders Bridge's brand images in Blender: the knot, three Borromean rings truly woven in 3D
# (A over B, B over C, C over A; take one away and the other two fall apart, as code, server and
# agent do without Bridge), in white ceramic lit by three coloured strip lights, one per ring.
#
#   /Applications/Blender.app/Contents/MacOS/Blender -b -P scripts/make-bridge-icon.py
#
# writes Resources/BridgeIcon.icns and, in Resources/Brand, the 1024 px icon, a transparent render of
# the knot for the website and a wide banner for link previews. One Blender run per image; the first
# run starts the others and then builds the .icns with iconutil.
import bpy, math, sys, os, subprocess, shutil
import numpy as np
from mathutils import Vector

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BRAND = os.path.join(ROOT, "Resources", "Brand")
WORK = os.path.join(ROOT, "build", "icon-render")
argv = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
MODE = argv[0] if argv else "all"

if MODE == "all":
    os.makedirs(BRAND, exist_ok=True)
    os.makedirs(WORK, exist_ok=True)
    for mode in ("icon", "icon-small", "hero", "banner"):
        subprocess.run([bpy.app.binary_path, "-b", "-P", os.path.abspath(__file__), "--", mode], check=True,
                       stdout=subprocess.DEVNULL)
        print("rendered", mode)
    # The knot's weave is too fine to read below 128 px, so the small sizes come from a render with
    # thicker rings seen closer.
    iconset = os.path.join(WORK, "Bridge.iconset")
    shutil.rmtree(iconset, ignore_errors=True)
    os.makedirs(iconset)
    big, small = os.path.join(WORK, "icon.png"), os.path.join(WORK, "icon-small.png")
    for name, px, src in [("16x16", 16, small), ("16x16@2x", 32, small), ("32x32", 32, small), ("32x32@2x", 64, small),
                          ("128x128", 128, big), ("128x128@2x", 256, big), ("256x256", 256, big),
                          ("256x256@2x", 512, big), ("512x512", 512, big), ("512x512@2x", 1024, big)]:
        subprocess.run(["sips", "-z", str(px), str(px), src, "--out", os.path.join(iconset, f"icon_{name}.png")],
                       check=True, stdout=subprocess.DEVNULL)
    subprocess.run(["iconutil", "-c", "icns", iconset, "-o", os.path.join(ROOT, "Resources", "BridgeIcon.icns")], check=True)
    shutil.copy(big, os.path.join(BRAND, "bridge-icon-1024.png"))
    shutil.copy(small, os.path.join(BRAND, "bridge-icon-small-256.png"))
    shutil.copy(os.path.join(WORK, "hero.png"), os.path.join(BRAND, "bridge-knot-2048.png"))
    shutil.copy(os.path.join(WORK, "banner.png"), os.path.join(BRAND, "bridge-banner-2400x1260.png"))
    print("Wrote Resources/BridgeIcon.icns and Resources/Brand")
    bpy.ops.wm.quit_blender()

SETTINGS = {
    # mode: (width, height, samples, ring shape, camera distance, transparent)
    "icon": (1024, 1024, 384, "pill", 19.0, False),
    "icon-small": (256, 256, 256, "fat", 16.0, False),
    "hero": (2048, 2048, 384, "pill", 19.0, True),
    "banner": (2400, 1260, 384, "pill", 40.0, False),
}
W, H, SAMPLES, SHAPE, DIST, TRANSPARENT = SETTINGS[MODE]

bpy.ops.wm.read_factory_settings(use_empty=True)
scene = bpy.context.scene
scene.render.engine = 'CYCLES'
try:
    prefs = bpy.context.preferences.addons['cycles'].preferences
    prefs.compute_device_type = 'METAL'
    prefs.get_devices()
    for d in prefs.devices:
        d.use = True
    scene.cycles.device = 'GPU'
except Exception:
    pass
scene.cycles.samples = SAMPLES
scene.cycles.use_denoising = True
scene.cycles.blur_glossy = 0.5
scene.render.resolution_x, scene.render.resolution_y = W, H
scene.render.film_transparent = TRANSPARENT
scene.render.image_settings.file_format = 'PNG'
scene.render.image_settings.color_mode = 'RGBA'
# Khronos PBR Neutral keeps the coloured light coloured; AgX bleaches bright colour towards white.
scene.view_settings.view_transform = 'Khronos PBR Neutral'

GREEN, VIOLET, CORAL = (0.16, 0.92, 0.58), (0.42, 0.3, 1.0), (1.0, 0.42, 0.22)

# ---- the knot ------------------------------------------------------------------
CENTERS = {'A': (0.0, 1.1), 'B': (-0.95, -0.55), 'C': (0.95, -0.55)}
OVER = {('A', 'B'), ('B', 'C'), ('C', 'A')}
R = 1.6
PROFILES = {'pill': (0.42, 0.26), 'fat': (0.5, 0.36)}

def crossings(i):
    out = []
    ci = np.array(CENTERS[i])
    for j, cj in CENTERS.items():
        if j == i:
            continue
        cj = np.array(cj)
        d = np.linalg.norm(cj - ci); a = d / 2; h = math.sqrt(R * R - a * a)
        m = ci + (cj - ci) / 2; perp = np.array([-(cj - ci)[1], (cj - ci)[0]]) / d
        for p in (m + perp * h, m - perp * h):
            out.append((math.atan2(p[1] - ci[1], p[0] - ci[0]), 1 if (i, j) in OVER else -1))
    return out

def ring(key, a_rad, b_dep, depth=0.3, sigma=0.5, N=360, M=48):
    """A ring swept along a circle whose depth rises where it passes over a neighbour and sinks
    where it passes under, so the three are woven rather than stacked."""
    cx, cy = CENTERS[key]
    xs = crossings(key)
    def z(t):
        s = 0.0
        for tk, sg in xs:
            dt = (t - tk + math.pi) % (2 * math.pi) - math.pi
            s += sg * depth * math.exp(-dt * dt / (2 * sigma * sigma))
        return s
    pts = [Vector((cx + R * math.cos(t), cy + R * math.sin(t), z(t))) for t in np.linspace(0, 2 * math.pi, N, endpoint=False)]
    verts = []
    for k in range(N):
        p = pts[k]; T = (pts[(k + 1) % N] - pts[k - 1]).normalized()
        u = Vector((p.x - cx, p.y - cy, 0)).normalized()
        n1 = (u - u.dot(T) * T).normalized(); n2 = T.cross(n1).normalized()
        if n2.z < 0:
            n2 = -n2
        for m in range(M):
            ph = 2 * math.pi * m / M
            verts.append(p + n1 * (a_rad * math.cos(ph)) + n2 * (b_dep * math.sin(ph)))
    faces = [(k * M + m, k * M + (m + 1) % M, ((k + 1) % N) * M + (m + 1) % M, ((k + 1) % N) * M + m) for k in range(N) for m in range(M)]
    me = bpy.data.meshes.new("Ring" + key)
    me.from_pydata([tuple(v) for v in verts], [], faces)
    me.update()
    for f in me.polygons:
        f.use_smooth = True
    ob = bpy.data.objects.new("Ring" + key, me)
    scene.collection.objects.link(ob)
    return ob

ceramic = bpy.data.materials.new("Ceramic")
ceramic.use_nodes = True
p = ceramic.node_tree.nodes["Principled BSDF"]
p.inputs["Base Color"].default_value = (0.88, 0.88, 0.9, 1)
p.inputs["Roughness"].default_value = 0.3
p.inputs["Coat Weight"].default_value = 0.6
p.inputs["Coat Roughness"].default_value = 0.06
for key in "ABC":
    ring(key, *PROFILES[SHAPE]).data.materials.append(ceramic)

# ---- world, backdrop, lights ------------------------------------------------------
w = bpy.data.worlds.new("W"); scene.world = w; w.use_nodes = True
nt = w.node_tree; bg = nt.nodes["Background"]; bg.inputs[1].default_value = 0.15
env = nt.nodes.new("ShaderNodeTexEnvironment")
env.image = bpy.data.images.load(os.path.join(os.path.dirname(bpy.app.binary_path), "..", "Resources",
                                              f"{bpy.app.version[0]}.{bpy.app.version[1]}", "datafiles", "studiolights", "world", "studio.exr"))
nt.links.new(env.outputs["Color"], bg.inputs["Color"])

if not TRANSPARENT:
    bpy.ops.mesh.primitive_plane_add(size=80, location=(0, 0, -1.6))
    bd = bpy.data.materials.new("Backdrop"); bd.use_nodes = True
    bp = bd.node_tree.nodes["Principled BSDF"]
    bp.inputs["Base Color"].default_value = (0.02, 0.02, 0.03, 1)
    bp.inputs["Roughness"].default_value = 0.6
    bpy.context.active_object.data.materials.append(bd)

def look_at(ob, target):
    ob.rotation_euler = (Vector(target) - ob.location).to_track_quat('-Z', 'Y').to_euler()

def area(color, energy, loc, size, size_y=None):
    l = bpy.data.lights.new("L", 'AREA'); l.color = color; l.energy = energy
    if size_y:
        l.shape = 'RECTANGLE'; l.size = size; l.size_y = size_y
    else:
        l.size = size
    ob = bpy.data.objects.new("L", l); ob.location = loc
    scene.collection.objects.link(ob); look_at(ob, (0, 0.3, 0))

# One coloured strip per ring, from the side that ring faces, low and grazing; a soft white key above.
area((1, 1, 1), 380, (-5, 6, 10), 4)
area(GREEN, 1800, (0, 8, 1.2), 5, 0.6)
area(VIOLET, 2000, (-8, -3, 1.2), 5, 0.6)
area(CORAL, 1800, (8, -3, 1.2), 5, 0.6)

cd = bpy.data.cameras.new("Cam"); cd.lens = 85
cam = bpy.data.objects.new("Cam", cd)
t = math.radians(9)
cam.location = (0, 0.27 - DIST * math.sin(t), DIST * math.cos(t))
scene.collection.objects.link(cam); scene.camera = cam
look_at(cam, (0, 0.27, 0))
if MODE == "banner":
    cd.shift_x = -0.17  # the knot sits right of centre, leaving room for a headline

raw = os.path.join(WORK, f"{MODE}-raw.png")
scene.render.filepath = raw
bpy.ops.render.render(write_still=True)

# ---- post ---------------------------------------------------------------------------
img = bpy.data.images.load(raw)
px = np.array(img.pixels[:], dtype=np.float32).reshape(H, W, 4)

def box(a, r, axis):
    c = np.cumsum(np.pad(a, [(r + 1, r) if i == axis else (0, 0) for i in range(a.ndim)], mode='edge'), axis=axis)
    return (np.take(c, range(2 * r + 1, c.shape[axis]), axis=axis) - np.take(c, range(0, c.shape[axis] - 2 * r - 1), axis=axis)) / (2 * r + 1)

def blur(a, sigma):
    r = max(1, int(sigma * 0.9))
    for _ in range(3):
        a = box(box(a, r, 0), r, 1)
    return a

def save(arr, path):
    out = bpy.data.images.new(os.path.basename(path), arr.shape[1], arr.shape[0], alpha=True)
    out.pixels.foreach_set(np.clip(arr, 0, 1).astype(np.float32).ravel())
    out.filepath_raw = path; out.file_format = 'PNG'; out.save()

s = min(W, H) / 1024
rgb = px[..., :3]
if not TRANSPARENT:
    # A soft bloom on the brightest highlights, as light behaves in a lens.
    lum = rgb.max(axis=2, keepdims=True)
    bright = rgb * np.clip((lum - 0.72) / 0.28, 0, 1)
    bloom = (blur(bright, 26 * s) * 0.9 + blur(bright, 7 * s) * 0.5 + blur(bright, 80 * s) * 0.45) * 0.25
    rgb = 1 - (1 - np.clip(rgb, 0, 1)) * (1 - np.clip(bloom, 0, 1))

if MODE in ("hero", "banner"):
    save(np.dstack([rgb, px[..., 3:4]]) if TRANSPARENT else np.dstack([rgb, np.ones((H, W, 1), np.float32)]), os.path.join(WORK, f"{MODE}.png"))
else:
    # macOS icon grid: the shape is 824 of 1024 points with continuous corners, a light rim on its
    # upper edge and a soft shadow below.
    ys, xs = np.mgrid[0:H, 0:W].astype(np.float32)
    a = 0.4025 * W; cx, cy = (W - 1) / 2, (H - 1) / 2
    f = ((np.abs(xs - cx) / a) ** 6.0 + (np.abs(ys - cy) / a) ** 6.0) ** (1 / 6.0)
    inside = np.clip((1 - f) * a + 0.5, 0, 1)
    def resample(src, scale):
        sx = (xs - cx) / scale + cx; sy = (ys - cy) / scale + cy
        x0 = np.clip(np.floor(sx).astype(int), 0, W - 2); y0 = np.clip(np.floor(sy).astype(int), 0, H - 2)
        fx = (sx - x0)[..., None]; fy = (sy - y0)[..., None]
        return (src[y0, x0] * (1 - fx) + src[y0, x0 + 1] * fx) * (1 - fy) + (src[y0 + 1, x0] * (1 - fx) + src[y0 + 1, x0 + 1] * fx) * fy
    content = resample(rgb, 0.86)
    top = np.clip((ys - cy) / a, 0, 1)[..., None]  # rows run bottom to top in Blender
    rim = np.clip(1 - np.abs(f - 0.993) * a / 1.4, 0, 1)[..., None] * (0.08 + 0.32 * top)
    content = content + (1 - content) * rim
    shadow = blur(np.roll(inside, -max(1, int(12 * s)), axis=0)[..., None], max(1.0, 14 * s))[..., 0] * 0.45
    alpha = inside + shadow * (1 - inside)
    col = content * inside[..., None]
    save(np.dstack([np.where(alpha[..., None] > 0, col / np.maximum(alpha[..., None], 1e-4), 0), alpha]), os.path.join(WORK, f"{MODE}.png"))
print("DONE", MODE)
