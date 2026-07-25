"""Export and round-trip validate the currently authored Titan blend.

Run from the ClickGame repository root:

    /tmp/blender-5.1.2/blender -b docs/blender/sources/goo2_titan.blend \
        --python tools/export_current_goo2_titan.py

This intentionally exports the open Titan file as-authored and never saves or
rebuilds it.
"""

from pathlib import Path

import bpy
from mathutils import Vector


ARMATURE_NAME = "GooRig"
MESH_NAMES = ("SlimeBody", "SlimeEyes")


def world_bbox_center(obj):
    local_center = sum((Vector(corner) for corner in obj.bound_box), Vector()) / 8
    return obj.matrix_world @ local_center


def select_only(objects, active):
    if bpy.context.object and bpy.context.object.mode != "OBJECT":
        bpy.ops.object.mode_set(mode="OBJECT")
    bpy.ops.object.select_all(action="DESELECT")
    for obj in objects:
        obj.select_set(True)
    bpy.context.view_layer.objects.active = active


def require_titan():
    source_path = Path(bpy.data.filepath)
    if source_path.name != "goo2_titan.blend":
        raise RuntimeError(f"Expected goo2_titan.blend, opened {source_path}")
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
    return source_path, armature, meshes


def capture_metrics(armature, meshes):
    weighted_groups = {}
    for mesh in meshes:
        weighted_indices = {
            link.group
            for vertex in mesh.data.vertices
            for link in vertex.groups
            if link.weight > 1e-7
        }
        weighted_groups[mesh.name] = {
            group.name
            for group in mesh.vertex_groups
            if group.index in weighted_indices
        }
    return {
        "bone_count": len(armature.data.bones),
        "dimensions": {mesh.name: tuple(mesh.dimensions) for mesh in meshes},
        "centers": {mesh.name: tuple(world_bbox_center(mesh)) for mesh in meshes},
        "groups": weighted_groups,
    }


def reset_pose(armature):
    armature.animation_data_create()
    armature.animation_data.action = None
    for bone in armature.pose.bones:
        bone.matrix_basis.identity()
    bpy.context.view_layer.update()


def export_titan(armature, meshes, filepath):
    reset_pose(armature)
    select_only([armature, *meshes], armature)
    bpy.ops.export_scene.fbx(
        filepath=str(filepath),
        check_existing=False,
        use_selection=True,
        object_types={"ARMATURE", "MESH"},
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
        use_mesh_modifiers=True,
        use_mesh_modifiers_render=True,
        mesh_smooth_type="FACE",
        use_tspace=True,
        bake_anim=False,
    )


def close_tuple(actual, expected, tolerance=2e-3):
    return all(abs(a - b) <= tolerance for a, b in zip(actual, expected))


def validate_round_trip(filepath, expected):
    bpy.ops.wm.read_factory_settings(use_empty=True)
    result = bpy.ops.import_scene.fbx(filepath=str(filepath), use_anim=False)
    if "FINISHED" not in result:
        raise RuntimeError(f"Failed to round-trip import {filepath}")
    armatures = [obj for obj in bpy.context.scene.objects if obj.type == "ARMATURE"]
    if len(armatures) != 1:
        raise RuntimeError(f"Expected one imported armature, found {len(armatures)}")
    armature = armatures[0]
    meshes = {obj.name: obj for obj in bpy.context.scene.objects if obj.type == "MESH"}
    if len(armature.data.bones) != expected["bone_count"]:
        raise RuntimeError("Titan bone count changed during FBX round trip")
    for name in MESH_NAMES:
        mesh = meshes.get(name)
        if mesh is None:
            raise RuntimeError(f"Round-trip FBX is missing {name}")
        if mesh.parent != armature:
            raise RuntimeError(f"Round-trip {name} lost its armature parent")
        if not close_tuple(tuple(mesh.dimensions), expected["dimensions"][name]):
            raise RuntimeError(
                f"{name} dimensions changed: {tuple(mesh.dimensions)} != "
                f"{expected['dimensions'][name]}"
            )
        if not close_tuple(tuple(world_bbox_center(mesh)), expected["centers"][name]):
            raise RuntimeError(
                f"{name} center changed: {tuple(world_bbox_center(mesh))} != "
                f"{expected['centers'][name]}"
            )
        weighted_indices = {
            link.group
            for vertex in mesh.data.vertices
            for link in vertex.groups
            if link.weight > 1e-7
        }
        groups = {
            group.name
            for group in mesh.vertex_groups
            if group.index in weighted_indices
        }
        if groups != expected["groups"][name]:
            raise RuntimeError(f"{name} weight groups changed during FBX round trip")


def main():
    source_path, armature, meshes = require_titan()
    reset_pose(armature)
    expected = capture_metrics(armature, meshes)
    output_path = source_path.parent.parent / "exports" / "goo2_titan_rig.fbx"
    output_path.parent.mkdir(parents=True, exist_ok=True)
    export_titan(armature, meshes, output_path)
    validate_round_trip(output_path, expected)
    print("GOO2_TITAN_EXPORTED", output_path)
    print("GOO2_TITAN_SOURCE_METRICS", expected)
    print("GOO2_TITAN_VALIDATION_OK")


main()
