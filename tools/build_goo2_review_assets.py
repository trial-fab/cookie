"""Build the review blend, integrated Hop, and healing pose helper.

Run from the ClickGame repository root:

    /tmp/blender-5.1.2/blender -b docs/blender/sources/goo2.blend \
        --python tools/build_goo2_review_assets.py

The canonical source is never saved over. The review blend retains
GooHealingProgress as an internal pose helper for the synchronized Dizzy pair,
but only the production Hop FBX is exported here. Titan has its own authored
source and exporter and is never generated or overwritten by this script.
"""

from pathlib import Path

import bmesh
import bpy
from mathutils import Vector
from mathutils.bvhtree import BVHTree


ARMATURE_NAME = "GooRig"
MESH_NAMES = ("SlimeBody", "SlimeEyes")
HOP_SOURCE = "GooHop"
HOP_ACTION = "GooHopIntegrated"
HEALING_SOURCE = "GooReveal"
HEALING_ACTION = "GooHealingProgress"
HOP_RANGE = (1, 72)
HEALING_RANGE = (1, 61)
HOP_PEAK_HEIGHT = 6.0
HOP_TAKEOFF_FRAME = 18
HOP_LAND_FRAME = 52

# Keep the expressive poses from GooHop, synchronize landing deformation to
# its root arc, and let the animation own all vertical movement. Roblox only
# needs to move the model horizontally using the track's actual TimePosition.
HOP_TIME_REMAP = (
    (1.0, 1.0),
    (7.0, 7.0),
    (10.0, 14.0),
    (14.0, 18.0),
    # Align the inherited apex extreme with the authored gelatin apex. Keeping
    # these at frames 34 and 35 respectively created two contradictory extreme
    # silhouettes one frame apart and caused a visible playback snap.
    (22.0, 35.0),
    (28.0, 49.0),
    (30.0, 55.0),
    (35.0, 61.0),
    (40.0, 67.0),
    (45.0, 72.0),
)

# Stronger extremes communicate a soft, gelatinous material. The largest
# deformation is reserved for impact, followed by diminishing opposing poses.
HOP_DEFORMATION_SCALE = (
    (1.0, 1.0),
    (7.0, 1.05),
    (10.0, 1.45),
    (14.0, 1.35),
    (22.0, 1.12),
    (28.0, 1.42),
    (30.0, 1.62),
    (35.0, 1.34),
    (40.0, 1.16),
    (45.0, 1.0),
)

