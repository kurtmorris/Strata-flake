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
            modelName = "qwen3.6-35b-a3b";
            tokenizer = "/var/lib/strata/pack/tokenizer";
            engineArgs = [
              "--native" "/srv/models/Qwen3.6-35B-A3B-UD-Q4_K_XL.gguf"
              "--max-context" "65536"
              "--prefill" "auto"
              "--mtp" "2"
            ];
          };
        }
      ];
    };
  };
}
```

The server is an OpenAI-compatible API (and a chat page) on `http://127.0.0.1:8080`.

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
- The model files and the server's settings are declared in the module, not set up by `setup.py`.

## License

MIT, as Strata itself.
