# The Strata engine (the C++/CUDA `strata` binary) for NVIDIA GPUs.
{
  lib,
  cudaPackages,
  cmake,
  ninja,
  autoAddDriverRunpath,
  strataSrc,
  llamaCppSrc,
  version,
  buildId,
  # CUDA compute capabilities to compile for, e.g. [ "8.9" "12.0" ].
  cudaCapabilities ? (import ../lib/gpus.nix { inherit lib; }).default,
}:

let
  gpus = import ../lib/gpus.nix { inherit lib; };
in
cudaPackages.backendStdenv.mkDerivation {
  pname = "strata-engine";
  inherit version;
  src = strataSrc;

  nativeBuildInputs = [
    cmake
    ninja
    cudaPackages.cuda_nvcc
    autoAddDriverRunpath
  ];

  buildInputs = with cudaPackages; [
    cuda_cudart
    cccl
    libcublas
  ];

  # The build fetches llama.cpp's ggml at a pinned commit with FetchContent; hand it
  # the same commit from the store instead. It is copied so the configure step can
  # write its overlay headers next to it.
  preConfigure = ''
    cp -r ${llamaCppSrc} "$NIX_BUILD_TOP/llama.cpp"
    chmod -R u+w "$NIX_BUILD_TOP/llama.cpp"
    cmakeFlagsArray+=("-DFETCHCONTENT_SOURCE_DIR_STRATA_LLAMACPP=$NIX_BUILD_TOP/llama.cpp")
  '';

  cmakeFlags = [
    (lib.cmakeBool "STRATA_ENABLE_CUDA" true)
    # AVX2 baseline for ggml instead of -march=native: the result must not depend on
    # the build machine. Strata's own AVX-512 kernels are still picked at run time.
    (lib.cmakeBool "STRATA_PORTABLE" true)
    (lib.cmakeBool "STRATA_BUILD_TESTS" false)
    (lib.cmakeBool "FETCHCONTENT_FULLY_DISCONNECTED" true)
    (lib.cmakeFeature "STRATA_BUILD_ID" buildId)
    (lib.cmakeFeature "CMAKE_CUDA_ARCHITECTURES" (gpus.toCmakeArchitectures cudaCapabilities))
  ];

  ninjaFlags = [ "strata" ];

  installPhase = ''
    runHook preInstall
    install -Dm755 strata $out/bin/strata
    runHook postInstall
  '';

  passthru = { inherit cudaCapabilities; };

  meta = {
    description = "Strata: MoE inference engine that keeps hot experts in VRAM and the rest in RAM";
    homepage = "https://github.com/niko1221/strata";
    license = lib.licenses.mit;
    platforms = [ "x86_64-linux" ];
    mainProgram = "strata";
  };
}
