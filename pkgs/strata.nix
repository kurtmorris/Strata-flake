# Strata's Python side (the OpenAI-compatible server and the `strata` terminal),
# wired to a Nix-built engine.
{
  lib,
  stdenvNoCC,
  python3,
  makeWrapper,
  strataSrc,
  version,
  strata-engine,
}:

let
  python = python3.withPackages (
    ps: with ps; [
      numpy
      jinja2
      regex
      pyyaml
      tqdm
      requests
      pillow
      psutil
      truststore
    ]
  );
in
stdenvNoCC.mkDerivation {
  pname = "strata";
  inherit version;
  src = strataSrc;

  nativeBuildInputs = [ makeWrapper ];

  dontConfigure = true;
  dontBuild = true;

  installPhase = ''
    runHook preInstall
    mkdir -p $out/share/strata $out/bin
    cp -r bin serve strata_cli strata_control strata.py setup.py tools data $out/share/strata/

    # Strata's engine needs the driver's libcuda, which NixOS keeps in /run/opengl-driver/lib.
    makeWrapper $out/share/strata/bin/strata $out/bin/strata \
      --set STRATA_PYTHON ${python}/bin/python3 \
      --set STRATA_UPDATE_CHECK 0 \
      --prefix LD_LIBRARY_PATH : /run/opengl-driver/lib
    makeWrapper ${python}/bin/python3 $out/bin/strata-server \
      --add-flags $out/share/strata/serve/server.py \
      --set STRATA_UPDATE_CHECK 0 \
      --prefix LD_LIBRARY_PATH : /run/opengl-driver/lib
    ln -s ${strata-engine}/bin/strata $out/bin/strata-engine
    runHook postInstall
  '';

  passthru = { inherit python strata-engine; };

  meta = strata-engine.meta // {
    description = "Strata server and terminal for MoE models too large for VRAM";
    mainProgram = "strata-server";
  };
}
