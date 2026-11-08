{
  description = "Nix packages and a NixOS module for Strata, the MoE inference engine (unofficial)";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

    strata = {
      # A release tag. .github/workflows/update-strata.yml moves this, `version` below
      # and the llama-cpp input to each new release.
      url = "github:niko1221/strata/v0.2.12";
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
      lib = nixpkgs.lib;

      # The release (the tag above).
      version = "0.2.12";

      cmakeLists = builtins.readFile "${strataSrc}/CMakeLists.txt";
      firstMatch = re: builtins.head (builtins.elemAt (builtins.split re cmakeLists) 1);
      # The engine's own version, as `strata --version` reports it.
      engineVersion = firstMatch "project\\(strata VERSION ([0-9.]+)";
      # The llama.cpp commit Strata's CMakeLists.txt fetches; the llama-cpp input must be it.
      pinnedLlamaCpp = firstMatch "GIT_TAG ([0-9a-f]{40})";
      llamaCppSrc =
        if llama-cpp.rev == pinnedLlamaCpp then
          llama-cpp
        else
          throw "the llama-cpp input is ${llama-cpp.rev}, but Strata ${version} pins ${pinnedLlamaCpp}: update it in flake.nix";

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
              inherit llamaCppSrc;
              buildId = builtins.substring 0 9 strataSrc.rev;
              version = engineVersion;
            }
            // lib.optionalAttrs (cudaCapabilities != null) { inherit cudaCapabilities; }
          );
          strata = pkgs.callPackage ./pkgs/strata.nix {
            inherit strataSrc;
            inherit llamaCppSrc;
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
        gpus = import ./lib/gpus.nix { inherit lib; };
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