# Airborne silhouette polish. The body carries a stretched baseline from
# takeoff through first contact, while a smaller lateral wave travels through
# the unsupported upper mass. This preserves momentum without freezing the goo
# into one rigid tapered silhouette.
HOP_AIRBORNE_POSES = {
    18: {
        "GooLower": ((0.0, 0.035, 0.0), (0.0, 0.0, 0.0)),
        "GooMid": ((0.012, 0.20, 0.0), (0.0, 0.0, 0.025)),
        "GooUpper": ((0.025, 0.44, -0.006), (-0.035, 0.0, 0.045)),
        "GooSideFront": ((0.0, 0.01, 0.20), (0.0, 0.0, 0.0)),
        "GooSideBack": ((0.0, 0.01, -0.20), (0.0, 0.0, 0.0)),
        "GooSideLeft": ((0.20, 0.01, 0.0), (0.0, 0.0, 0.0)),
        "GooSideRight": ((-0.20, 0.01, 0.0), (0.0, 0.0, 0.0)),
    },
    24: {
        "GooLower": ((0.0, 0.035, 0.0), (0.0, 0.0, 0.0)),
        "GooMid": ((0.018, 0.18, 0.0), (0.0, 0.0, 0.035)),
        "GooUpper": ((0.04, 0.50, -0.008), (-0.045, 0.0, 0.060)),
        "GooSideFront": ((0.0, 0.012, 0.19), (0.0, 0.0, 0.0)),
        "GooSideBack": ((0.0, 0.012, -0.19), (0.0, 0.0, 0.0)),
        "GooSideLeft": ((0.19, 0.012, 0.0), (0.0, 0.0, 0.0)),
        "GooSideRight": ((-0.19, 0.012, 0.0), (0.0, 0.0, 0.0)),
    },
    30: {
        "GooLower": ((0.0, 0.025, 0.0), (0.0, 0.0, 0.0)),
        "GooMid": ((0.014, 0.145, 0.0), (0.0, 0.0, 0.025)),
        "GooUpper": ((0.032, 0.46, -0.008), (-0.035, 0.0, 0.050)),
        "GooSideFront": ((0.0, 0.01, 0.16), (0.0, 0.0, 0.0)),
        "GooSideBack": ((0.0, 0.01, -0.16), (0.0, 0.0, 0.0)),
        "GooSideLeft": ((0.16, 0.01, 0.0), (0.0, 0.0, 0.0)),
        "GooSideRight": ((-0.16, 0.01, 0.0), (0.0, 0.0, 0.0)),
    },
    31: {
        "GooLower": ((0.0, 0.024, 0.0), (0.0, 0.0, 0.0)),
        "GooMid": ((0.012, 0.14, 0.0), (0.0, 0.0, 0.022)),
        "GooUpper": ((0.026, 0.445, -0.007), (-0.03, 0.0, 0.042)),
        "GooSideFront": ((0.0, 0.009, 0.155), (0.0, 0.0, 0.0)),
        "GooSideBack": ((0.0, 0.009, -0.155), (0.0, 0.0, 0.0)),
        "GooSideLeft": ((0.155, 0.009, 0.0), (0.0, 0.0, 0.0)),
        "GooSideRight": ((-0.155, 0.009, 0.0), (0.0, 0.0, 0.0)),
    },
    32: {
        "GooLower": ((0.0, 0.023, 0.0), (0.0, 0.0, 0.0)),
        "GooMid": ((0.009, 0.135, 0.0), (0.0, 0.0, 0.016)),
        "GooUpper": ((0.018, 0.43, -0.006), (-0.022, 0.0, 0.032)),
        "GooSideFront": ((0.0, 0.008, 0.15), (0.0, 0.0, 0.0)),
        "GooSideBack": ((0.0, 0.008, -0.15), (0.0, 0.0, 0.0)),
        "GooSideLeft": ((0.15, 0.008, 0.0), (0.0, 0.0, 0.0)),
        "GooSideRight": ((-0.15, 0.008, 0.0), (0.0, 0.0, 0.0)),
    },
    33: {
        "GooLower": ((0.0, 0.022, 0.0), (0.0, 0.0, 0.0)),
        "GooMid": ((0.006, 0.13, 0.0), (0.0, 0.0, 0.010)),
        "GooUpper": ((0.010, 0.415, -0.004), (-0.014, 0.0, 0.020)),
        "GooSideFront": ((0.0, 0.008, 0.145), (0.0, 0.0, 0.0)),
        "GooSideBack": ((0.0, 0.008, -0.145), (0.0, 0.0, 0.0)),
        "GooSideLeft": ((0.145, 0.008, 0.0), (0.0, 0.0, 0.0)),
        "GooSideRight": ((-0.145, 0.008, 0.0), (0.0, 0.0, 0.0)),
    },
    34: {
        "GooLower": ((0.0, 0.021, 0.0), (0.0, 0.0, 0.0)),
        "GooMid": ((0.003, 0.125, 0.0), (0.0, 0.0, 0.004)),
        "GooUpper": ((0.004, 0.40, -0.002), (-0.006, 0.0, 0.008)),
        "GooSideFront": ((0.0, 0.007, 0.14), (0.0, 0.0, 0.0)),
        "GooSideBack": ((0.0, 0.007, -0.14), (0.0, 0.0, 0.0)),
        "GooSideLeft": ((0.14, 0.007, 0.0), (0.0, 0.0, 0.0)),
        "GooSideRight": ((-0.14, 0.007, 0.0), (0.0, 0.0, 0.0)),
    },
    35: {
        "GooLower": ((0.0, 0.02, 0.0), (0.0, 0.0, 0.0)),
        "GooMid": ((0.0, 0.12, 0.0), (0.0, 0.0, 0.0)),
        "GooUpper": ((0.0, 0.39, 0.0), (0.0, 0.0, 0.0)),
        "GooSideFront": ((0.0, 0.007, 0.14), (0.0, 0.0, 0.0)),
        "GooSideBack": ((0.0, 0.007, -0.14), (0.0, 0.0, 0.0)),
        "GooSideLeft": ((0.14, 0.007, 0.0), (0.0, 0.0, 0.0)),
        "GooSideRight": ((-0.14, 0.007, 0.0), (0.0, 0.0, 0.0)),
    },
    40: {
        "GooLower": ((0.0, 0.02, 0.0), (0.0, 0.0, 0.0)),
        "GooMid": ((-0.008, 0.115, 0.0), (0.0, 0.0, -0.012)),
        "GooUpper": ((-0.018, 0.40, -0.003), (0.018, 0.0, -0.025)),
        "GooSideFront": ((0.0, 0.008, 0.15), (0.0, 0.0, 0.0)),
        "GooSideBack": ((0.0, 0.008, -0.15), (0.0, 0.0, 0.0)),
        "GooSideLeft": ((0.15, 0.008, 0.0), (0.0, 0.0, 0.0)),
        "GooSideRight": ((-0.15, 0.008, 0.0), (0.0, 0.0, 0.0)),
    },
    44: {
        "GooLower": ((0.0, 0.005, 0.0), (0.0, 0.0, 0.0)),
        "GooMid": ((-0.012, 0.08, 0.0), (0.0, 0.0, -0.018)),
        "GooUpper": ((-0.03, 0.43, -0.003), (0.03, 0.0, -0.04)),
        "GooSideFront": ((0.0, 0.01, 0.18), (0.0, 0.0, 0.0)),
        "GooSideBack": ((0.0, 0.01, -0.18), (0.0, 0.0, 0.0)),
        "GooSideLeft": ((0.18, 0.01, 0.0), (0.0, 0.0, 0.0)),
        "GooSideRight": ((-0.18, 0.01, 0.0), (0.0, 0.0, 0.0)),
    },
    48: {
        "GooLower": ((0.0, -0.025, 0.0), (0.0, 0.0, 0.0)),
        "GooMid": ((-0.016, -0.035, 0.0), (0.0, 0.0, -0.024)),
        "GooUpper": ((-0.044, 0.46, 0.0), (0.044, 0.0, -0.065)),
        "GooSideFront": ((0.0, 0.012, 0.21), (0.0, 0.0, 0.0)),
        "GooSideBack": ((0.0, 0.012, -0.21), (0.0, 0.0, 0.0)),
        "GooSideLeft": ((0.21, 0.012, 0.0), (0.0, 0.0, 0.0)),
        "GooSideRight": ((-0.21, 0.012, 0.0), (0.0, 0.0, 0.0)),
    },
    51: {
        "GooLower": ((0.0, -0.035, 0.0), (0.0, 0.0, 0.0)),
        "GooMid": ((-0.018, -0.08, 0.0), (0.0, 0.0, -0.025)),
        "GooUpper": ((-0.05, 0.46, 0.0), (0.05, 0.0, -0.075)),
        "GooSideFront": ((0.0, 0.012, 0.22), (0.0, 0.0, 0.0)),
        "GooSideBack": ((0.0, 0.012, -0.22), (0.0, 0.0, 0.0)),
        "GooSideLeft": ((0.22, 0.012, 0.0), (0.0, 0.0, 0.0)),
        "GooSideRight": ((-0.22, 0.012, 0.0), (0.0, 0.0, 0.0)),
    },
    # First contact retains the falling stretch. The root is on the ground,
    # but the upper mass has not yet had time to collapse.
    52: {
        "GooLower": ((0.0, -0.035, 0.0), (0.0, 0.0, 0.0)),
        "GooMid": ((-0.018, -0.08, 0.0), (0.0, 0.0, -0.025)),
        "GooUpper": ((-0.05, 0.46, 0.0), (0.05, 0.0, -0.075)),
        "GooSideFront": ((0.0, 0.012, 0.22), (0.0, 0.0, 0.0)),
        "GooSideBack": ((0.0, 0.012, -0.22), (0.0, 0.0, 0.0)),
        "GooSideLeft": ((0.22, 0.012, 0.0), (0.0, 0.0, 0.0)),
        "GooSideRight": ((-0.22, 0.012, 0.0), (0.0, 0.0, 0.0)),
    },
    # One frame after contact, compression propagates upward: the lower mass
    # spreads first while the top is still catching up under inertia.
    53: {
        "GooLower": ((0.0, -0.055, 0.0), (0.0, 0.0, 0.0)),
        "GooMid": ((-0.01, -0.12, 0.0), (0.0, 0.0, -0.015)),
        "GooUpper": ((-0.025, 0.18, 0.0), (0.025, 0.0, -0.04)),
        "GooSideFront": ((0.0, 0.006, -0.18), (0.0, 0.0, 0.0)),
        "GooSideBack": ((0.0, 0.006, 0.18), (0.0, 0.0, 0.0)),
        "GooSideLeft": ((-0.15, 0.006, 0.0), (0.0, 0.0, 0.0)),
        "GooSideRight": ((0.15, 0.006, 0.0), (0.0, 0.0, 0.0)),
    },
    54: {
        "GooLower": ((0.0, -0.02, 0.0), (0.0, 0.0, 0.0)),
        "GooMid": ((-0.006, -0.06, 0.0), (0.0, 0.0, -0.01)),
        "GooUpper": ((-0.012, -0.08, 0.0), (0.015, 0.0, -0.015)),
        "GooSideFront": ((0.0, 0.002, -0.20), (0.0, 0.0, 0.0)),
        "GooSideBack": ((0.0, 0.002, 0.20), (0.0, 0.0, 0.0)),
        "GooSideLeft": ((-0.20, 0.002, 0.0), (0.0, 0.0, 0.0)),
        "GooSideRight": ((0.20, 0.002, 0.0), (0.0, 0.0, 0.0)),
    },
    55: {
        # Maximum impact spreads the middle radially while shortening all
        # three vertical controls. The upper mass still leads slightly to one
        # side, so the result reads as fluid displacement rather than a lid
        # folding inward.
        # The actual flattening is a uniform inherited vertical scale on the
        # root's children. These small offsets keep a hint of internal lag
        # without pulling the crown below a GooMid-controlled annular ridge.
        "GooLower": ((0.0, -0.03, 0.0), (0.0, 0.0, 0.0)),
        "GooMid": ((-0.006, -0.10, 0.0), (0.0, 0.0, -0.01)),
        "GooUpper": ((-0.012, -0.15, 0.0), (0.015, 0.0, -0.015)),
        "GooSideFront": ((0.0, 0.0, -0.40), (0.0, 0.0, 0.0)),
        "GooSideBack": ((0.0, 0.0, 0.40), (0.0, 0.0, 0.0)),
        "GooSideLeft": ((-0.40, 0.0, 0.0), (0.0, 0.0, 0.0)),
        "GooSideRight": ((0.40, 0.0, 0.0), (0.0, 0.0, 0.0)),
    },
    58: {
        "GooLower": ((0.0, -0.025, 0.0), (0.0, 0.0, 0.0)),
        "GooMid": ((0.004, -0.08, 0.0), (0.0, 0.0, 0.008)),
        "GooUpper": ((0.010, -0.10, 0.0), (-0.012, 0.0, 0.012)),
        "GooSideFront": ((0.0, 0.0, -0.30), (0.0, 0.0, 0.0)),
        "GooSideBack": ((0.0, 0.0, 0.30), (0.0, 0.0, 0.0)),
        "GooSideLeft": ((-0.30, 0.0, 0.0), (0.0, 0.0, 0.0)),
        "GooSideRight": ((0.30, 0.0, 0.0), (0.0, 0.0, 0.0)),
    },
}

