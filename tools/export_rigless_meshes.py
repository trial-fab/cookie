"""Export the goo as two rigless meshes (SlimeBody + SlimeEyes) for the old
procedural (Size-driven) animation path.

No armature, no bones, no skin data -- just two plain MeshParts that Roblox can
resize. bake_space_transform=True is safe here (nothing to misalign) and yields
an identity pivot on import. The two meshes ship in one FBX so Studio imports a
body + eyes model; the eyes stay their own part so code can keep them tinted and
placed on the body surface as it resizes.

Run once per source blend:

    ~/tools/blender-5.1.2-linux-x64/blender -b docs/blender/sources/goo2.blend \
        --python tools/export_rigless_meshes.py
    ~/tools/blender-5.1.2-linux-x64/blender -b docs/blender/sources/goo2_titan.blend \
        --python tools/export_rigless_meshes.py

Output name is derived from the blend:
    goo2.blend        -> exports/goo_norig.fbx
    goo2_titan.blend  -> exports/titan_goo_norig.fbx
"""

from pathlib import Path

import bpy


ARMATURE_NAME = "GooRig"
MESH_NAMES = ("SlimeBody", "SlimeEyes")

OUTPUT_BY_SOURCE = {
    "goo2.blend": "goo_norig.fbx",
    "goo2_titan.blend": "titan_goo_norig.fbx",
}


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
        raise RuntimeError(f"Open one of {sorted(OUTPUT_BY_SOURCE)}, opened {source_path.name!r}")
    armature = bpy.data.objects.get(ARMATURE_NAME)
    if armature and armature.type == "ARMATURE":
        armature.animation_data_create()
        armature.animation_data.action = None
        for bone in armature.pose.bones:
            bone.matrix_basis.identity()
    meshes = []
    for name in MESH_NAMES:
        mesh = bpy.data.objects.get(name)
        if mesh is None or mesh.type != "MESH":
            raise RuntimeError(f"Missing mesh {name!r}")
        meshes.append(mesh)
    bpy.context.view_layer.update()
    return source_path, meshes


def strip_rig(mesh):
    # Drop armature deformation so this becomes a plain, resizable MeshPart.
    for modifier in list(mesh.modifiers):
        if modifier.type == "ARMATURE":
            mesh.modifiers.remove(modifier)
    world = mesh.matrix_world.copy()
    mesh.parent = None
    mesh.matrix_world = world


def sorted_dims(mesh):
    return tuple(sorted(round(v, 4) for v in mesh.dimensions))


def export_meshes(meshes, filepath):
    select_only(meshes, meshes[0])
    bpy.ops.export_scene.fbx(
        filepath=str(filepath),
        check_existing=False,
        use_selection=True,
        object_types={"MESH"},
        global_scale=1.0,
        apply_unit_scale=True,
        apply_scale_options="FBX_SCALE_UNITS",
        use_space_transform=True,
        bake_space_transform=True,
        axis_forward="-Z",
        axis_up="Y",
        use_custom_props=False,
        use_mesh_modifiers=True,
        use_mesh_modifiers_render=True,
        mesh_smooth_type="FACE",
        use_tspace=True,
        bake_anim=False,
    )


def close(actual, expected, tol=3e-3):
    return all(abs(a - b) <= tol for a, b in zip(actual, expected))


def validate_round_trip(filepath, expected_dims):
    bpy.ops.wm.read_factory_settings(use_empty=True)
    result = bpy.ops.import_scene.fbx(filepath=str(filepath), use_anim=False)
    if "FINISHED" not in result:
        raise RuntimeError(f"Failed to round-trip import {filepath}")
    armatures = [o for o in bpy.context.scene.objects if o.type == "ARMATURE"]
    if armatures:
        raise RuntimeError(f"Rigless export unexpectedly contains {len(armatures)} armature(s)")
    meshes = {o.name.split(".")[0]: o for o in bpy.context.scene.objects if o.type == "MESH"}
    for name in MESH_NAMES:
        mesh = meshes.get(name)
        if mesh is None:
            raise RuntimeError(f"Round-trip FBX is missing {name}")
        if any(m.type == "ARMATURE" for m in mesh.modifiers):
            raise RuntimeError(f"{name} still has an armature modifier")
        got = sorted_dims(mesh)
        if not close(got, expected_dims[name]):
            raise RuntimeError(f"{name} shape changed: {got} != {expected_dims[name]}")


def main():
    source_path, meshes = require_data()
    expected_dims = {m.name: sorted_dims(m) for m in meshes}
    for mesh in meshes:
        strip_rig(mesh)
    bpy.context.view_layer.update()

    output_name = OUTPUT_BY_SOURCE[source_path.name]
    output_path = source_path.parent.parent / "exports" / output_name
    output_path.parent.mkdir(parents=True, exist_ok=True)
    export_meshes(meshes, output_path)
    validate_round_trip(output_path, expected_dims)

    print("RIGLESS_SOURCE", source_path.name)
    print("RIGLESS_EXPORTED", output_path)
    print("RIGLESS_DIMS", expected_dims)
    print("RIGLESS_VALIDATION_OK")


main()
