#!/usr/bin/env python3
"""Copy the production environment into N more, each drifted a little.

    make_envs.py <environments-dir> <count>

Every copy is a full, separate tree, as r10k deploys them. In each one, 10
modules get an edited manifest (so their documentation has to be rebuilt) and 3
modules are removed (so the module sets differ).
"""
import glob, os, random, shutil, sys
envs, count = sys.argv[1], int(sys.argv[2])
src = os.path.join(envs, "production")
names = ["staging", "qa"] + [f"team{n:02d}_feature" for n in range(1, count - 1)]
for i, name in enumerate(names[:count]):
    dest = os.path.join(envs, name)
    if os.path.isdir(dest):
        continue
    shutil.copytree(src, dest, symlinks=True)
    rng = random.Random(i)
    mods = sorted(os.listdir(os.path.join(dest, "modules")))
    for mod in rng.sample(mods, 3):
        shutil.rmtree(os.path.join(dest, "modules", mod))
    edited = 0
    for mod in rng.sample(mods, 40):
        pps = sorted(glob.glob(os.path.join(dest, "modules", mod, "manifests", "**", "*.pp"), recursive=True))
        if not pps:
            continue
        with open(pps[0], "a") as f:
            f.write(f"\n# drift in {name}\n")
        edited += 1
        if edited == 10:
            break
print(len([d for d in os.listdir(envs) if os.path.isdir(os.path.join(envs, d))]), "environments")
