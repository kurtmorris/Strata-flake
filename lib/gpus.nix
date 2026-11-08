# Friendly GPU names -> CUDA compute capabilities.
#
# Users know their card ("an RTX 4070"), not its compute capability ("8.9"), so the
# module takes these names and compiles them down to the same capability strings
# nixpkgs uses for `config.cudaCapabilities`.
#
# Strata supports compute capability 7.5 and newer (RTX 20 series onward); its
# CMake refuses anything older.
{ lib }:

rec {
  capabilities = {
    rtx-20 = "7.5"; # Turing: RTX 2060-2080 Ti, Quadro RTX, GTX 16xx
    rtx-30 = "8.6"; # Ampere: RTX 3050-3090 Ti, RTX A-series
    rtx-40 = "8.9"; # Ada: RTX 4060-4090, RTX 6000 Ada
    rtx-50 = "12.0"; # Blackwell: RTX 5060-5090, RTX PRO Blackwell
  };

  names = builtins.attrNames capabilities;

  # What upstream's ready-made engine is built for: every consumer generation.
  default = builtins.attrValues capabilities;

  toCapabilities = gpus: lib.unique (map (g: capabilities.${g}) gpus);

  # "8.9" -> "89", for CMAKE_CUDA_ARCHITECTURES.
  toCmakeArchitectures = caps: lib.concatMapStringsSep ";" (lib.replaceStrings [ "." ] [ "" ]) caps;
}
