"""Write models.json, the models services.strata.model can name, from Strata's setup.py.

Two kinds of entry:

- "native": a single GGUF the engine reads directly (Qwen3.6). setup.py's pins (Hugging Face
  revision, size, SHA-256) are copied here, and the module downloads and prepares it itself.
- "setup": everything else. Preparing these (expert packs, the MTP draft layer, the n-gram
  table) and choosing their engine arguments for the machine's RAM and VRAM is what setup.py
  does, so the module runs setup.py for them. Only the names and descriptions are copied.

Run by scripts/update-strata.sh on each release.

Usage: python3 scripts/gen-models.py STRATA_SOURCE > models.json
"""
import json
import sys

sys.dont_write_bytecode = True
sys.path.insert(0, sys.argv[1])
import setup  # noqa: E402  (Strata's setup.py; importing it has no side effects)

out = {}


def entry(fam, key, model, about, ram_gb, **extra):
    out[f"{fam['name']}:{model}"] = {
        "title": f"{fam['title']} {model}",
        "family": key,
        "model": model,
        "about": about,
        "ramGb": ram_gb,
        "license": fam.get("license"),
        # The run config setup.py writes for it (home() / f"strata-{tag.lower()}.json").
        "configName": f"strata-{(fam['tag'] + model).lower()}.json",
        **extra,
    }


for key, fam in setup.OWN_PATH_FAMILIES.items():
    for model, d in fam["models"].items():
        file = fam["file"].format(q=model)
        size, sha256 = fam["sha256"][file]
        entry(fam, key, model, d["about"], d["ram_gb"], kind="native", engine="strata",
              url=fam["hf"] + file, file=file, size=size, sha256=sha256,
              modelName=f"{fam['name']}-{model.lower()}", arch=fam["arch"], mtp=fam["mtp"],
              context=setup.own_path_context(fam, 0.0))

for key, fam in setup.FAMILIES.items():
    for model, d in setup.MODELS.items():
        # setup.py's own rule: a size names its families, and a size that names none is Qwen's and Swift's.
        if key in d.get("families", ("qwen", "swift")):
            entry(fam, key, model, d["about"], d["ram_gb"], kind="setup", engine="strata",
                  nvfp4Local=model in setup.MODELS and setup.MODELS[model].get("repo") == setup.NVFP4_FP4LOCAL_REPO)

for key, fam in setup.MULTI_FILE_FAMILIES.items():
    for model, d in fam["models"].items():
        entry(fam, key, model, d["about"], d["ram_gb"], kind="setup", engine="dsv41", nvfp4Local=False)

json.dump(out, sys.stdout, indent=2, sort_keys=True)
sys.stdout.write("\n")
