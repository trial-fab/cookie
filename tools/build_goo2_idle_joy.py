"""Build a stronger looping Idle and an authored double-jump Joy clip.

Run from the ClickGame repository root:

    /tmp/blender-5.1.2/blender -b docs/blender/reviews/goo2_review.blend \
        --python tools/build_goo2_idle_joy.py

The approved GooHopIntegrated action is sampled, never modified. The script
adds two review actions to goo2_review.blend and exports animation-only FBXs
with a shared neutral bind pose.
"""

from pathlib import Path
import sys

import bmesh
import bpy
from mathutils import Vector
from mathutils.bvhtree import BVHTree


ARMATURE_NAME = "GooRig"
BODY_NAME = "SlimeBody"
IDLE_SOURCE = "GooIdle"
IDLE_ACTION = "GooIdleGelatin"
JOY_SOURCE = "GooHopIntegrated"
JOY_ACTION = "GooJoyDouble"
IDLE_RANGE = (1, 72)
JOY_RANGE = (1, 114)
ROOT_LOCATION_PATH = 'pose.bones["GooRootBone"].location'
ROOT_SCALE_PATH = 'pose.bones["GooRootBone"].scale'

# The first hop is quick and playful. Its rebound flows directly into the
# second anticipation; the larger second hop then gets more ascent and hang
# time. Both flights inherit Hop's momentum-carrying stretched baseline, while
# the offsets below provide additional liquid follow-through between them.
JOY_TIME_MAP = (
    (1.0, 1.0),
    (6.0, 7.0),
    (9.0, 14.0),
    (12.0, 18.0),
    (25.0, 35.0),
    (38.0, 52.0),
    (40.0, 53.0),
    (43.0, 55.0),
    (48.0, 61.0),
    # Let the first rebound finish before the second anticipation begins.
    # Frames 48-52 blend directly between two near-rest poses rather than
    # scrubbing backward through the source Hop's airborne section.
    (50.0, 67.0),
    (52.0, 7.0),
    (55.0, 14.0),
    (60.0, 18.0),
    # The two flight arcs now have closely matched timing. The second remains
    # higher through its root height, not by stretching time unnaturally.
    (74.0, 35.0),
    (88.0, 52.0),
    # The stronger second impact still gets enough frames for compression to
    # propagate through the body without the old 54 -> 55 visual snap.
    (90.0, 53.0),
    (93.0, 54.0),
    (96.0, 55.0),
    (102.0, 61.0),
    (108.0, 67.0),
    (114.0, 72.0),
)

JOY_POSE_SCALE_MAP = (
    (1.0, 1.0),
    (9.0, 1.10),
    (12.0, 1.10),
    (25.0, 1.08),
    (38.0, 1.12),
    (43.0, 1.18),
    (48.0, 1.14),
    (57.0, 1.20),
    (60.0, 1.16),
    (74.0, 1.10),
    (88.0, 1.15),
    (96.0, 1.20),
    (102.0, 1.15),
    (114.0, 1.0),
)

# Additive controls make the first landing feed a traveling, damped ripple
# into the second anticipation. The radial side controls move opposite the
# vertical compression to preserve the impression of liquid volume.
LIQUID_OFFSETS = {
    ("GooLower", "location", 1): (
        (38, 0.0), (41, -0.025), (45, 0.045), (49, -0.018),
        (53, 0.010), (57, -0.025), (60, 0.0),
    ),
    ("GooMid", "location", 1): (
        (38, 0.0), (42, -0.060), (46, 0.120), (50, -0.045),
        (54, 0.030), (58, -0.060), (60, 0.0),
    ),
    ("GooUpper", "location", 1): (
        (38, 0.0), (43, -0.110), (48, 0.220), (52, -0.090),
        (55, 0.050), (58, -0.080), (60, 0.0),
    ),
    ("GooMid", "location", 0): (
        (38, 0.0), (43, 0.020), (47, -0.030), (51, 0.022),
        (55, -0.012), (60, 0.0), (66, 0.018), (74, -0.024),
        (81, 0.018), (88, 0.0),
    ),
    ("GooUpper", "location", 0): (
        (38, 0.0), (44, -0.035), (48, 0.055), (52, -0.040),
        (56, 0.025), (60, 0.0), (66, -0.040), (74, 0.060),
        (81, -0.050), (88, 0.0),
    ),
    ("GooUpper", "rotation_euler", 2): (
        (38, 0.0), (44, -0.040), (48, 0.065), (52, -0.048),
        (56, 0.030), (60, 0.0), (66, -0.045), (74, 0.070),
        (81, -0.055), (88, 0.0),
    ),
}

