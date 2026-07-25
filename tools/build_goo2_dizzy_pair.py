"""Build synchronized normal/compressed Dizzy clips for healing crossfades.

Run from the ClickGame repository root:

    /tmp/blender-5.1.2/blender -b docs/blender/reviews/goo2_review.blend \
        --python tools/build_goo2_dizzy_pair.py

The script adds GooDizzyCompressed to the review blend, exports both Dizzy
states with the same neutral bind pose, and validates the FBXs as a pair.
"""

from pathlib import Path

import bpy


ARMATURE_NAME = "GooRig"
NORMAL_ACTION = "GooDizzy"
COMPRESSED_ACTION = "GooDizzyCompressed"
HEALING_ACTION = "GooHealingProgress"
FRAME_RANGE = (1, 96)


def iter_fcurves(action):
    if hasattr(action, "fcurves"):
        return list(action.fcurves)
    curves = []
    for layer in action.layers:
        for strip in layer.strips:
            for channelbag in strip.channelbags:
                curves.extend(channelbag.fcurves)
    return curves


def curve_map(action):
    return {
        (curve.data_path, curve.array_index): curve
        for curve in iter_fcurves(action)
    }


def require_data():
    source_path = Path(bpy.data.filepath)
    if source_path.name != "goo2_review.blend":
        raise RuntimeError(f"Expected goo2_review.blend, opened {source_path}")
    armature = bpy.data.objects.get(ARMATURE_NAME)
    if armature is None or armature.type != "ARMATURE":
        raise RuntimeError(f"Missing armature {ARMATURE_NAME!r}")
    normal = bpy.data.actions.get(NORMAL_ACTION)
    healing = bpy.data.actions.get(HEALING_ACTION)
    if normal is None or healing is None:
        raise RuntimeError("Missing GooDizzy or GooHealingProgress")
    if tuple(round(value) for value in normal.frame_range) != FRAME_RANGE:
        raise RuntimeError(f"Unexpected GooDizzy range {tuple(normal.frame_range)}")
    return source_path, armature, normal, healing


def remove_action(name):
    action = bpy.data.actions.get(name)
    if action is not None:
        bpy.data.actions.remove(action)


def build_compressed_action(normal, healing):
    remove_action(COMPRESSED_ACTION)
    compressed = normal.copy()
    compressed.name = COMPRESSED_ACTION
    compressed.use_fake_user = True
    compressed.use_frame_range = True
    compressed.frame_start, compressed.frame_end = FRAME_RANGE

    healing_curves = curve_map(healing)
    nonzero_offsets = {}
    for curve in iter_fcurves(compressed):
        key = (curve.data_path, curve.array_index)
        healing_curve = healing_curves.get(key)
        if healing_curve is None:
            continue
        offset = healing_curve.evaluate(1.0) - healing_curve.evaluate(61.0)
        if abs(offset) <= 1e-8:
            continue
        if not (
            curve.data_path.endswith(".location")
            or curve.data_path.endswith(".rotation_euler")
        ):
            raise RuntimeError(f"Unsupported healing offset curve {curve.data_path}")
        for point in curve.keyframe_points:
            point.co.y += offset
            point.handle_left.y += offset
            point.handle_right.y += offset
        curve.update()
        nonzero_offsets[key] = offset

    if len(nonzero_offsets) < 7:
        raise RuntimeError(f"Too few compression offsets were applied: {nonzero_offsets}")
    return compressed, nonzero_offsets


def default_curve_value(curve):
    if curve.data_path.endswith(".scale"):
        return 1.0
    if curve.data_path.endswith(".rotation_quaternion") and curve.array_index == 0:
        return 1.0
    return 0.0


