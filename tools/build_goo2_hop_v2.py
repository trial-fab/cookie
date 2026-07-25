"""Author a fresh, feel-first Hop clip (v2) for the goo rig.

Run from the ClickGame repository root:

    /tmp/blender-5.1.2/blender -b docs/blender/sources/goo2.blend \
        --python tools/build_goo2_hop_v2.py

This is a from-scratch experiment, not a modification of the existing
GooHopIntegrated pipeline. It keeps the shared skeleton and the frame landmarks
the runtime already depends on (72 frames, takeoff ~18, contact ~52, peak 6.0)
so it is a drop-in Hop asset: upload the FBX and swap only the Hop AssetId in
GooAnimationConfig -- no code or timing-fraction changes required.

Feel principles baked in here (the things the hand-keyed pipeline was fighting):
  * Gross squash & stretch is driven by GooRootBone.scale, the rig-native
    equivalent of the old procedural body.Size scaling. The root sits on the
    ground, so squashing its Y keeps the footprint planted for free.
  * Real anticipation crouch before takeoff, and a stretched airborne hold that
    rounds out only at the zero-velocity apex.
  * The landing SPLAT deliberately overshoots volume for two frames -- strict
    incompressibility read as a firm gummy; a brief over-spread reads as liquid.
  * The settle is a damped multi-bounce wave, generated as a decaying
    oscillation that lags and grows up the Lower->Mid->Upper chain, so the top
    mass sloshes after the base has caught. This is the jelly wobble the old
    version got from continuous tweening.
  * All deformation curves use smooth bezier (auto-clamped) handles so playback
    never snaps between poses.
"""

import math
from pathlib import Path

import bpy
from mathutils import Vector


ARMATURE_NAME = "GooRig"
BODY_NAME = "SlimeBody"
ACTION_NAME = "GooHopV2"
HOP_RANGE = (1, 72)
TAKEOFF = 18
APEX = 35
CONTACT = 52
PEAK_HEIGHT = 6.0
OUTPUT_NAME = "goo2_hop_v2.fbx"

# --- Primary silhouette: GooRootBone scale (sy = vertical, sxz = radial) -------
# sy * sxz^2 is roughly the volume factor. It is held near 1.0 through the air
# and deliberately pushed past 1.0 at the splat (frames 54-56) for the liquid
# over-spread. Values read top-to-bottom as: rest, anticipation crouch, load,
# takeoff stretch, ascent, apex round, descent stretch, contact, splat,
# then the damped settle bounces.
# Authored as (frame): (sy_vertical, sxz_radial).
ROOT_SCALE = {
    1:  (1.00, 1.00),
    8:  (1.00, 1.00),
    12: (0.74, 1.18),   # anticipation crouch: squat and spread
    16: (0.82, 1.12),   # coil / load
    18: (1.36, 0.82),   # takeoff: snap tall and thin
    24: (1.44, 0.80),   # fast ascent, maximum stretch
    30: (1.14, 0.93),   # slowing near apex
    APEX: (1.02, 0.99), # zero-velocity apex: relax to nearly round
    42: (1.28, 0.85),   # descent stretch rebuilds
    48: (1.45, 0.79),   # fast fall
    51: (1.45, 0.79),   # still stretched a frame before contact
    CONTACT: (1.38, 0.81),  # first contact: base grounded, mass still tall
    54: (0.68, 1.26),   # squash drives down fast
    55: (0.52, 1.44),   # MAX SPLAT -- volume overshoot (0.52*1.44^2 = 1.08)
    56: (0.56, 1.40),
    58: (1.16, 0.91),   # rebound overshoots past rest (jelly)
    61: (0.88, 1.07),   # settle bounce down
    64: (1.07, 0.965),  # up
    67: (0.965, 1.02),  # down
    70: (1.006, 0.997),
    72: (1.00, 1.00),
}

# --- Root vertical arc (world up). Parabola between takeoff and contact, with a
# small anticipation dip and a micro settle dip so the whole body drops a touch
# into the splat before the rebound. -------------------------------------------
def root_height(frame):
    if frame <= 12:
        return 0.0
    if frame < TAKEOFF:
        # brief downward load during the crouch
        a = (frame - 12) / (TAKEOFF - 12)
        return -0.18 * math.sin(a * math.pi)
    if frame <= CONTACT:
        p = (frame - TAKEOFF) / (CONTACT - TAKEOFF)
        return 4.0 * PEAK_HEIGHT * p * (1.0 - p)
    # After contact the root stays on the ground plane. GooRootBone sits at the
    # footprint, so the squash scale keeps the base planted for free -- adding a
    # vertical bob here only lifts the whole body off the floor.
    return 0.0