RADIAL_RIPPLE = (
    (38, 0.0), (43, 0.120), (48, -0.070), (52, 0.045),
    (56, -0.025), (60, 0.0), (66, 0.050), (74, -0.040),
    (81, 0.035), (88, 0.0),
)
RADIAL_CHANNELS = {
    ("GooSideFront", "location", 2): -1.0,
    ("GooSideBack", "location", 2): 1.0,
    ("GooSideLeft", "location", 0): -1.0,
    ("GooSideRight", "location", 0): 1.0,
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


def action_curve_map(action):
    return {
        (curve.data_path, curve.array_index): curve
        for curve in iter_fcurves(action)
    }


def remove_action(name):
    action = bpy.data.actions.get(name)
    if action is not None:
        bpy.data.actions.remove(action)


def default_curve_value(curve):
    if curve.data_path.endswith(".scale"):
        return 1.0
    if curve.data_path.endswith(".rotation_quaternion") and curve.array_index == 0:
        return 1.0
    return 0.0


def replace_curve_samples(curve, frame_range, values):
    points = curve.keyframe_points
    while len(points):
        points.remove(points[-1], fast=True)
    for frame, value in zip(
        range(frame_range[0], frame_range[1] + 1), values
    ):
        point = points.insert(frame, value, options={"FAST"})
        point.interpolation = "LINEAR"
    curve.update()


def bone_name(curve):
    prefix = 'pose.bones["'
    if not curve.data_path.startswith(prefix):
        return None
    return curve.data_path[len(prefix):].split('"]', 1)[0]


def idle_amplitude(curve):
    """Target the soft mass while keeping the floor contact calm."""
    name = bone_name(curve)
    channel = curve.data_path.rsplit(".", 1)[-1]
    index = curve.array_index

    if name == "GooRootBone":
        if channel == "location":
            return (0.85, 1.0, 0.85)[index]
        return 1.15
    if name == "GooLower":
        if channel == "location":
            return (1.35, 1.70, 1.35)[index]
        return 1.45
    if name == "GooMid":
        if channel == "location":
            return (1.90, 2.15, 1.75)[index]
        return 2.0
    if name == "GooUpper":
        if channel == "location":
            return (2.10, 2.25, 1.90)[index]
        return 2.10
    if name in {"GooSideFront", "GooSideBack"}:
        if channel == "location":
            return (1.35, 1.50, 2.0)[index]
        return 1.55
    if name in {"GooSideLeft", "GooSideRight"}:
        if channel == "location":
            return (2.0, 1.50, 1.35)[index]
        return 1.55
    return 1.0


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
    """Bake radial root-child scale that keeps the goo near-incompressible."""
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
    corrections = []
    for frame in frames:
        bpy.context.scene.frame_set(frame)
        bpy.context.view_layer.update()
        corrections.append(
            (
                frame,
                root.location.y
                + target_ground
                - evaluated_body_metrics(body)["min_z"],
            )
        )
    for frame, corrected_location in corrections:
        bpy.context.scene.frame_set(frame)
        root.location.y = corrected_location
        root.keyframe_insert(data_path="location", frame=frame, group=root.name)
    curve = action_curve_map(action)[(ROOT_LOCATION_PATH, 1)]
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


def neutral_ground(armature, body):
    armature.animation_data_create()
    armature.animation_data.action = None
    for pose_bone in armature.pose.bones:
        pose_bone.matrix_basis.identity()
    bpy.context.scene.frame_set(1)
    bpy.context.view_layer.update()
    return evaluated_body_metrics(body)["min_z"]


def build_idle(armature, body):
    source = bpy.data.actions[IDLE_SOURCE]
    if tuple(round(value) for value in source.frame_range) != IDLE_RANGE:
        raise RuntimeError(f"Unexpected {IDLE_SOURCE} range {tuple(source.frame_range)}")

    source_samples = {
        (curve.data_path, curve.array_index): [
            curve.evaluate(frame) for frame in range(IDLE_RANGE[0], IDLE_RANGE[1] + 1)
        ]
        for curve in iter_fcurves(source)
    }
    remove_action(IDLE_ACTION)
    action = source.copy()
    action.name = IDLE_ACTION
    action.use_fake_user = True
    action.use_frame_range = True
    action.frame_start, action.frame_end = IDLE_RANGE

    for curve in iter_fcurves(action):
        baseline = default_curve_value(curve)
        scale = idle_amplitude(curve)
        values = [
            baseline + (value - baseline) * scale
            for value in source_samples[(curve.data_path, curve.array_index)]
        ]
        replace_curve_samples(curve, IDLE_RANGE, values)

    # Counter the deformation at the root so every frame rests on the exact
    # neutral ground plane. This keeps the stronger breath from looking like a
    # tiny hover or foot-slide while the upper mass remains visibly alive.
    target_ground = neutral_ground(armature, body)
    armature.animation_data.action = action
    root_curve = action_curve_map(action)[(ROOT_LOCATION_PATH, 1)]
    root_values = [root_curve.evaluate(frame) for frame in range(1, 73)]
    ground_values = []
    for frame in range(1, 73):
        bpy.context.scene.frame_set(frame)
        bpy.context.view_layer.update()
        ground_values.append(evaluated_body_metrics(body)["min_z"])
    corrected = [
        root + target_ground - ground
        for root, ground in zip(root_values, ground_values)
    ]
    replace_curve_samples(root_curve, IDLE_RANGE, corrected)
    return action


def remapped_source_frame(target_frame):
    for index in range(len(JOY_TIME_MAP) - 1):
        target_a, source_a = JOY_TIME_MAP[index]
        target_b, source_b = JOY_TIME_MAP[index + 1]
        if target_frame <= target_b:
            alpha = (target_frame - target_a) / (target_b - target_a)
            return source_a + alpha * (source_b - source_a)
    return JOY_TIME_MAP[-1][1]


def interpolated_map_value(frame, anchors):
    for index in range(len(anchors) - 1):
        frame_a, value_a = anchors[index]
        frame_b, value_b = anchors[index + 1]
        if frame <= frame_b:
            alpha = (frame - frame_a) / (frame_b - frame_a)
            return value_a + (value_b - value_a) * alpha
    return anchors[-1][1]


def joy_pose_scale(frame):
    return interpolated_map_value(frame, JOY_POSE_SCALE_MAP)


def joy_root_scale(frame):
    return 0.90 if frame <= 43 else 1.25


def sampled_offset(frame, anchors):
    if frame < anchors[0][0] or frame > anchors[-1][0]:
        return 0.0
    return interpolated_map_value(frame, anchors)


def liquid_offset(curve, frame):
    name = bone_name(curve)
    channel = curve.data_path.rsplit(".", 1)[-1]
    key = (name, channel, curve.array_index)
    anchors = LIQUID_OFFSETS.get(key)
    offset = sampled_offset(frame, anchors) if anchors else 0.0
    radial_direction = RADIAL_CHANNELS.get(key)
    if radial_direction is not None:
        offset += sampled_offset(frame, RADIAL_RIPPLE) * radial_direction
    return offset


def sample_joy_curve(source_curve, frame):
    # Any backwards source segment is a direct endpoint-pose blend. Sampling
    # backward through the source Hop would traverse its airborne arc and
    # create an unintended extra hop/snap between the two jumps.
    for index in range(len(JOY_TIME_MAP) - 1):
        target_a, source_a = JOY_TIME_MAP[index]
        target_b, source_b = JOY_TIME_MAP[index + 1]
        if frame <= target_b:
            if source_b < source_a:
                alpha = (frame - target_a) / (target_b - target_a)
                value_a = source_curve.evaluate(source_a)
                value_b = source_curve.evaluate(source_b)
                return value_a + (value_b - value_a) * alpha
            break
    return source_curve.evaluate(remapped_source_frame(frame))


def build_joy():
    source = bpy.data.actions[JOY_SOURCE]
    if tuple(round(value) for value in source.frame_range) != IDLE_RANGE:
        raise RuntimeError(f"Unexpected {JOY_SOURCE} range {tuple(source.frame_range)}")
    source_curves = action_curve_map(source)

    remove_action(JOY_ACTION)
    action = source.copy()
    action.name = JOY_ACTION
    action.use_fake_user = True
    action.use_frame_range = True
    action.frame_start, action.frame_end = JOY_RANGE

    for curve in iter_fcurves(action):
        source_curve = source_curves[(curve.data_path, curve.array_index)]
        baseline = default_curve_value(curve)
        values = []
        for frame in range(JOY_RANGE[0], JOY_RANGE[1] + 1):
            sampled = sample_joy_curve(source_curve, frame)
            if curve.data_path == ROOT_LOCATION_PATH and curve.array_index == 1:
                value = 0.0 if 43 <= frame <= 60 else sampled * joy_root_scale(frame)
            elif curve.data_path == ROOT_LOCATION_PATH and curve.array_index in {0, 2}:
                value = 0.0
            elif curve.data_path == ROOT_SCALE_PATH and curve.array_index == 1:
                # Keep the approved uniform splat thickness. Amplifying this
                # scale as a generic pose offset reintroduces a wafer-thin hit.
                value = sampled
            else:
                value = (
                    baseline
                    + (sampled - baseline) * joy_pose_scale(frame)
                    + liquid_offset(curve, frame)
                )
            values.append(value)
        replace_curve_samples(curve, JOY_RANGE, values)
    return action


def matrix_error(first, second):
    return max(
        abs(first[row][column] - second[row][column])
        for row in range(4)
        for column in range(4)
    )


def sample_source_metrics(armature, body, action, frame_range):
    armature.animation_data_create()
    armature.animation_data.action = action
    samples = {}
    poses = {}
    for frame in range(frame_range[0], frame_range[1] + 1):
        bpy.context.scene.frame_set(frame)
        bpy.context.view_layer.update()
        samples[frame] = evaluated_body_metrics(body)
        samples[frame]["volume"] = evaluated_body_volume(body)
        samples[frame]["band_widths"] = evaluated_band_widths(body)
        samples[frame]["root_height"] = armature.pose.bones["GooRootBone"].location.y
        poses[frame] = {
            bone.name: bone.matrix_basis.copy()
            for bone in armature.pose.bones
        }
    return samples, poses


def validate_idle_source(armature, body, action):
    samples, poses = sample_source_metrics(armature, body, action, IDLE_RANGE)
    loop_error = max(
        matrix_error(poses[1][name], poses[72][name])
        for name in poses[1]
    )
    ground_range = max(value["min_z"] for value in samples.values()) - min(
        value["min_z"] for value in samples.values()
    )
    height_range = max(value["height"] for value in samples.values()) - min(
        value["height"] for value in samples.values()
    )
    width_range = max(value["width"] for value in samples.values()) - min(
        value["width"] for value in samples.values()
    )
    target_volume = samples[1]["volume"]
    volume_error = max(
        abs(value["volume"] / target_volume - 1.0)
        for value in samples.values()
    )
    if loop_error > 1e-6:
        raise RuntimeError(f"Idle loop pose error {loop_error}")
    if ground_range > 2e-3:
        raise RuntimeError(f"Idle ground drift {ground_range}")
    if height_range < 0.20 or width_range < 0.045:
        raise RuntimeError(
            f"Idle is still too subtle: height {height_range}, width {width_range}"
        )
    if volume_error > 0.006:
        raise RuntimeError(f"Idle does not conserve liquid volume: {volume_error}")
    return {
        "loop_error": loop_error,
        "ground_range": ground_range,
        "height_range": height_range,
        "width_range": width_range,
        "volume_error": volume_error,
    }


def validate_joy_source(armature, body, action):
    samples, poses = sample_source_metrics(armature, body, action, JOY_RANGE)
    heights = {frame: value["root_height"] for frame, value in samples.items()}
    first_peak = max((height, frame) for frame, height in heights.items() if frame <= 43)
    second_peak = max((height, frame) for frame, height in heights.items() if frame >= 44)
    if first_peak[1] != 25 or abs(first_peak[0] - 5.4) > 0.02:
        raise RuntimeError(f"Unexpected first Joy apex {first_peak}")
    if second_peak[1] != 74 or abs(second_peak[0] - 7.5) > 0.02:
        raise RuntimeError(f"Unexpected second Joy apex {second_peak}")
    if min(heights.values()) < -1e-6:
        raise RuntimeError("Joy root moves below its ground plane")
    ground_frames = (
        *range(1, 13),
        *range(38, 61),
        *range(88, 115),
    )
    target_ground = samples[1]["min_z"]
    for frame in ground_frames:
        if abs(samples[frame]["min_z"] - target_ground) > 2e-3:
            raise RuntimeError(f"Joy loses ground contact at frame {frame}")
    if samples[25]["height"] > samples[38]["height"] * 0.90:
        raise RuntimeError("First Joy flight does not relax at its apex")
    if samples[74]["height"] > samples[88]["height"] * 0.90:
        raise RuntimeError("Second Joy flight does not relax at its apex")
    if samples[25]["width"] <= samples[38]["width"]:
        raise RuntimeError("First Joy apex does not recover radial volume")
    if samples[74]["width"] <= samples[88]["width"]:
        raise RuntimeError("Second Joy apex does not recover radial volume")
    if samples[40]["height"] >= samples[38]["height"]:
        raise RuntimeError("First Joy landing does not compress after contact")
    if samples[90]["height"] >= samples[88]["height"]:
        raise RuntimeError("Second Joy landing does not compress after contact")
    for impact_frame in (43, 96):
        impact_widths = samples[impact_frame]["band_widths"]
        if any(impact_widths[index] < impact_widths[index + 1] for index in range(4)):
            raise RuntimeError(f"Joy impact at frame {impact_frame} does not spread from the ground upward")
    first_footprints = [samples[frame]["band_widths"][0] for frame in (38, 40, 41, 42, 43)]
    second_footprints = [samples[frame]["band_widths"][0] for frame in (88, 90, 93, 96)]
    if first_footprints != sorted(first_footprints) or second_footprints != sorted(second_footprints):
        raise RuntimeError("Joy footprints do not spread progressively after contact")
    for frame in (40, 42, 43, 48, 90, 94, 95, 96, 102):
        bpy.context.scene.frame_set(frame)
        bpy.context.view_layer.update()
        health = evaluated_surface_health(body)
        if health["nonadjacent_overlaps"] or health["minimum_face_area"] < 1e-6:
            raise RuntimeError(f"Joy surface folds at frame {frame}: {health}")
        if frame in {43, 95, 96} and health["ridge_above_center"] > 0.04:
            raise RuntimeError(f"Joy forms an annular impact ridge at frame {frame}: {health}")
    end_error = max(
        matrix_error(poses[1][name], poses[114][name])
        for name in poses[1]
    )
    if end_error > 2e-4:
        raise RuntimeError(f"Joy does not return to rest: {end_error}")
    target_volume = samples[1]["volume"]
    volume_error = max(
        abs(value["volume"] / target_volume - 1.0)
        for value in samples.values()
    )
    if volume_error > 0.006:
        raise RuntimeError(f"Joy does not conserve liquid volume: {volume_error}")
    return {
        "first_apex": first_peak,
        "second_apex": second_peak,
        "first_contact_height": samples[38]["height"],
        "first_impact_height": samples[43]["height"],
        "second_contact_height": samples[88]["height"],
        "second_impact_height": samples[96]["height"],
        "first_apex_body_height": samples[25]["height"],
        "second_apex_body_height": samples[74]["height"],
        "volume_error": volume_error,
        "end_error": end_error,
    }


def make_neutral_bind_export_action(source, name, frame_range):
    remove_action(name)
    samples = {
        (curve.data_path, curve.array_index): [
            curve.evaluate(frame)
            for frame in range(frame_range[0], frame_range[1] + 1)
        ]
        for curve in iter_fcurves(source)
    }
    exported = source.copy()
    exported.name = name
    exported.use_frame_range = True
    exported.frame_start, exported.frame_end = frame_range
    for curve in iter_fcurves(exported):
        points = curve.keyframe_points
        while len(points):
            points.remove(points[-1], fast=True)
        point = points.insert(0.0, default_curve_value(curve), options={"FAST"})
        point.interpolation = "LINEAR"
        for frame, value in zip(
            range(frame_range[0], frame_range[1] + 1),
            samples[(curve.data_path, curve.array_index)],
        ):
            point = points.insert(frame, value, options={"FAST"})
            point.interpolation = "LINEAR"
        curve.update()
    return exported


def select_only(obj):
    if bpy.context.object and bpy.context.object.mode != "OBJECT":
        bpy.ops.object.mode_set(mode="OBJECT")
    bpy.ops.object.select_all(action="DESELECT")
    obj.select_set(True)
    bpy.context.view_layer.objects.active = obj


def export_action(armature, action, filepath, frame_range):
    armature.animation_data_create()
    armature.animation_data.action = action
    bpy.context.scene.frame_start, bpy.context.scene.frame_end = frame_range
    bpy.context.scene.frame_set(0)
    select_only(armature)
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


def capture_import(path, expected_range):
    bpy.ops.wm.read_factory_settings(use_empty=True)
    result = bpy.ops.import_scene.fbx(filepath=str(path), use_anim=True)
    if "FINISHED" not in result:
        raise RuntimeError(f"Failed to import {path}")
    armatures = [obj for obj in bpy.context.scene.objects if obj.type == "ARMATURE"]
    if len(armatures) != 1:
        raise RuntimeError(f"Expected one armature in {path}, found {len(armatures)}")
    armature = armatures[0]
    if len(armature.data.bones) != 9:
        raise RuntimeError(f"Unexpected bone count in {path}: {len(armature.data.bones)}")
    action = armature.animation_data.action
    actual_range = tuple(round(value) for value in action.frame_range)
    if actual_range != expected_range:
        raise RuntimeError(f"Unexpected imported range {actual_range} for {path}")
    rest = {
        bone.name: (tuple(bone.head_local), tuple(bone.tail_local))
        for bone in armature.data.bones
    }
    poses = {}
    for frame in range(expected_range[0], expected_range[1] + 1):
        bpy.context.scene.frame_set(frame)
        bpy.context.view_layer.update()
        poses[frame] = {
            bone.name: bone.matrix_basis.copy()
            for bone in armature.pose.bones
        }
    return rest, poses


def validate_round_trip(hop_path, idle_path, joy_path):
    hop_rest, hop_poses = capture_import(hop_path, (2, 73))
    idle_rest, idle_poses = capture_import(idle_path, (2, 73))
    joy_rest, joy_poses = capture_import(joy_path, (2, 115))
    if hop_rest != idle_rest or idle_rest != joy_rest:
        raise RuntimeError("Hop, Idle, and Joy imported with different rest poses")
    hop_end_error = max(
        matrix_error(hop_poses[2][name], hop_poses[73][name])
        for name in hop_poses[2]
    )
    idle_loop_error = max(
        matrix_error(idle_poses[2][name], idle_poses[73][name])
        for name in idle_poses[2]
    )
    joy_end_error = max(
        matrix_error(joy_poses[2][name], joy_poses[115][name])
        for name in joy_poses[2]
    )
    if hop_end_error > 2e-4:
        raise RuntimeError(f"Imported Hop end error {hop_end_error}")
    if idle_loop_error > 2e-4:
        raise RuntimeError(f"Imported Idle loop error {idle_loop_error}")
    if joy_end_error > 2e-4:
        raise RuntimeError(f"Imported Joy end error {joy_end_error}")
    return {
        "hop_end_error": hop_end_error,
        "idle_loop_error": idle_loop_error,
        "joy_end_error": joy_end_error,
        "bone_count": len(idle_rest),
    }


def validate_joy_round_trip(hop_path, joy_path):
    hop_rest, _hop_poses = capture_import(hop_path, (2, 73))
    rest, poses = capture_import(joy_path, (2, 115))
    if hop_rest != rest:
        raise RuntimeError("Hop and Joy imported with different rest poses")
    end_error = max(
        matrix_error(poses[2][name], poses[115][name])
        for name in poses[2]
    )
    if end_error > 2e-4:
        raise RuntimeError(f"Imported Joy end error {end_error}")
    return {"joy_end_error": end_error, "bone_count": len(rest)}


def main():
    joy_only = "--joy-only" in sys.argv
    source_path = Path(bpy.data.filepath)
    if source_path.name != "goo2_review.blend":
        raise RuntimeError(f"Expected goo2_review.blend, opened {source_path}")
    armature = bpy.data.objects.get(ARMATURE_NAME)
    body = bpy.data.objects.get(BODY_NAME)
    if armature is None or armature.type != "ARMATURE":
        raise RuntimeError(f"Missing armature {ARMATURE_NAME!r}")
    if body is None or body.type != "MESH":
        raise RuntimeError(f"Missing mesh {BODY_NAME!r}")
    for action_name in (IDLE_SOURCE, JOY_SOURCE):
        if bpy.data.actions.get(action_name) is None:
            raise RuntimeError(f"Missing source action {action_name!r}")

    idle = bpy.data.actions.get(IDLE_ACTION) if joy_only else build_idle(armature, body)
    if idle is None:
        raise RuntimeError(f"Missing approved action {IDLE_ACTION!r}")
    joy = build_joy()
    idle_volume = (
        None
        if joy_only
        else conserve_action_volume(armature, body, idle, IDLE_RANGE)
    )
    joy_volume = conserve_action_volume(armature, body, joy, JOY_RANGE)
    joy_ground = pin_ground_contact(
        armature,
        body,
        joy,
        (
            *range(1, 13),
            *range(38, 61),
            *range(88, 115),
        ),
    )
    idle_metrics = None if joy_only else validate_idle_source(armature, body, idle)
    joy_metrics = validate_joy_source(armature, body, joy)

    armature.animation_data.action = joy
    bpy.context.scene.frame_start, bpy.context.scene.frame_end = JOY_RANGE
    bpy.context.scene.frame_set(1)
    bpy.ops.wm.save_as_mainfile(filepath=str(source_path), check_existing=False)

    joy_export = make_neutral_bind_export_action(
        joy, "GooJoyDoubleFBXExport", JOY_RANGE
    )
    output_dir = source_path.parent.parent / "exports"
    output_dir.mkdir(parents=True, exist_ok=True)
    idle_path = output_dir / "goo2_idle_gelatin.fbx"
    joy_path = output_dir / "goo2_joy_double.fbx"
    hop_path = output_dir / "goo2_hop_integrated.fbx"
    if not hop_path.exists():
        raise RuntimeError(f"Missing approved Hop export {hop_path}")
    if not joy_only:
        idle_export = make_neutral_bind_export_action(
            idle, "GooIdleGelatinFBXExport", IDLE_RANGE
        )
        export_action(armature, idle_export, idle_path, IDLE_RANGE)
    export_action(armature, joy_export, joy_path, JOY_RANGE)
    round_trip = (
        validate_joy_round_trip(hop_path, joy_path)
        if joy_only
        else validate_round_trip(hop_path, idle_path, joy_path)
    )

    if joy_only:
        print("GOO2_IDLE_PRESERVED", idle_path)
    else:
        print("GOO2_IDLE_VOLUME", idle_volume)
        print("GOO2_IDLE_ACTION", IDLE_ACTION, idle_metrics)
    print("GOO2_JOY_VOLUME", joy_volume)
    print("GOO2_JOY_GROUND", joy_ground)
    print("GOO2_JOY_ACTION", JOY_ACTION, joy_metrics)
    print("GOO2_IDLE_JOY_EXPORTS", idle_path, joy_path)
    print("GOO2_IDLE_JOY_ROUND_TRIP", round_trip)


main()
