"""Write models.json, the models services.strata.model can name, from Strata's setup.py.

setup.py pins every model file to a Hugging Face revision, size and SHA-256; this copies those
pins so Nix can read them. Run by scripts/update-strata.sh on each release.

Usage: python3 scripts/gen-models.py STRATA_SOURCE > models.json
"""
import json
import sys

sys.dont_write_bytecode = True
sys.path.insert(0, sys.argv[1])
import setup  # noqa: E402  (Strata's setup.py; importing it has no side effects)

# The families with a GGUF the engine reads directly (no pack to build beyond the tokenizer).
FAMILIES = ["qwen36"]

out = {}
for key in FAMILIES:
    fam = setup.OWN_PATH_FAMILIES[key]
    for variant, about in fam["models"].items():
        file = fam["file"].format(q=variant)
        size, sha256 = fam["sha256"][file]
        out[f"{fam['name']}:{variant}"] = {
            "title": f"{fam['title']} {variant}",
            "about": about["about"],
            "ramGb": about["ram_gb"],
            "url": fam["hf"] + file,
            "file": file,
            "size": size,
            "sha256": sha256,
            "modelName": f"{fam['name']}-{variant.lower()}",
            "arch": fam["arch"],
            "mtp": fam["mtp"],
            "context": setup.own_path_context(fam, 0.0),
            "license": fam.get("license"),
        }

json.dump(out, sys.stdout, indent=2, sort_keys=True)
sys.stdout.write("\n")
