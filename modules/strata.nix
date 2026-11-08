# services.strata: run Strata's OpenAI-compatible server as a systemd service.
#
# Hardware can't be probed at build time the way upstream's installer does, so the
# GPU generation is declared here and the engine is compiled for it.
#
# Models from upstream's catalogue (../models.json, generated from setup.py) are
# downloaded at run time by strata-model.service, not into the Nix store: they are
# tens of gigabytes, and garbage collection would delete them on every model change.
# A "native" model (a single GGUF) is downloaded and prepared here; any other is
# prepared by upstream's setup.py, which also picks its engine arguments for this
# machine's RAM and VRAM.
{ mkPackages }:

{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.services.strata;
  # Fixed by StateDirectory = "strata".
  stateDir = "/var/lib/strata";
  gpus = import ../lib/gpus.nix { inherit lib; };
  catalogue = lib.importJSON ../models.json;
  json = pkgs.formats.json { };

  globalCaps = config.nixpkgs.config.cudaCapabilities or null;

  capabilities =
    if cfg.cudaCapabilities != null then
      cfg.cudaCapabilities
    else if cfg.gpus != [ ] then
      gpus.toCapabilities cfg.gpus
    else if globalCaps != null then
      globalCaps
    else
      gpus.default;

  packages = mkPackages pkgs {
    cudaCapabilities = capabilities;
    withNvfp4Local = model != null && model.nvfp4Local or false;
  };

  model = if cfg.model != null then catalogue.${cfg.model} else null;
  native = model != null && model.kind == "native";
  viaSetup = model != null && model.kind == "setup";

  gguf = "${cfg.modelsDir}/${model.file}";
  pack = "${stateDir}/packs/${model.modelName}";
  # Where setup.py installs to, and the run config it writes there.
  installDir = "${stateDir}/install";
  setupConfig = "${stateDir}/setup-run.json";

  # The run config before the machine-dependent parts: from the options, or from setup.py.
  baseConfig =
    if viaSetup then
      setupConfig
    else
      json.generate "strata-base.json" (
        {
          exe = lib.getExe cfg.package.strata-engine;
          args = cfg.engineArgs;
          cwd = stateDir;
          tokenizer = cfg.tokenizer;
          model_name = cfg.modelName;
        }
        // lib.optionalAttrs native { inherit (model) arch; }
      );
  overlay = json.generate "strata-overlay.json" ({ inherit (cfg) host; } // cfg.settings);

  # A native model: downloads the file (resuming a partial one), checks its size and
  # SHA-256 once, and extracts its tokenizer. Every step is skipped when already done.
  prepareNative = pkgs.writeShellApplication {
    name = "strata-prepare-model";
    runtimeInputs = with pkgs; [
      coreutils
      curl
    ];
    text = ''
      gguf=${lib.escapeShellArg gguf}
      ok="$gguf.sha256-ok"
      if [ "$(cat "$ok" 2>/dev/null)" != ${model.sha256} ]; then
        if [ ! -f "$gguf" ]; then
          echo "downloading ${model.title} (${
            toString ((model.size + 500000000) / 1000000000)
          } GB) to $gguf"
          curl --fail --location --retry 5 --retry-all-errors --continue-at - \
            --output "$gguf.part" ${lib.escapeShellArg model.url}
          mv "$gguf.part" "$gguf"
        fi
        size=$(stat -c %s "$gguf")
        if [ "$size" != ${toString model.size} ]; then
          echo "$gguf is $size bytes, expected ${toString model.size}: delete it to download again" >&2
          exit 1
        fi
        echo "checking the SHA-256 of $gguf"
        if [ "$(sha256sum "$gguf" | cut -d' ' -f1)" != ${model.sha256} ]; then
          echo "$gguf does not match its pinned SHA-256: delete it to download again" >&2
          exit 1
        fi
        echo ${model.sha256} > "$ok"
      fi

      pack=${lib.escapeShellArg pack}
      if [ ! -f "$pack/tokenizer/vocab.json" ]; then
        echo "extracting the tokenizer to $pack"
        mkdir -p "$pack"
        ${cfg.package}/bin/strata-tokenizer --gguf "$gguf" --out "$pack"
      fi
    '';
  };

  # Any other model: upstream's setup.py, in the mode Strata's desktop app runs it in
  # (STRATA_CONTROL_INSTALL): it downloads and prepares the model and writes a run config,
  # but installs no Python package and fetches or compiles no engine. It runs again only
  # when the model, its settings or Strata change, since checking hundreds of gigabytes
  # takes a while.
  setupCmd = [
    "${cfg.package.python}/bin/python3"
    "-B"
    "setup.py"
    "--family"
    model.family
    "--model"
    model.model
    "--yes"
    "--no-start"
    "--no-browser"
    "--vision"
    "no"
    "--data-dir"
    "${stateDir}/data"
    "--models-dir"
    cfg.modelsDir
  ]
  ++ lib.optionals (cfg.context != null) [
    "--context"
    (toString cfg.context)
  ]
  ++ cfg.setupArgs;

  prepareSetup = pkgs.writeShellApplication {
    name = "strata-prepare-model";
    runtimeInputs = with pkgs; [
      coreutils
      jq
    ];
    text = ''
      install=${installDir}
      run_config="$install/${model.configName}"
      stamp="$install/.prepared"
      want=${lib.escapeShellArg (builtins.toJSON setupCmd)}

      if [ ! -f "$run_config" ] || [ "$(cat "$stamp" 2>/dev/null)" != "$want" ]; then
        # llama.cpp's gguf-py for the preparation tools, from the commit Strata pins.
        mkdir -p "$install/third_party"
        ln -sfn ${cfg.package.llamaCppSrc} "$install/third_party/llama.cpp"
        export STRATA_CONTROL_INSTALL=1 STRATA_INSTALL_DIR="$install"
        ${lib.optionalString (model.engine == "dsv41") ''
          export STRATA_DSV41_EXE=${lib.getExe cfg.dsv41Package}
        ''}
        cd ${cfg.package}/share/strata
        ${lib.escapeShellArgs setupCmd}
        echo "$want" > "$stamp"
      fi

      # The app's engine component is this flake's engine.
      jq --arg exe ${lib.getExe cfg.package.strata-engine} \
        'if (.exe | startswith("component:")) then .exe = $exe else . end' \
        "$run_config" > ${setupConfig}
    '';
  };
