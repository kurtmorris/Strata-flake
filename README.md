# Strata-flake

Nix packages and a NixOS module for [Strata](https://github.com/niko1221/strata), an inference
engine that runs Mixture-of-Experts models larger than your VRAM: the most-used experts stay on
the GPU, and the rest are computed on the CPU from RAM.

> **Unofficial.** This flake is not affiliated with the Strata project. Report packaging problems
> here, and engine problems upstream.

Status: x86_64-linux with NVIDIA GPUs (CUDA). AMD (ROCm) and aarch64 (DGX Spark) are not packaged yet.

## Usage

```nix
{
  inputs.strata-flake.url = "github:kurtmorris/Strata-flake";

  outputs = { nixpkgs, strata-flake, ... }: {
    nixosConfigurations.my-pc = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      modules = [
        strata-flake.nixosModules.default
        {
          nixpkgs.config.allowUnfree = true; # the CUDA toolkit is unfree

          services.strata = {
            enable = true;
            gpus = [ "rtx-40" ];
            model = "qwen3.6-35b-a3b:UD-Q4_K_XL";
          };
        }
      ];
    };
  };
}
```

The server is an OpenAI-compatible API (and a chat page) on `http://127.0.0.1:8080`.

### Choosing a model

`model` names one of the 35 models in Strata's catalogue, as `family:size`. On first start,
`strata-model.service` downloads it to `/var/lib/strata/models` (`modelsDir` changes that) and prepares
it; later starts skip that. Models are kept out of the Nix store on purpose: they are tens to hundreds
of gigabytes, and garbage collection would delete them whenever you change models.

| Family (`model = "<family>:<size>"`) | Sizes | RAM (upstream's figures) |
|---|---|---|
| `qwen3.6-35b-a3b` | `UD-Q4_K_XL`, `UD-Q6_K_XL`, `Q8_0` | 32 to 52 GB |
| `qwen3.8-flash-next` | `Q2_0`, `IQ2_XS`, `IQ3_XXS`, `IQ3_S` | 48 to 62 GB |
| `qwen3.8-flash-next-coder` | `IQ1_M` | 32 GB |
| `swift-1.5` | `IQ2_XS`, `IQ3_XXS`, `IQ3_S` | 48 to 62 GB |
| `qwen3.8-flash-next-unsloth` | `UD-IQ1_M`, `UD-Q2_0`, `UD-IQ2_XS`, `UD-Q2_K_XL`, `UD-IQ3_XXS`, `UD-Q3_K_XL`, `UD-IQ4_XS`, `UD-IQ4_XS-v31`, `UD-Q4_K_XL`, `UD-Q5_K_XL`, `UD-Q6_K_XL`, `Q8_0` | 48 to 136 GB |
| `qwen3.8-flash-next-gyro` | `Gyro-S`, `Gyro-M` | 28 to 35 GB (VRAM + RAM) |
| `qwen3.8-flash-next-nvfp4` | `NVFP4`, `NVFP4-NVIDIA`, `NVFP4-QAD` | 80 GB |
| `deepseek-v4.1-flash` | `ISTA-DAS-Coder`, `IST-DAS-1.75bpw`, `IST-DAS-2.00bpw`, `IST-DAS-2.25bpw`, `UD-IQ1_S`, `UD-IQ1_M`, `UD-Q8_K_XL` | 24 to 306 GB |

The option's description (`nixos-option services.strata.model`, or `models.json`) says what each size
is. A few notes:

- **Qwen3.6** is downloaded and checked against the SHA-256 Strata pins by the module itself.
- **Every other model is prepared by upstream's `setup.py`**, run non-interactively in the mode Strata's
  desktop app uses: it downloads the files, builds the expert pack and draft layer, and picks the engine
  settings for this machine's RAM and VRAM (KV cache type, resident or streamed experts, and so on). It
  runs again only when the model, `context`, `setupArgs` or Strata changes. Pass `setup.py` options it
  would otherwise choose itself with `setupArgs`, e.g. `[ "--low-ram" "resident" ]`.
- **DeepSeek** runs on its own engine, `strata-dsv41`, which is only compiled when you choose a
  DeepSeek model. Its downloads include a 111 GB n-gram table: 200 to 500 GB of disk in all.
- **NVFP4-QAD** converts NVIDIA's 102 GB checkpoint on your machine (20 to 40 minutes, 110 GB more
  disk), with PyTorch added to Strata's Python only for this model. RTX 50 cards run NVFP4 models on
  their FP4 tensor cores; other cards run them at 8-bit precision.
- `context` (default: upstream's recommendation, 128K tokens) trades context length for VRAM the
  experts could use.

For a model outside the catalogue, leave `model` unset and give `modelName`, `tokenizer` and
`engineArgs` yourself (`strata-tokenizer --gguf FILE --out DIR` makes the tokenizer).

### Choosing your GPU

You don't need to know your card's CUDA compute capability. Pick its generation:

| `gpus` value | Cards |
|---|---|
| `rtx-20` | RTX 2060 to 2080 Ti, GTX 16xx, Quadro RTX |
| `rtx-30` | RTX 3050 to 3090 Ti, RTX A-series |
| `rtx-40` | RTX 4060 to 4090, RTX 6000 Ada |
| `rtx-50` | RTX 5060 to 5090, RTX PRO Blackwell |

List several for a mixed-GPU machine. If `gpus` is empty, the flake uses `nixpkgs.config.cudaCapabilities`
when you have set it, otherwise every generation above. `services.strata.cudaCapabilities` takes raw values
(`[ "8.9" ]`) when you need exact control.

### Build time

There is no binary cache: the engine is compiled on your machine, and each generation in `gpus` adds
compile time. Naming only your own card is the biggest saving.

### Without NixOS

```sh
NIXPKGS_ALLOW_UNFREE=1 nix build --impure github:kurtmorris/Strata-flake
./result/bin/strata-server --engine strata --config strata.json
```

The packages are built for every generation. For a smaller build, use the flake's `lib.mkPackages`:

```nix
(strata-flake.lib.mkPackages pkgs { cudaCapabilities = [ "8.9" ]; }).strata
```

## Differences from upstream's installer

- The engine is built from source with CUDA 13.0 (upstream's choice; 13.2 miscompiles for RTX 50).
- ggml's CPU code is built for an AVX2 baseline rather than `-march=native`, as upstream's ready-made
  engine is; Strata's own AVX-512 kernels are still chosen at run time.
- The update check and engine downloads are off; update by updating this flake. A daily workflow
  opens a pull request for each new Strata release (`scripts/update-strata.sh` does the same by hand).
- `setup.py` never installs Python packages or engines here: the module runs it only to download and
  prepare models, and points the run config it writes at this flake's engine.
- Picture input (the vision encoder) is not packaged yet, so models are set up with images off.

## License

MIT, as Strata itself.