def make_neutral_bind_export_action(source, name):
    remove_action(name)
    samples = {
        (curve.data_path, curve.array_index): [
            curve.evaluate(frame) for frame in range(FRAME_RANGE[0], FRAME_RANGE[1] + 1)
        ]
        for curve in iter_fcurves(source)
    }
    exported = source.copy()
    exported.name = name
    exported.use_frame_range = True
    exported.frame_start, exported.frame_end = FRAME_RANGE
    for curve in iter_fcurves(exported):
        values = samples[(curve.data_path, curve.array_index)]
        points = curve.keyframe_points
        while len(points):
            points.remove(points[-1], fast=True)
        points.insert(0.0, default_curve_value(curve), options={"FAST"})
        for frame, value in zip(
            range(FRAME_RANGE[0], FRAME_RANGE[1] + 1), values
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


def export_action(armature, action, filepath):
    armature.animation_data_create()
    armature.animation_data.action = action
    bpy.context.scene.frame_start, bpy.context.scene.frame_end = FRAME_RANGE
    # Frame zero exists only in the temporary baked action and is neutral. It
    # supplies a shared bind pose but is excluded from the exported clip range.
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


def capture_import(path):
    bpy.ops.wm.read_factory_settings(use_empty=True)
    result = bpy.ops.import_scene.fbx(filepath=str(path), use_anim=True)
    if "FINISHED" not in result:
        raise RuntimeError(f"Failed to import {path}")
    armatures = [obj for obj in bpy.context.scene.objects if obj.type == "ARMATURE"]
    if len(armatures) != 1:
        raise RuntimeError(f"Expected one armature in {path}, found {len(armatures)}")
    armature = armatures[0]
    action = armature.animation_data.action
    frame_range = tuple(round(value) for value in action.frame_range)
    if frame_range != (2, 97):
        raise RuntimeError(f"Unexpected imported range {frame_range} for {path}")
    rest = {
        bone.name: (tuple(bone.head_local), tuple(bone.tail_local))
        for bone in armature.data.bones
    }
    poses = {}
    for frame in range(2, 98):
        bpy.context.scene.frame_set(frame)
        bpy.context.view_layer.update()
        poses[frame] = {
            bone.name: bone.matrix_basis.copy()
            for bone in armature.pose.bones
        }
    return rest, poses


def matrix_error(first, second):
    return max(
        abs(first[row][column] - second[row][column])
        for row in range(4)
        for column in range(4)
    )


def validate_pair(normal_path, compressed_path):
    normal_rest, normal_poses = capture_import(normal_path)
    compressed_rest, compressed_poses = capture_import(compressed_path)
    if normal_rest != compressed_rest:
        raise RuntimeError("Dizzy pair imported with different rest poses")

    affected_bones = set()
    translation_offsets = {}
    for bone_name in normal_poses[2]:
        reference_offset = (
            compressed_poses[2][bone_name].translation
            - normal_poses[2][bone_name].translation
        )
        translation_offsets[bone_name] = tuple(reference_offset)
        if reference_offset.length > 1e-5:
            affected_bones.add(bone_name)
        for frame in range(2, 98):
            normal_matrix = normal_poses[frame][bone_name]
            compressed_matrix = compressed_poses[frame][bone_name]
            offset = compressed_matrix.translation - normal_matrix.translation
            if (offset - reference_offset).length > 2e-4:
                raise RuntimeError(
                    f"Compression offset drifts on {bone_name} at frame {frame}"
                )
            normal_rotation = normal_matrix.to_3x3().normalized()
            compressed_rotation = compressed_matrix.to_3x3().normalized()
            if matrix_error(normal_rotation.to_4x4(), compressed_rotation.to_4x4()) > 2e-4:
                raise RuntimeError(
                    f"Dizzy phase/rotation mismatch on {bone_name} at frame {frame}"
                )
        if matrix_error(normal_poses[2][bone_name], normal_poses[97][bone_name]) > 2e-4:
            raise RuntimeError(f"Normal Dizzy does not loop on {bone_name}")
        if matrix_error(
            compressed_poses[2][bone_name], compressed_poses[97][bone_name]
        ) > 2e-4:
            raise RuntimeError(f"Compressed Dizzy does not loop on {bone_name}")

    if len(affected_bones) < 5:
        raise RuntimeError(f"Too few compressed bones after import: {affected_bones}")
    return affected_bones, translation_offsets


def main():
    source_path, armature, normal, healing = require_data()
    compressed, source_offsets = build_compressed_action(normal, healing)

    armature.animation_data_create()
    armature.animation_data.action = compressed
    bpy.context.scene.frame_start, bpy.context.scene.frame_end = FRAME_RANGE
    bpy.context.scene.frame_set(1)
    bpy.ops.wm.save_as_mainfile(filepath=str(source_path), check_existing=False)

    normal_export = make_neutral_bind_export_action(
        normal, "GooDizzyNormalFBXExport"
    )
    compressed_export = make_neutral_bind_export_action(
        compressed, "GooDizzyCompressedFBXExport"
    )
    output_dir = source_path.parent.parent / "exports"
    output_dir.mkdir(parents=True, exist_ok=True)
    normal_path = output_dir / "goo2_dizzy_normal.fbx"
    compressed_path = output_dir / "goo2_dizzy_compressed.fbx"
    export_action(armature, normal_export, normal_path)
    export_action(armature, compressed_export, compressed_path)

    affected_bones, imported_offsets = validate_pair(normal_path, compressed_path)
    print("GOO2_DIZZY_PAIR", normal_path, compressed_path)
    print("GOO2_DIZZY_SOURCE_OFFSETS", source_offsets)
    print("GOO2_DIZZY_AFFECTED_BONES", sorted(affected_bones))
    print("GOO2_DIZZY_IMPORTED_OFFSETS", imported_offsets)
    print("GOO2_DIZZY_PAIR_VALIDATION_OK")


main()