# Authoritative airborne silhouette layered over the directional poses above.
# Vertical displacement is distributed across three mass controls instead of
# pulling only the crown upward; uniform radial contraction keeps the result
# column-like and malleable instead of tapered like a gumdrop.
HOP_LIQUID_PROFILE = {
    18: (0.080, 0.280, 0.680, 0.25),
    24: (0.070, 0.340, 0.900, 0.30),
    # Gravity removes vertical speed toward the apex, so the unsupported mass
    # relaxes toward a rounder pose instead of holding one rigid air column.
    30: (0.045, 0.200, 0.550, 0.20),
    31: (0.040, 0.160, 0.450, 0.16),
    32: (0.035, 0.130, 0.360, 0.12),
    33: (0.030, 0.100, 0.290, 0.10),
    34: (0.025, 0.080, 0.240, 0.08),
    35: (0.020, 0.070, 0.200, 0.06),
    # Stretch rebuilds as downward velocity increases, with the crown lagging
    # behind the falling root until first contact.
    40: (0.035, 0.150, 0.420, 0.14),
    44: (0.050, 0.280, 0.720, 0.24),
    48: (0.020, 0.200, 0.980, 0.34),
    51: (-0.025, -0.020, 0.900, 0.38),
    52: (-0.025, -0.020, 0.900, 0.40),
}

