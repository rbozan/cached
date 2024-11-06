{
  description = "yt-subtitles-db";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-23.11";

    crane = {
      url = "github:ipetkov/crane";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    rust-overlay.url = "github:oxalica/rust-overlay";

    flake-utils.url = "github:numtide/flake-utils";

  };

  outputs = { self, nixpkgs, crane, flake-utils, rust-overlay }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = import nixpkgs {
          inherit system;
          overlays = [ (import rust-overlay) ];
        };

        rustPkg = pkgs.rust-bin.stable.latest;
        rustMinimalToolchain = rustPkg.minimal;
        rustDefaultToolchain = rustPkg.default;

        craneLib = crane.lib.${system}.overrideToolchain rustMinimalToolchain;

        my-crate = craneLib.buildPackage {
          src = ./.;

          cargoExtraArgs = "--features=tracing_journald,opentelemetry";

          OPENSSL_DIR = "${pkgs.openssl.dev}";
          OPENSSL_LIB_DIR = "${pkgs.openssl.out}/lib";

          VERGEN_GIT_DESCRIBE = if self ? rev then self.rev else "dirty";

          doCheck = false;
          # nativeBuildInputs = with pkgs; [ git ];

        };

        rust-nightly =
          pkgs.rust-bin.nightly."2024-02-04".default; #selectLatestNightlyWith (toolchain: toolchain.default);
      in
      {
        checks = {
          inherit my-crate;
        };

        packages.default = my-crate;

        apps.default = flake-utils.lib.mkApp {
          drv = my-crate;
        };

        devShells.default = pkgs.mkShell {
          inputsFrom = builtins.attrValues self.checks;

          # CONFIG_FILE = pkgs.writeText "config_file" (builtins.toJSON config_data);

          nativeBuildInputs = with pkgs; [
            # Development
            cargo-watch
            cargo-insta
            rustDefaultToolchain
          ];
        };

        # Wrap `cargo-udeps` to ensure it uses a nightly Rust version.
        apps.udeps = flake-utils.lib.mkApp {
          drv = pkgs.writeShellScriptBin "cargo-udeps" ''
            export RUSTC="${rust-nightly}/bin/rustc";
            export CARGO="${rust-nightly}/bin/cargo";

            ${pkgs.cargo-udeps}/bin/cargo-udeps udeps --all-targets
          '';
        };

        # Module

        nixosModules.default = { config, lib, ... }:
          with lib;
          let
            cfg = config.services.yt-subtitles-db;
            system = config.nixpkgs.system;
            service_config = {
              RUST_LOG = "info,tower_http=debug";
              http_port = 3002;

              database_url = "postgres://postgres:K864LiAuEWsDBZVzu5ioGhz7QMq3YVW7hiwFCwTHH6S7vNai@127.0.0.1:5432/postgres";

              meilisearch_url = "https://search.learnfeliz.com";
              meilisearch_api_key = "4a7a3942e0b6b23c2cab8972270c13ce4b972ecccd03d0136494baa82beab908";
            };
          in
          {
            options = {
              services.yt-subtitles-db = {
                enable = mkEnableOption "Enables the yt-subtitles-db";

                environment = mkOption rec {
                  type = types.anything;
                  default = {
                    CONFIG_FILE = pkgs.writeText "config_file" (builtins.toJSON service_config);
                  };
                  example = default;
                  description = "The config file";
                };
              };
            };

            config = mkIf cfg.enable {
              # services.postgresql = {
              #   enable = true;
              # };

              services.rabbitmq = {
                enable = true;
              };

              networking.firewall.allowedTCPPorts = [ service_config.HTTP_PORT ];

              systemd.services."yt-subtitles-db" = with builtins; {
                description = "yt-subtitles-db, repo: https://gitlab.com/l4010/game-group/yt-subtitles-db";
                wantedBy = [ "multi-user.target" ];
                after = [ "network.target" ];
                environment = cfg.environment;
                serviceConfig =
                  let pkg = self.packages.${system}.default;
                  in
                  {
                    RestartSec = 3;
                    Restart = "always";
                    RuntimeMaxSec = "90m"; # Workaround for now
                    ExecStart = "${pkg}/bin/yt-subtitles-db";
                    DynamicUser = "yes";

                    AmbientCapabilities = "cap_net_bind_service";
                    CapabilityBoundingSet = "cap_net_bind_service";
                  };
              };
            };
          };

      });
}