in
{
  options.services.strata = {
    enable = lib.mkEnableOption "the Strata MoE inference server";

    gpus = lib.mkOption {
      type = lib.types.listOf (lib.types.enum gpus.names);
      default = [ ];
      example = [ "rtx-50" ];
      description = ''
        The NVIDIA GPU generations to compile the engine for: ${lib.concatStringsSep ", " gpus.names}.
        Listing only your own card cuts the build time considerably. When empty, the
        nixpkgs-wide `nixpkgs.config.cudaCapabilities` is used if set, otherwise all
        of the above.
      '';
    };

    cudaCapabilities = lib.mkOption {
      type = lib.types.nullOr (lib.types.listOf lib.types.str);
      default = null;
      example = [ "8.9" ];
      description = "Advanced: CUDA compute capabilities to compile for. Overrides {option}`services.strata.gpus`.";
    };

    package = lib.mkOption {
      type = lib.types.package;
      default = packages.strata;
      defaultText = lib.literalMD "Strata built for {option}`services.strata.gpus`";
      description = "The Strata package (server and terminal, with its engine as `passthru.strata-engine`).";
    };

    dsv41Package = lib.mkOption {
      type = lib.types.package;
      default = packages.strata-dsv41;
      defaultText = lib.literalMD "the DeepSeek-V4.1 engine built for {option}`services.strata.gpus`";
      description = "The DeepSeek-V4.1 engine, built only when a DeepSeek model is chosen.";
    };

    model = lib.mkOption {
      type = lib.types.nullOr (lib.types.enum (builtins.attrNames catalogue));
      default = null;
      example = "qwen3.6-35b-a3b:UD-Q4_K_XL";
      description = ''
        A model from Strata's catalogue, downloaded to {option}`services.strata.modelsDir` and
        prepared on first start; it sets everything the engine needs. Leave it unset to give
        {option}`services.strata.engineArgs` and the rest yourself. Choices:

        ${lib.concatStrings (
          lib.mapAttrsToList (
            name: m: "- `${name}`: ${m.about}; about ${toString m.ramGb} GB of RAM\n"
          ) catalogue
        )}
      '';
    };

    context = lib.mkOption {
      type = lib.types.nullOr lib.types.ints.positive;
      default = null;
      description = ''
        Context length in tokens. Its cache takes VRAM the experts would otherwise use; lower
        it to fit more experts on a small card. `null` uses upstream's recommendation for the
        model and this machine.
      '';
    };

    setupArgs = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [
        "--low-ram"
        "resident"
        "--kv"
        "q4_0"
      ];
      description = ''
        Extra options for upstream's `setup.py` (`setup.py --help` lists them), for models it
        prepares: every model but Qwen3.6. Changing them prepares the model again.
      '';
    };

    cpuWorkers = lib.mkOption {
      type = lib.types.nullOr (lib.types.either lib.types.ints.positive (lib.types.enum [ "auto" ]));
      default = "auto";
      description = ''
        Threads computing experts on the CPU (`--pool-workers`). `"auto"` uses upstream's
        recommendation, which only applies to CPUs with more efficiency than performance cores;
        `null` leaves it to the engine.
      '';
    };

    modelsDir = lib.mkOption {
      type = lib.types.str;
      default = "${stateDir}/models";
      defaultText = lib.literalExpression ''"/var/lib/strata/models"'';
      description = ''
        Where model files are downloaded: 23 GB for the smallest model, several hundred for the
        largest. A folder outside `/var/lib/strata` must be writable by the `strata` user.
      '';
    };

    host = lib.mkOption {
      type = lib.types.str;
      default = "127.0.0.1";
      description = "Address to listen on. Set {option}`services.strata.apiKeyFile` when listening beyond localhost.";
    };

    port = lib.mkOption {
      type = lib.types.port;
      default = 8080;
      description = "Port of the OpenAI-compatible API and web page.";
    };

    openFirewall = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Open {option}`services.strata.port` in the firewall.";
    };

    apiKeyFile = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      description = "File holding the API key clients must send (several keys: comma-separated). Not copied to the store.";
    };

    modelName = lib.mkOption {
      type = lib.types.str;
      example = "qwen3.6-35b-a3b";
      description = "Model name reported by the API, without {option}`services.strata.model`.";
    };

    tokenizer = lib.mkOption {
      type = lib.types.str;
      example = "/var/lib/strata/packs/my-model/tokenizer";
      description = ''
        The model's tokenizer folder, without {option}`services.strata.model`
        (`strata-tokenizer --gguf FILE --out DIR` makes one in `DIR/tokenizer`).
      '';
    };

    engineArgs = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      example = [
        "--native"
        "/srv/models/Qwen3.6-35B-A3B-UD-Q4_K_XL.gguf"
        "--max-context"
        "65536"
        "--prefill"
        "auto"
        "--mtp"
        "2"
      ];
      description = "Arguments for the engine: the model files and how to run them, without {option}`services.strata.model`.";
    };

    extraEngineArgs = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [
        "--expert-vram"
        "10"
      ];
      description = "Arguments added to the engine's, e.g. to leave VRAM free for other programs.";
    };

    settings = lib.mkOption {
      type = json.type;
      default = { };
      example = {
        sampling.presence_penalty = 0;
        idle_unload_s = 900;
      };
      description = ''
        Extra keys for the server's run config (upstream's `strata-<model>.json`), such as
        `sampling` defaults or `idle_unload_s`. Merged over the generated keys.
      '';
    };

    extraFlags = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [ "--lazy" ];
      description = "Extra command-line flags for the server.";
    };
  };

  config = lib.mkIf cfg.enable (
    lib.mkMerge [
      (lib.mkIf native {
        services.strata = {
          modelName = lib.mkDefault model.modelName;
          tokenizer = lib.mkDefault "${pack}/tokenizer";
          engineArgs = lib.mkDefault [
            "--native"
            gguf
            "--max-context"
            (toString (if cfg.context != null then cfg.context else model.context))
            "--prefill"
            "auto"
            "--mtp"
            (toString model.mtp)
          ];
        };
      })

      (lib.mkIf (model != null) {
        systemd.services.strata-model = {
          description = "Download and prepare Strata's model";
          wants = [ "network-online.target" ];
          after = [ "network-online.target" ];
          environment = {
            STRATA_UPDATE_CHECK = "0";
            HOME = stateDir;
          };
          # setup.py reads the GPUs from nvidia-smi.
          path = lib.optional viaSetup config.hardware.nvidia.package.bin;
          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
            ExecStart = lib.getExe (if native then prepareNative else prepareSetup);
            User = "strata";
            Group = "strata";
            StateDirectory = "strata";
            # A first download is large, and preparing NVIDIA's FP4 checkpoint takes up to 40 minutes.
            TimeoutStartSec = "infinity";
          };
        };

        systemd.tmpfiles.settings.strata.${cfg.modelsDir}.d = {
          user = "strata";
          group = "strata";
          mode = "0750";
        };
      })

      {
        warnings =
          lib.optional (cfg.gpus == [ ] && cfg.cudaCapabilities == null && globalCaps == null) ''
            services.strata.gpus is not set, so the engine is compiled for every supported GPU
            generation (${lib.concatStringsSep ", " gpus.names}). Set it to your card, e.g.
            services.strata.gpus = [ "rtx-40" ]; to build much faster.
          ''
          ++ lib.optional (cfg.host != "127.0.0.1" && cfg.host != "::1" && cfg.apiKeyFile == null) ''
            services.strata listens on ${cfg.host} without services.strata.apiKeyFile: anyone who can
            reach port ${toString cfg.port} can use the model.
          ''
          ++ lib.optional (cfg.setupArgs != [ ] && !viaSetup) ''
            services.strata.setupArgs only applies to models prepared by setup.py (every model but Qwen3.6).
          '';

        users.users.strata = {
          isSystemUser = true;
          group = "strata";
          extraGroups = [
            "video"
            "render"
          ];
          home = stateDir;
        };
        users.groups.strata = { };

        networking.firewall.allowedTCPPorts = lib.mkIf cfg.openFirewall [ cfg.port ];

        systemd.services.strata = {
          description = "Strata MoE inference server";
          wantedBy = [ "multi-user.target" ];
          after = [ "network.target" ] ++ lib.optional (model != null) "strata-model.service";
          requires = lib.optional (model != null) "strata-model.service";

          environment = {
            STRATA_UPDATE_CHECK = "0";
            STRATA_STATE_DIR = stateDir;
            HOME = stateDir;
          };

          path = [ pkgs.jq ];

          # The run config: the base one, the options over it, and the CPU worker count,
          # which depends on the machine.
          script = ''
            ${lib.optionalString (cfg.apiKeyFile != null) ''
              STRATA_API_KEY="$(< "$CREDENTIALS_DIRECTORY/api-key")"
              export STRATA_API_KEY
            ''}
            workers=${
              if cfg.cpuWorkers == "auto" then
                "$(${cfg.package}/bin/strata-pool-workers)"
              else if cfg.cpuWorkers == null then
                ""
              else
                toString cfg.cpuWorkers
            }
            config="$RUNTIME_DIRECTORY/strata.json"
            jq --slurpfile overlay ${overlay} --arg w "$workers" \
              --argjson extra ${lib.escapeShellArg (builtins.toJSON cfg.extraEngineArgs)} '
                (. * $overlay[0])
                | .args += $extra
                | .lib_dirs = ((.lib_dirs // []) + ["/run/opengl-driver/lib"] | unique)
                | if $w != "" and (.args | index("--pool-workers") | not) then .args += ["--pool-workers", $w] else . end
              ' ${baseConfig} > "$config"

            exec ${lib.getExe cfg.package} --engine strata --config "$config" --port ${toString cfg.port} \
              ${lib.escapeShellArgs (
                lib.optional (cfg.host != "127.0.0.1" && cfg.apiKeyFile == null) "--no-api-key" ++ cfg.extraFlags
              )}
          '';

          serviceConfig = {
            User = "strata";
            Group = "strata";
            StateDirectory = "strata";
            RuntimeDirectory = "strata";
            WorkingDirectory = stateDir;
            LoadCredential = lib.optional (cfg.apiKeyFile != null) "api-key:${cfg.apiKeyFile}";
            # Strata pins every expert in RAM.
            LimitMEMLOCK = "infinity";
            Restart = "on-failure";
            RestartSec = 10;
            # Loading a large model takes minutes.
            TimeoutStartSec = "15min";
            NoNewPrivileges = true;
            ProtectSystem = "strict";
            ProtectHome = "read-only";
            ReadWritePaths = [ cfg.modelsDir ];
            PrivateTmp = true;
          };
        };
      }
    ]
  );
}