# GooRootBone uniformly thins the entire body; GooBase then trims the heavily
# base-weighted bottom ring to match the lower body. The side controls above
# remain deliberately mild so they read as a ripple instead of a cinched waist.
HOP_RADIAL_SCALE_PROFILE = {
    1: (1.00, 1.00),
    14: (1.00, 1.00),
    18: (0.94, 0.92),
    24: (0.87, 0.86),
    30: (0.85, 0.84),
    31: (0.845, 0.84),
    32: (0.84, 0.835),
    33: (0.835, 0.83),
    34: (0.838, 0.835),
    35: (0.84, 0.84),
    40: (0.85, 0.85),
    44: (0.87, 0.87),
    48: (0.90, 0.90),
    51: (0.94, 0.94),
    52: (0.95, 0.95),
    53: (1.00, 1.08),
    54: (1.00, 1.20),
    55: (1.00, 1.40),
    58: (1.00, 1.30),
    61: (1.00, 1.15),
    64: (1.00, 1.05),
    67: (1.00, 1.00),
    72: (1.00, 1.00),
}

# Once the footprint hits, radial pressure begins at the ground and only then
# reaches the middle. The footprint remains broad during the first rebound so
# the goo appears to adhere briefly before retracting.
HOP_IMPACT_SPREAD_PROFILE = {
    53: 0.08,
    54: 0.20,
    55: 0.40,
    58: 0.30,
    61: 0.12,
    64: 0.04,
    67: 0.00,
    72: 0.00,
}

HOP_VERTICAL_SCALE_PROFILE = {
    1: 1.00,
    52: 1.00,
    53: 0.88,
    54: 0.70,
    55: 0.50,
    58: 0.65,
    61: 1.00,
    64: 1.00,
    72: 1.00,
}


def iter_fcurves(action):
    """Return f-curves for both legacy and Blender 4.4+ layered actions."""
    if hasattr(action, "fcurves"):
        return list(action.fcurves)
    curves = []
    for layer in action.layers:
        for strip in layer.strips:
            for channelbag in strip.channelbags:
                curves.extend(channelbag.fcurves)
    return curves


def require_scene_data():
    source_path = Path(bpy.data.filepath)
    if source_path.name != "goo2.blend":
        raise RuntimeError(f"Expected goo2.blend, opened {source_path}")
    armature = bpy.data.objects.get(ARMATURE_NAME)
    if armature is None or armature.type != "ARMATURE":
        raise RuntimeError(f"Missing armature {ARMATURE_NAME!r}")
    meshes = []
    for name in MESH_NAMES:
        mesh = bpy.data.objects.get(name)
        if mesh is None or mesh.type != "MESH":
            raise RuntimeError(f"Missing mesh {name!r}")
        if mesh.parent != armature:
            raise RuntimeError(f"{name} is not parented to {ARMATURE_NAME}")
        meshes.append(mesh)
    for name in (HOP_SOURCE, HEALING_SOURCE):
        if bpy.data.actions.get(name) is None:
            raise RuntimeError(f"Missing source action {name!r}")
    return source_path, armature


def remove_action_if_present(name):
    action = bpy.data.actions.get(name)
    if action is not None:
        bpy.data.actions.remove(action)


def remap_time(frame):
    for index in range(len(HOP_TIME_REMAP) - 1):
        old_a, new_a = HOP_TIME_REMAP[index]
        old_b, new_b = HOP_TIME_REMAP[index + 1]
        if frame <= old_b:
            alpha = (frame - old_a) / (old_b - old_a)
            return new_a + alpha * (new_b - new_a)
    return frame


def deformation_scale(frame):
    for index in range(len(HOP_DEFORMATION_SCALE) - 1):
        frame_a, scale_a = HOP_DEFORMATION_SCALE[index]
        frame_b, scale_b = HOP_DEFORMATION_SCALE[index + 1]
        if frame <= frame_b:
            alpha = (frame - frame_a) / (frame_b - frame_a)
            return scale_a + alpha * (scale_b - scale_a)
    return 1.0


def replace_root_arc(curve):
    points = curve.keyframe_points
    while len(points):
        points.remove(points[-1], fast=True)

    points.insert(HOP_RANGE[0], 0.0, options={"FAST"})
    for frame in range(HOP_TAKEOFF_FRAME, HOP_LAND_FRAME + 1):
        progress = (frame - HOP_TAKEOFF_FRAME) / (
            HOP_LAND_FRAME - HOP_TAKEOFF_FRAME
        )
        # A parabola gives constant downward acceleration: rapid separation
        # from the ground, a readable apex, then accelerating descent.
        height = 4.0 * HOP_PEAK_HEIGHT * progress * (1.0 - progress)
        points.insert(frame, height, options={"FAST"})
    points.insert(HOP_RANGE[1], 0.0, options={"FAST"})
    for key in points:
        key.interpolation = "LINEAR"
    curve.update()


