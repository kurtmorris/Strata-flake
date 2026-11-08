# The Strata engine (the C++/CUDA `strata` binary) for NVIDIA GPUs, or with `dsv41`
# the separate DeepSeek-V4.1 engine (`strata-dsv41`).
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
  dsv41 ? false,
}:

let
  gpus = import ../lib/gpus.nix { inherit lib; };
  exe = if dsv41 then "strata-dsv41" else "strata";
in
cudaPackages.backendStdenv.mkDerivation {
  pname = if dsv41 then "strata-dsv41" else "strata-engine";
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
  ]
  ++ lib.optional dsv41 (lib.cmakeBool "STRATA_BUILD_DSV41" true);

  ninjaFlags = [ exe ];

  installPhase = ''
    runHook preInstall
    install -Dm755 ${exe} $out/bin/${exe}
    runHook postInstall
  '';

  passthru = { inherit cudaCapabilities; };

  meta = {
    description = "Strata: MoE inference engine that keeps hot experts in VRAM and the rest in RAM";
    homepage = "https://github.com/niko1221/strata";
    license = lib.licenses.mit;
    platforms = [ "x86_64-linux" ];
    mainProgram = exe;
  };
}