# --- Footprint: GooBase spreads on impact, stays broad briefly (adhesion),
# then retracts. Purely radial (x,z) scale. ------------------------------------
GOOBASE_SCALE = {
    1: 1.00, 51: 1.00, 52: 1.02,
    54: 1.22, 55: 1.42, 56: 1.40, 58: 1.24,
    61: 1.08, 64: 1.02, 67: 1.00, 72: 1.00,
}

# --- Damped settle wave up the vertical chain ---------------------------------
# After contact the base catches first while the upper mass keeps sloshing. Each
# control gets the same decaying oscillation, delayed and amplified going up.
# Amplitude is a vertical (along-bone, local Y) offset in rig units.
CHAIN = (
    ("GooLower", 0.12, 0.02),   # (bone, amplitude, lag seconds)
    ("GooMid",   0.24, 0.045),
    ("GooUpper", 0.42, 0.075),
)
WAVE_FREQ = 3.4     # Hz -- ~2.5 visible bounces over the settle
WAVE_DAMP = 7.5     # higher = quicker settle


def chain_offset(amp, lag, frame):
    t = (frame - CONTACT) / 30.0 - lag
    if t <= 0.0:
        return 0.0
    return -amp * math.exp(-WAVE_DAMP * t) * math.cos(2.0 * math.pi * WAVE_FREQ * t)


# --- Radial ripple on the four side controls during the settle ----------------
SIDE_BONES = {
    "GooSideFront": (2, 1.0),
    "GooSideBack": (2, -1.0),
    "GooSideLeft": (0, 1.0),
    "GooSideRight": (0, -1.0),
}
SIDE_AMP = 0.10
SIDE_LAG = 0.03


def side_offset(frame):
    t = (frame - CONTACT) / 30.0 - SIDE_LAG
    if t <= 0.0:
        return 0.0
    # sides bulge outward as the body squashes, opposite phase to the crown
    return SIDE_AMP * math.exp(-WAVE_DAMP * t) * math.cos(2.0 * math.pi * WAVE_FREQ * t)


def lerp_table(table, frame):
    keys = sorted(table)
    if frame <= keys[0]:
        return table[keys[0]]
    if frame >= keys[-1]:
        return table[keys[-1]]
    for i in range(len(keys) - 1):
        a, b = keys[i], keys[i + 1]
        if a <= frame <= b:
            alpha = (frame - a) / (b - a)
            va = table[a]
            vb = table[b]
            if isinstance(va, tuple):
                return tuple(x + (y - x) * alpha for x, y in zip(va, vb))
            return va + (vb - va) * alpha
    return table[keys[-1]]


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


def clear_action(name):
    action = bpy.data.actions.get(name)
    if action is not None:
        bpy.data.actions.remove(action)


def build_action(armature):
    clear_action(ACTION_NAME)
    armature.animation_data_create()
    action = bpy.data.actions.new(ACTION_NAME)
    action.use_fake_user = True
    armature.animation_data.action = action

    for bone in armature.pose.bones:
        bone.rotation_mode = "XYZ"
        bone.matrix_basis.identity()

    root = armature.pose.bones["GooRootBone"]
    base = armature.pose.bones["GooBase"]

    for frame in range(HOP_RANGE[0], HOP_RANGE[1] + 1):
        # Root: whole-body squash/stretch + vertical arc.
        sy, sxz = lerp_table(ROOT_SCALE, frame)
        root.scale = (sxz, sy, sxz)
        root.location = (0.0, root_height(frame), 0.0)
        root.keyframe_insert("scale", frame=frame, group="GooRootBone")
        root.keyframe_insert("location", frame=frame, group="GooRootBone")

        # Base footprint (radial only).
        bs = lerp_table(GOOBASE_SCALE, frame)
        base.scale = (bs, 1.0, bs)
        base.keyframe_insert("scale", frame=frame, group="GooBase")

        # Vertical-chain slosh wave.
        for name, amp, lag in CHAIN:
            pb = armature.pose.bones[name]
            pb.location = (0.0, chain_offset(amp, lag, frame), 0.0)
            pb.keyframe_insert("location", frame=frame, group=name)

        # Radial ripple on the side controls.
        so = side_offset(frame)
        for name, (axis, sign) in SIDE_BONES.items():
            pb = armature.pose.bones[name]
            loc = [0.0, 0.0, 0.0]
            loc[axis] = so * sign
            pb.location = loc
            pb.keyframe_insert("location", frame=frame, group=name)

    # Smooth every curve: bezier with auto-clamped handles => no pose snapping.
    for fcurve in iter_fcurves(action):
        for key in fcurve.keyframe_points:
            key.interpolation = "BEZIER"
            key.handle_left_type = "AUTO_CLAMPED"
            key.handle_right_type = "AUTO_CLAMPED"
        fcurve.update()

    action.use_frame_range = True
    action.frame_start, action.frame_end = HOP_RANGE
    return action