def set_curve_key(action, data_path, array_index, frame, value):
    curve = next(
        (
            candidate
            for candidate in iter_fcurves(action)
            if candidate.data_path == data_path
            and candidate.array_index == array_index
        ),
        None,
    )
    if curve is None:
        raise RuntimeError(f"Missing curve {data_path}[{array_index}]")
    key = next(
        (
            candidate
            for candidate in curve.keyframe_points
            if abs(candidate.co.x - frame) < 1e-5
        ),
        None,
    )
    if key is None:
        key = curve.keyframe_points.insert(frame, value, options={"FAST"})
    else:
        key.co.y = value
    key.interpolation = "BEZIER"
    key.handle_left_type = "AUTO_CLAMPED"
    key.handle_right_type = "AUTO_CLAMPED"
    curve.update()


def polish_airborne_poses(action):
    for frame, bones in HOP_AIRBORNE_POSES.items():
        liquid_profile = HOP_LIQUID_PROFILE.get(frame)
        for bone_name, (location, rotation) in bones.items():
            location = list(location)
            rotation = list(rotation)
            if liquid_profile:
                lower_y, mid_y, upper_y, radial = liquid_profile
                if bone_name == "GooLower":
                    location[1] = lower_y
                elif bone_name == "GooMid":
                    location[1] = mid_y
                elif bone_name == "GooUpper":
                    location[1] = upper_y
                elif bone_name == "GooSideFront":
                    location[2] = radial
                elif bone_name == "GooSideBack":
                    location[2] = -radial
                elif bone_name == "GooSideLeft":
                    location[0] = radial
                elif bone_name == "GooSideRight":
                    location[0] = -radial
            if bone_name in {"GooMid", "GooUpper"}:
                # A visible phase lag travels through the unsupported mass:
                # ascent carries the upper body to one side, then descent
                # reverses it. Keep this off the radial side controls so the
                # volume-preserving silhouette remains independently authored.
                lag_scale = 2.5 if frame <= HOP_LAND_FRAME else 1.8
                location[0] *= lag_scale
                rotation[0] *= 1.3
                rotation[2] *= min(lag_scale, 1.9)
            location_path = f'pose.bones["{bone_name}"].location'
            rotation_path = f'pose.bones["{bone_name}"].rotation_euler'
            for index, value in enumerate(location):
                set_curve_key(action, location_path, index, frame, value)
            for index, value in enumerate(rotation):
                set_curve_key(action, rotation_path, index, frame, value)

    armature = bpy.data.objects[ARMATURE_NAME]
    armature.animation_data_create()
    armature.animation_data.action = action
    for frame, (root_scale, base_scale) in HOP_RADIAL_SCALE_PROFILE.items():
        for bone_name, radial_scale in (
            ("GooRootBone", root_scale),
            ("GooBase", base_scale),
        ):
            pose_bone = armature.pose.bones[bone_name]
            pose_bone.scale = (radial_scale, 1.0, radial_scale)
            pose_bone.keyframe_insert(data_path="scale", frame=frame, group=bone_name)

    root = armature.pose.bones["GooRootBone"]
    for frame, vertical_scale in HOP_VERTICAL_SCALE_PROFILE.items():
        bpy.context.scene.frame_set(frame)
        root.scale.y = vertical_scale
        root.keyframe_insert(data_path="scale", frame=frame, group=root.name)

    for curve in iter_fcurves(action):
        if curve.data_path not in {
            'pose.bones["GooRootBone"].scale',
            'pose.bones["GooBase"].scale',
        }:
            continue
        for key in curve.keyframe_points:
            key.interpolation = "BEZIER"
            key.handle_left_type = "AUTO_CLAMPED"
            key.handle_right_type = "AUTO_CLAMPED"
        curve.update()

    impact_channels = {
        "GooSideFront": (2, -1.0),
        "GooSideBack": (2, 1.0),
        "GooSideLeft": (0, -1.0),
        "GooSideRight": (0, 1.0),
    }
    for frame, spread in HOP_IMPACT_SPREAD_PROFILE.items():
        for bone_name, (array_index, direction) in impact_channels.items():
            set_curve_key(
                action,
                f'pose.bones["{bone_name}"].location',
                array_index,
                frame,
                spread * direction,
            )


def build_hop_action():
    remove_action_if_present(HOP_ACTION)
    action = bpy.data.actions[HOP_SOURCE].copy()
    action.name = HOP_ACTION
    action.use_fake_user = True
    action.use_frame_range = True
    action.frame_start, action.frame_end = HOP_RANGE

    root_vertical_curve = None
    for curve in iter_fcurves(action):
        is_root_location = curve.data_path == 'pose.bones["GooRootBone"].location'
        if is_root_location and curve.array_index == 1:
            root_vertical_curve = curve
        for key in curve.keyframe_points:
            old_frame = key.co.x
            pose_scale = deformation_scale(old_frame)
            new_frame = remap_time(old_frame)
            handle_left_offset = key.handle_left.x - old_frame
            handle_right_offset = key.handle_right.x - old_frame
            key.co.x = new_frame
            key.handle_left.x = new_frame + handle_left_offset
            key.handle_right.x = new_frame + handle_right_offset
            key.interpolation = "BEZIER"
            key.handle_left_type = "AUTO_CLAMPED"
            key.handle_right_type = "AUTO_CLAMPED"
            if is_root_location and curve.array_index != 1:
                key.co.y = 0.0
                key.handle_left.y = 0.0
                key.handle_right.y = 0.0
            elif not is_root_location:
                baseline = 1.0 if curve.data_path.endswith(".scale") else 0.0
                key.co.y = baseline + (key.co.y - baseline) * pose_scale
                key.handle_left.y = baseline + (
                    key.handle_left.y - baseline
                ) * pose_scale
                key.handle_right.y = baseline + (
                    key.handle_right.y - baseline
                ) * pose_scale
        curve.update()

    if root_vertical_curve is None:
        raise RuntimeError("GooHop has no GooRootBone vertical location curve")
    replace_root_arc(root_vertical_curve)
    polish_airborne_poses(action)

    actual_range = tuple(round(value) for value in action.frame_range)
    if actual_range != HOP_RANGE:
        raise RuntimeError(f"{HOP_ACTION} range {actual_range}, expected {HOP_RANGE}")
    actual_peak = max(
        abs(key.co.y) for key in root_vertical_curve.keyframe_points
    )
    if abs(actual_peak - HOP_PEAK_HEIGHT) > 1e-6:
        raise RuntimeError(
            f"Hop peak is {actual_peak}, expected {HOP_PEAK_HEIGHT}"
        )
    return action


