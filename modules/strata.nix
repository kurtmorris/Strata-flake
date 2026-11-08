# services.strata: run Strata's OpenAI-compatible server as a systemd service.
#
# Hardware can't be probed at build time the way upstream's installer does, so the
# GPU generation is declared here and the engine is compiled for it.
{ mkPackages }:

{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.services.strata;
  gpus = import ../lib/gpus.nix { inherit lib; };
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

  serverConfig = json.generate "strata.json" (
    {
      exe = lib.getExe cfg.package.strata-engine;
      args = cfg.engineArgs;
      cwd = "/var/lib/strata";
      tokenizer = cfg.tokenizer;
      model_name = cfg.modelName;
      lib_dirs = [ "/run/opengl-driver/lib" ];
      inherit (cfg) host port;
    }
    // cfg.settings
  );
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
      default = (mkPackages pkgs { cudaCapabilities = capabilities; }).strata;
      defaultText = lib.literalMD "Strata built for {option}`services.strata.gpus`";
      description = "The Strata package (server and terminal, with its engine as `passthru.strata-engine`).";
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
      description = "Model name reported by the API.";
    };

    tokenizer = lib.mkOption {
      type = lib.types.str;
      example = "/var/lib/strata/pack/tokenizer";
      description = "The model's tokenizer folder (the `tokenizer` folder of the model's pack).";
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
      description = "Arguments for the engine: the model files and how to run them.";
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

  config = lib.mkIf cfg.enable {
    warnings =
      lib.optional (cfg.gpus == [ ] && cfg.cudaCapabilities == null && globalCaps == null) ''
        services.strata.gpus is not set, so the engine is compiled for every supported GPU
        generation (${lib.concatStringsSep ", " gpus.names}). Set it to your card, e.g.
        services.strata.gpus = [ "rtx-40" ]; to build much faster.
      ''
      ++ lib.optional (cfg.host != "127.0.0.1" && cfg.host != "::1" && cfg.apiKeyFile == null) ''
        services.strata listens on ${cfg.host} without services.strata.apiKeyFile: anyone who can
        reach port ${toString cfg.port} can use the model.
      '';

    networking.firewall.allowedTCPPorts = lib.mkIf cfg.openFirewall [ cfg.port ];

    systemd.services.strata = {
      description = "Strata MoE inference server";
      wantedBy = [ "multi-user.target" ];
      after = [ "network.target" ];

      environment = {
        STRATA_UPDATE_CHECK = "0";
        STRATA_STATE_DIR = "/var/lib/strata";
        HOME = "/var/lib/strata";
      };

      script = ''
        ${lib.optionalString (cfg.apiKeyFile != null) ''
          STRATA_API_KEY="$(< "$CREDENTIALS_DIRECTORY/api-key")"
          export STRATA_API_KEY
        ''}
        exec ${lib.getExe cfg.package} --engine strata --config ${serverConfig} \
          ${lib.escapeShellArgs (
            lib.optional (cfg.host != "127.0.0.1" && cfg.apiKeyFile == null) "--no-api-key" ++ cfg.extraFlags
          )}
      '';

      serviceConfig = {
        DynamicUser = true;
        SupplementaryGroups = [
          "video"
          "render"
        ];
        StateDirectory = "strata";
        WorkingDirectory = "/var/lib/strata";
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
        PrivateTmp = true;
      };
    };
  };
}