def body_metrics(body):
    depsgraph = bpy.context.evaluated_depsgraph_get()
    ev = body.evaluated_get(depsgraph)
    pts = [ev.matrix_world @ Vector(c) for c in ev.bound_box]
    return {
        "min_z": min(p.z for p in pts),
        "height": max(p.z for p in pts) - min(p.z for p in pts),
        "width": max(p.x for p in pts) - min(p.x for p in pts),
    }


def report(armature, body, action):
    armature.animation_data.action = action
    print("HOPV2_SAMPLES frame height width min_z")
    for frame in (1, 12, 18, 24, APEX, 48, CONTACT, 54, 55, 58, 61, 64, 72):
        bpy.context.scene.frame_set(frame)
        bpy.context.view_layer.update()
        m = body_metrics(body)
        print(
            f"  f{frame:<3d} h={m['height']:.3f} w={m['width']:.3f} min_z={m['min_z']:.4f}"
        )


def export(armature, action, filepath):
    armature.animation_data.action = action
    bpy.context.scene.frame_start, bpy.context.scene.frame_end = HOP_RANGE
    bpy.context.scene.frame_set(HOP_RANGE[1])
    if bpy.context.object and bpy.context.object.mode != "OBJECT":
        bpy.ops.object.mode_set(mode="OBJECT")
    bpy.ops.object.select_all(action="DESELECT")
    armature.select_set(True)
    bpy.context.view_layer.objects.active = armature
    bpy.ops.export_scene.fbx(
        filepath=str(filepath),
        check_existing=False,
        use_selection=True,
        object_types={"ARMATURE"},
        global_scale=1.0,
        apply_unit_scale=True,
        apply_scale_options="FBX_SCALE_UNITS",
        use_space_transform=True,
        bake_space_transform=False,
        axis_forward="-Z",
        axis_up="Y",
        use_custom_props=False,
        add_leaf_bones=False,
        primary_bone_axis="Y",
        secondary_bone_axis="X",
        use_armature_deform_only=False,
        armature_nodetype="NULL",
        bake_anim=True,
        bake_anim_use_all_bones=True,
        bake_anim_use_nla_strips=False,
        bake_anim_use_all_actions=False,
        bake_anim_force_startend_keying=True,
        bake_anim_step=1.0,
        bake_anim_simplify_factor=0.0,
    )


def main():
    source = Path(bpy.data.filepath)
    if source.name != "goo2.blend":
        raise RuntimeError(f"Expected goo2.blend, opened {source}")
    armature = bpy.data.objects[ARMATURE_NAME]
    body = bpy.data.objects[BODY_NAME]

    action = build_action(armature)
    report(armature, body, action)

    blender_dir = source.parent.parent

    # Save a dedicated review blend (never the source, never the existing
    # goo2_review.blend) with GooHopV2 applied and the scene framed so it opens
    # ready to scrub or play back with the spacebar.
    armature.animation_data.action = action
    scene = bpy.context.scene
    scene.frame_start, scene.frame_end = HOP_RANGE
    scene.frame_set(HOP_RANGE[0])
    review_dir = blender_dir / "reviews"
    review_dir.mkdir(parents=True, exist_ok=True)
    review_path = review_dir / "goo2_hop_v2_review.blend"
    bpy.ops.wm.save_as_mainfile(filepath=str(review_path), check_existing=False)
    print("HOPV2_REVIEW_BLEND", review_path)

    out_dir = blender_dir / "exports"
    out_dir.mkdir(parents=True, exist_ok=True)
    out_path = out_dir / OUTPUT_NAME
    export(armature, action, out_path)
    print("HOPV2_EXPORT", out_path)


main()