def build_healing_action():
    remove_action_if_present(HEALING_ACTION)
    action = bpy.data.actions[HEALING_SOURCE].copy()
    action.name = HEALING_ACTION
    action.use_fake_user = True
    action.use_frame_range = True
    action.frame_start, action.frame_end = HEALING_RANGE

    for curve in iter_fcurves(action):
        points = curve.keyframe_points
        if len(points) < 2:
            raise RuntimeError(f"Healing source curve has fewer than two keys: {curve.data_path}")
        first_value = points[0].co.y
        last_value = points[-1].co.y
        while len(points) > 2:
            points.remove(points[1], fast=True)
        points[0].co = (HEALING_RANGE[0], first_value)
        points[1].co = (HEALING_RANGE[1], last_value)
        for key in points:
            key.interpolation = "LINEAR"
        curve.update()

    actual_range = tuple(round(value) for value in action.frame_range)
    if actual_range != HEALING_RANGE:
        raise RuntimeError(
            f"{HEALING_ACTION} range {actual_range}, expected {HEALING_RANGE}"
        )
    return action


def reset_pose(armature):
    armature.animation_data_create()
    armature.animation_data.action = None
    for pose_bone in armature.pose.bones:
        pose_bone.matrix_basis.identity()
    bpy.context.scene.frame_set(1)
    bpy.context.view_layer.update()


def evaluated_body_metrics(body):
    depsgraph = bpy.context.evaluated_depsgraph_get()
    evaluated = body.evaluated_get(depsgraph)
    points = [evaluated.matrix_world @ Vector(corner) for corner in evaluated.bound_box]
    return {
        "min_z": min(point.z for point in points),
        "height": max(point.z for point in points) - min(point.z for point in points),
        "width": max(point.x for point in points) - min(point.x for point in points),
    }


def evaluated_body_volume(body):
    depsgraph = bpy.context.evaluated_depsgraph_get()
    evaluated = body.evaluated_get(depsgraph)
    mesh = evaluated.to_mesh()
    try:
        geometry = bmesh.new()
        try:
            geometry.from_mesh(mesh)
            local_volume = abs(geometry.calc_volume(signed=True))
        finally:
            geometry.free()
        return local_volume * abs(evaluated.matrix_world.to_3x3().determinant())
    finally:
        evaluated.to_mesh_clear()


def evaluated_surface_health(body):
    depsgraph = bpy.context.evaluated_depsgraph_get()
    evaluated = body.evaluated_get(depsgraph)
    mesh = evaluated.to_mesh()
    try:
        world = evaluated.matrix_world
        vertices = [world @ vertex.co for vertex in mesh.vertices]
        polygons = [tuple(polygon.vertices) for polygon in mesh.polygons]
        center_x = (max(point.x for point in vertices) + min(point.x for point in vertices)) / 2
        center_y = (max(point.y for point in vertices) + min(point.y for point in vertices)) / 2
        radii = [
            ((point.x - center_x) ** 2 + (point.y - center_y) ** 2) ** 0.5
            for point in vertices
        ]
        max_radius = max(radii)
        center_top = max(
            point.z
            for point, radius in zip(vertices, radii)
            if radius / max_radius < 0.15
        )
        ridge_top = max(
            point.z
            for point, radius in zip(vertices, radii)
            if 0.25 < radius / max_radius < 0.80
        )
        tree = BVHTree.FromPolygons(vertices, polygons, all_triangles=False)
        nonadjacent_overlaps = 0
        for first, second in tree.overlap(tree):
            if first >= second:
                continue
            if set(polygons[first]).isdisjoint(polygons[second]):
                nonadjacent_overlaps += 1
        return {
            "minimum_face_area": min(polygon.area for polygon in mesh.polygons),
            "nonadjacent_overlaps": nonadjacent_overlaps,
            "ridge_above_center": ridge_top - center_top,
        }
    finally:
        evaluated.to_mesh_clear()


