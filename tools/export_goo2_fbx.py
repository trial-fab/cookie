"""Batch-export goo2's Roblox base rig and animation FBXs.

Blender GUI: open this file in the Scripting workspace and press Run Script.
Command line: blender -b docs/blender/sources/goo2.blend --python tools/export_goo2_fbx.py
"""

from pathlib import Path

import bpy


ARMATURE_NAME = "GooRig"
MESH_NAMES = ("SlimeBody", "SlimeEyes")
ACTION_EXPORTS = {
    "GooReveal": "goo2_reveal.fbx",
    "GooRecover": "goo2_recover.fbx",
    "GooShowcase": "goo2_showcase.fbx",
}
EXPECTED_RANGES = {
    "GooReveal": (1, 48),
    "GooRecover": (1, 54),
    "GooShowcase": (1, 72),
}


def require_data():
    if not bpy.data.filepath:
        raise RuntimeError("Save goo2.blend before exporting so the output folder is deterministic.")
    armature = bpy.data.objects.get(ARMATURE_NAME)
    if armature is None or armature.type != "ARMATURE":
        raise RuntimeError(f"Missing armature object {ARMATURE_NAME!r}.")
    meshes = []
    for name in MESH_NAMES:
        mesh = bpy.data.objects.get(name)
        if mesh is None or mesh.type != "MESH":
            raise RuntimeError(f"Missing mesh object {name!r}.")
        meshes.append(mesh)
    for action_name, expected_range in EXPECTED_RANGES.items():
        action = bpy.data.actions.get(action_name)
        if action is None:
            raise RuntimeError(f"Missing action {action_name!r}.")
        actual_range = tuple(int(value) for value in action.frame_range)
        if actual_range != expected_range:
            raise RuntimeError(f"{action_name} range is {actual_range}, expected {expected_range}.")
    return armature, meshes


def select_only(objects, active):
    bpy.ops.object.mode_set(mode="OBJECT") if bpy.context.object and bpy.context.object.mode != "OBJECT" else None
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


def export_base(armature, meshes, output_dir):
    # Export the bind/rest pose even when the currently active looping action
    # begins at a deliberately non-neutral phase.
    armature.animation_data_create()
    armature.animation_data.action = None
    for pose_bone in armature.pose.bones:
        pose_bone.matrix_basis.identity()
    bpy.context.view_layer.update()
    select_only([armature, *meshes], armature)
    settings = common_export_settings(output_dir / "goo2_rig.fbx", {"ARMATURE", "MESH"})
    settings.update(
        {
            "use_mesh_modifiers": True,
            "use_mesh_modifiers_render": True,
            "mesh_smooth_type": "FACE",
            "use_tspace": True,
            "bake_anim": False,
        }
    )
    bpy.ops.export_scene.fbx(**settings)


def export_action(armature, action_name, filename, output_dir):
    action = bpy.data.actions[action_name]
    armature.animation_data_create()
    armature.animation_data.action = action
    start, end = EXPECTED_RANGES[action_name]
    bpy.context.scene.frame_start = start
    bpy.context.scene.frame_end = end
    bpy.context.scene.frame_set(start)
    select_only([armature], armature)
    settings = common_export_settings(output_dir / filename, {"ARMATURE"})
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
    armature, meshes = require_data()
    output_dir = Path(bpy.data.filepath).parent.parent / "exports"
    output_dir.mkdir(parents=True, exist_ok=True)

    original_action = armature.animation_data.action if armature.animation_data else None
    original_start = bpy.context.scene.frame_start
    original_end = bpy.context.scene.frame_end
    original_frame = bpy.context.scene.frame_current

    export_base(armature, meshes, output_dir)
    for action_name, filename in ACTION_EXPORTS.items():
        export_action(armature, action_name, filename, output_dir)

    armature.animation_data.action = original_action
    bpy.context.scene.frame_start = original_start
    bpy.context.scene.frame_end = original_end
    bpy.context.scene.frame_set(original_frame)
    select_only([armature, *meshes], armature)

    exported = ["goo2_rig.fbx", *ACTION_EXPORTS.values()]
    print("GOO2_EXPORT_DIR", output_dir)
    print("GOO2_EXPORTED", exported)


main()
