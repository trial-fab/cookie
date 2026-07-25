"""Export a goo rig with a baked space transform so it imports upright with an
identity pivot (no 90-degree PivotOffset), instead of leaving the Z-up -> Y-up
conversion as a node rotation.

The ONLY difference from the existing rig exporters is bake_space_transform=True.
It round-trips the FBX back into Blender to prove the bake did not damage the rig
(bone count, mesh->armature parenting, and skin-weight groups must survive).

Run once per source blend:

    /tmp/blender-5.1.2/blender -b docs/blender/sources/goo2.blend \
        --python tools/export_tidy_rig.py
    /tmp/blender-5.1.2/blender -b docs/blender/sources/goo2_titan.blend \
        --python tools/export_tidy_rig.py

Output name is derived from the blend:
    goo2.blend        -> exports/goo_rig.fbx
    goo2_titan.blend  -> exports/titan_goo_rig.fbx
"""

from pathlib import Path

import bpy
from mathutils import Vector


ARMATURE_NAME = "GooRig"
MESH_NAMES = ("SlimeBody", "SlimeEyes")

OUTPUT_BY_SOURCE = {
    "goo2.blend": "goo_rig.fbx",
    "goo2_titan.blend": "titan_goo_rig.fbx",
}


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


def require_data():
    source_path = Path(bpy.data.filepath)
    if source_path.name not in OUTPUT_BY_SOURCE:
        raise RuntimeError(
            f"Open one of {sorted(OUTPUT_BY_SOURCE)}, opened {source_path.name!r}"
        )
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


def reset_pose(armature):
    armature.animation_data_create()
    armature.animation_data.action = None
    for bone in armature.pose.bones:
        bone.matrix_basis.identity()
    bpy.context.view_layer.update()


def weight_groups(mesh):
    weighted_indices = {
        link.group
        for vertex in mesh.data.vertices
        for link in vertex.groups
        if link.weight > 1e-7
    }
    return {
        group.name for group in mesh.vertex_groups if group.index in weighted_indices
    }


def capture_metrics(armature, meshes):
    return {
        "bone_count": len(armature.data.bones),
        # Sorted extents are orientation-independent: baking rotates the geometry,
        # so we compare the set of edge lengths, not per-axis X/Y/Z.
        "sorted_dims": {m.name: tuple(sorted(round(v, 4) for v in m.dimensions)) for m in meshes},
        "groups": {m.name: weight_groups(m) for m in meshes},
    }


def export_rig(armature, meshes, filepath):
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
        bake_space_transform=True,  # <-- the tidy fix: bake Z-up->Y-up into geometry
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


def close(actual, expected, tol=3e-3):
    return all(abs(a - b) <= tol for a, b in zip(actual, expected))


def validate_round_trip(filepath, expected):
    bpy.ops.wm.read_factory_settings(use_empty=True)
    result = bpy.ops.import_scene.fbx(filepath=str(filepath), use_anim=False)
    if "FINISHED" not in result:
        raise RuntimeError(f"Failed to round-trip import {filepath}")
    armatures = [o for o in bpy.context.scene.objects if o.type == "ARMATURE"]
    if len(armatures) != 1:
        raise RuntimeError(f"Expected one armature, found {len(armatures)}")
    armature = armatures[0]
    if len(armature.data.bones) != expected["bone_count"]:
        raise RuntimeError("Bone count changed during the baked round trip")
    meshes = {o.name: o for o in bpy.context.scene.objects if o.type == "MESH"}
    for name in MESH_NAMES:
        mesh = meshes.get(name)
        if mesh is None:
            raise RuntimeError(f"Round-trip FBX is missing {name}")
        if mesh.parent != armature:
            raise RuntimeError(f"Round-trip {name} lost its armature parent")
        got = tuple(sorted(round(v, 4) for v in mesh.dimensions))
        if not close(got, expected["sorted_dims"][name]):
            raise RuntimeError(
                f"{name} shape changed: {got} != {expected['sorted_dims'][name]}"
            )
        if weight_groups(mesh) != expected["groups"][name]:
            raise RuntimeError(f"{name} skin-weight groups changed during the bake")


def main():
    source_path, armature, meshes = require_data()
    reset_pose(armature)
    expected = capture_metrics(armature, meshes)
    output_name = OUTPUT_BY_SOURCE[source_path.name]
    output_path = source_path.parent.parent / "exports" / output_name
    output_path.parent.mkdir(parents=True, exist_ok=True)

    export_rig(armature, meshes, output_path)
    validate_round_trip(output_path, expected)

    print("TIDY_RIG_SOURCE", source_path.name)
    print("TIDY_RIG_EXPORTED", output_path)
    print("TIDY_RIG_METRICS", expected)
    print("TIDY_RIG_VALIDATION_OK")


main()