def conserve_action_volume(armature, body, action, frame_range, tolerance=0.004):
    """Bake radial compensation so the exported skeleton behaves like liquid.

    Preserve Volume helps Blender interpolate rotated skin, but it cannot undo
    volume changes authored through translated and scaled bones. Radially
    scaling the non-deforming root's children keeps those deliberate poses and
    their footprint hierarchy while restoring near-incompressible volume.
    """
    armature.animation_data_create()
    armature.animation_data.action = action
    root = armature.pose.bones["GooRootBone"]
    bpy.context.scene.frame_set(frame_range[0])
    bpy.context.view_layer.update()
    target_volume = evaluated_body_volume(body)

    for _pass in range(3):
        corrections = []
        for frame in range(frame_range[0], frame_range[1] + 1):
            bpy.context.scene.frame_set(frame)
            bpy.context.view_layer.update()
            volume = evaluated_body_volume(body)
            factor = (target_volume / volume) ** 0.5
            corrections.append((frame, root.scale.copy(), factor))

        for frame, scale, factor in corrections:
            bpy.context.scene.frame_set(frame)
            root.scale = (scale.x * factor, scale.y, scale.z * factor)
            root.keyframe_insert(data_path="scale", frame=frame, group=root.name)

        for curve in iter_fcurves(action):
            if (
                curve.data_path == 'pose.bones["GooRootBone"].scale'
                and curve.array_index in {0, 2}
            ):
                for key in curve.keyframe_points:
                    key.interpolation = "LINEAR"
                curve.update()

        ratios = []
        for frame in range(frame_range[0], frame_range[1] + 1):
            bpy.context.scene.frame_set(frame)
            bpy.context.view_layer.update()
            ratios.append(evaluated_body_volume(body) / target_volume)
        max_error = max(abs(ratio - 1.0) for ratio in ratios)
        if max_error <= tolerance:
            return {
                "target": target_volume,
                "minimum_ratio": min(ratios),
                "maximum_ratio": max(ratios),
                "max_error": max_error,
            }
    raise RuntimeError(
        f"{action.name} volume compensation failed: "
        f"range {min(ratios):.6f}..{max(ratios):.6f}"
    )


def pin_ground_contact(armature, body, action, frames):
    armature.animation_data_create()
    armature.animation_data.action = action
    root = armature.pose.bones["GooRootBone"]
    bpy.context.scene.frame_set(1)
    bpy.context.view_layer.update()
    target_ground = evaluated_body_metrics(body)["min_z"]
    offsets = []
    for frame in frames:
        bpy.context.scene.frame_set(frame)
        bpy.context.view_layer.update()
        offsets.append(
            (
                frame,
                root.location.y
                + target_ground
                - evaluated_body_metrics(body)["min_z"],
            )
        )
    for frame, corrected_location in offsets:
        bpy.context.scene.frame_set(frame)
        root.location.y = corrected_location
        root.keyframe_insert(data_path="location", frame=frame, group=root.name)
    curve = next(
        curve
        for curve in iter_fcurves(action)
        if curve.data_path == 'pose.bones["GooRootBone"].location'
        and curve.array_index == 1
    )
    for key in curve.keyframe_points:
        key.interpolation = "LINEAR"
    curve.update()
    return target_ground


def evaluated_band_widths(body, band_count=5):
    depsgraph = bpy.context.evaluated_depsgraph_get()
    evaluated = body.evaluated_get(depsgraph)
    mesh = evaluated.to_mesh()
    try:
        points = [evaluated.matrix_world @ vertex.co for vertex in mesh.vertices]
        min_z = min(point.z for point in points)
        height = max(point.z for point in points) - min_z
        widths = []
        for band_index in range(band_count):
            band = [
                point
                for point in points
                if band_index / band_count
                <= (point.z - min_z) / height
                <= (band_index + 1) / band_count
            ]
            widths.append(max(point.x for point in band) - min(point.x for point in band))
        return widths
    finally:
        evaluated.to_mesh_clear()


def validate_hop_physics(armature, body, action):
    armature.animation_data_create()
    armature.animation_data.action = action
    samples = {}
    for frame in (1, 18, 24, 30, 35, 40, 44, 48, 51, 52, 53, 54, 55, 58, 61, 64):
        bpy.context.scene.frame_set(frame)
        bpy.context.view_layer.update()
        samples[frame] = evaluated_body_metrics(body)
        samples[frame]["volume"] = evaluated_body_volume(body)
        samples[frame]["band_widths"] = evaluated_band_widths(body)
        samples[frame]["root_height"] = armature.pose.bones[
            "GooRootBone"
        ].location.y

    if samples[51]["root_height"] < 0.4 or abs(samples[52]["root_height"]) > 1e-6:
        raise RuntimeError(f"Hop contact timing is invalid: {samples}")
    if samples[51]["height"] < 2.2 or samples[52]["height"] < 2.2:
        raise RuntimeError(f"Hop compresses before first contact: {samples}")
    if samples[55]["height"] > 1.4:
        raise RuntimeError(f"Hop lacks a post-contact squash: {samples}")
    if samples[53]["height"] >= samples[52]["height"]:
        raise RuntimeError(f"Hop compression does not propagate after contact: {samples}")
    impact_widths = samples[55]["band_widths"]
    if any(impact_widths[index] < impact_widths[index + 1] for index in range(4)):
        raise RuntimeError(f"Hop maximum impact does not spread from the ground upward: {samples}")
    if not (
        samples[53]["band_widths"][0]
        < samples[54]["band_widths"][0]
        < samples[55]["band_widths"][0]
    ):
        raise RuntimeError(f"Hop footprint does not spread progressively after contact: {samples}")
    if samples[58]["band_widths"][0] < samples[58]["band_widths"][1]:
        raise RuntimeError(f"Hop footprint retracts before the rebound begins: {samples}")
    for frame in (54, 55, 58):
        bpy.context.scene.frame_set(frame)
        bpy.context.view_layer.update()
        health = evaluated_surface_health(body)
        if health["nonadjacent_overlaps"] or health["minimum_face_area"] < 1e-6:
            raise RuntimeError(f"Hop surface folds at frame {frame}: {health}")
        if frame == 55 and health["ridge_above_center"] > 0.04:
            raise RuntimeError(f"Hop forms an annular impact ridge: {health}")
    fast_air_frames = (24, 48, 51)
    if min(samples[frame]["height"] for frame in fast_air_frames) < samples[1]["height"] * 1.30:
        raise RuntimeError(f"Hop does not stretch with airborne speed: {samples}")
    if max(samples[frame]["width"] for frame in fast_air_frames) > samples[1]["width"] * 0.94:
        raise RuntimeError(f"Hop fast-air silhouette is too wide: {samples}")
    if samples[35]["height"] > samples[24]["height"] * 0.90:
        raise RuntimeError(f"Hop does not relax at its zero-velocity apex: {samples}")
    if samples[35]["width"] <= samples[24]["width"]:
        raise RuntimeError(f"Hop apex does not recover radial volume: {samples}")
    for frame in (24, 30, 35, 40, 44):
        lower_bands = samples[frame]["band_widths"][:3]
        if lower_bands[0] > lower_bands[1] * 1.08:
            raise RuntimeError(f"Hop base remains wider than its lower body: {samples}")
        if min(lower_bands) < max(lower_bands) * 0.78:
            raise RuntimeError(f"Hop has an hourglass waist: {samples}")
    target_volume = samples[1]["volume"]
    if max(
        abs(sample["volume"] / target_volume - 1.0)
        for sample in samples.values()
    ) > 0.006:
        raise RuntimeError(f"Hop does not conserve liquid volume: {samples}")
    if abs(samples[52]["min_z"] - samples[1]["min_z"]) > 2e-3:
        raise RuntimeError(f"Hop first contact misses the ground plane: {samples}")
    for frame in (52, 53, 54, 55, 58, 61, 64):
        if abs(samples[frame]["min_z"] - samples[1]["min_z"]) > 2e-3:
            raise RuntimeError(f"Hop loses grounded contact at frame {frame}: {samples}")
    return samples


