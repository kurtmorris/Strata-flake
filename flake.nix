{
  description = "Nix packages and a NixOS module for Strata, the MoE inference engine (unofficial)";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

    strata = {
      url = "github:niko1221/strata/146df3c468739147f520ac3816de806f71232571";
      flake = false;
    };
    # The llama.cpp commit Strata's CMakeLists.txt pins (its ggml is compiled in).
    llama-cpp = {
      url = "github:ggml-org/llama.cpp/3cf03257f219afbe7334045ff7c6a06ac68c627d";
      flake = false;
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      strata,
      llama-cpp,
    }:
    let
      system = "x86_64-linux";
      strataSrc = strata;
      version = "0.1.58";

      # Build Strata against any nixpkgs instance. CUDA 13.0 on purpose: upstream's
      # ready-made engine uses it, and 13.2 miscompiles for sm_120 (RTX 50).
      mkPackages =
        pkgs:
        {
          cudaCapabilities ? null,
        }:
        rec {
          strata-engine = pkgs.callPackage ./pkgs/strata-engine.nix (
            {
              cudaPackages = pkgs.cudaPackages_13_0;
              inherit strataSrc;
              llamaCppSrc = llama-cpp;
              buildId = builtins.substring 0 9 strataSrc.rev;
              inherit version;
            }
            // nixpkgs.lib.optionalAttrs (cudaCapabilities != null) { inherit cudaCapabilities; }
          );
          strata = pkgs.callPackage ./pkgs/strata.nix {
            inherit strataSrc;
            inherit version strata-engine;
          };
        };

      pkgs = import nixpkgs {
        inherit system;
        config.allowUnfree = true;
      };
    in
    {
      lib = {
        inherit mkPackages;
        gpus = import ./lib/gpus.nix { inherit (nixpkgs) lib; };
      };

      packages.${system} = (mkPackages pkgs { }) // {
        default = self.packages.${system}.strata;
      };

      nixosModules = {
        strata = import ./modules/strata.nix { inherit mkPackages; };
        default = self.nixosModules.strata;
      };

      formatter.${system} = pkgs.nixfmt;
    };
}