def select_only(objects, active):
    if bpy.context.object and bpy.context.object.mode != "OBJECT":
        bpy.ops.object.mode_set(mode="OBJECT")
    bpy.ops.object.select_all(action="DESELECT")
    for obj in objects:
        obj.select_set(True)
    bpy.context.view_layer.objects.active = active


def common_export_settings(filepath, object_types):
    return {
        "filepath": str(filepath),
        "check_existing": False,
        "use_selection": True,
        "object_types": object_types,
        "global_scale": 1.0,
        "apply_unit_scale": True,
        "apply_scale_options": "FBX_SCALE_UNITS",
        "use_space_transform": True,
        "bake_space_transform": False,
        "axis_forward": "-Z",
        "axis_up": "Y",
        "use_custom_props": False,
        "add_leaf_bones": False,
        "primary_bone_axis": "Y",
        "secondary_bone_axis": "X",
        "use_armature_deform_only": False,
        "armature_nodetype": "NULL",
    }


def export_action(armature, action, filepath, frame_range):
    armature.animation_data_create()
    armature.animation_data.action = action
    bpy.context.scene.frame_start, bpy.context.scene.frame_end = frame_range
    # The Hop finishes in the neutral pose. FBX derives its embedded armature
    # bind pose from the currently evaluated frame, so export from that neutral
    # endpoint even though the complete range is baked.
    bpy.context.scene.frame_set(frame_range[1])
    select_only([armature], armature)
    settings = common_export_settings(filepath, {"ARMATURE"})
    settings.update(
        {
            "bake_anim": True,
            "bake_anim_use_all_bones": True,
            "bake_anim_use_nla_strips": False,
            "bake_anim_use_all_actions": False,
            "bake_anim_force_startend_keying": True,
            "bake_anim_step": 1.0,
            "bake_anim_simplify_factor": 0.0,
        }
    )
    bpy.ops.export_scene.fbx(**settings)


def main():
    source_path, armature = require_scene_data()
    blender_dir = source_path.parent.parent
    output_dir = blender_dir / "exports"
    output_dir.mkdir(parents=True, exist_ok=True)
    review_dir = blender_dir / "reviews"
    review_dir.mkdir(parents=True, exist_ok=True)
    review_blend_path = review_dir / "goo2_review.blend"

    hop_action = build_hop_action()
    build_healing_action()
    hop_volume = conserve_action_volume(
        armature, bpy.data.objects["SlimeBody"], hop_action, HOP_RANGE
    )
    hop_ground = pin_ground_contact(
        armature,
        bpy.data.objects["SlimeBody"],
        hop_action,
        range(HOP_LAND_FRAME, HOP_RANGE[1] + 1),
    )
    hop_physics = validate_hop_physics(
        armature, bpy.data.objects["SlimeBody"], hop_action
    )
    reset_pose(armature)
    bpy.context.scene.frame_start = 1
    bpy.context.scene.frame_end = max(HOP_RANGE[1], HEALING_RANGE[1])
    bpy.ops.wm.save_as_mainfile(filepath=str(review_blend_path), check_existing=False)

    hop_fbx = output_dir / "goo2_hop_integrated.fbx"
    export_action(armature, hop_action, hop_fbx, HOP_RANGE)

    print("GOO2_REVIEW_BLEND", review_blend_path)
    print("GOO2_HOP_VOLUME", hop_volume)
    print("GOO2_HOP_GROUND", hop_ground)
    print("GOO2_HOP_PHYSICS", hop_physics)
    print("GOO2_HOP_EXPORT", hop_fbx)


main()
