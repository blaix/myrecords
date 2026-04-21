{
  description = "MyRecords - A vinyl record collection manager";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    ws4sql.url = "github:blaix/ws4sql-nix";
    process-compose-flake.url = "github:Platonic-Systems/process-compose-flake";
  };

  outputs = { self, nixpkgs, ws4sql, process-compose-flake }:
    let
      # Support both Mac (development) and Linux (production)
      supportedSystems = [ "x86_64-linux" "aarch64-linux" "aarch64-darwin" ];

      forAllSystems = nixpkgs.lib.genAttrs supportedSystems;

      pkgsFor = system: nixpkgs.legacyPackages.${system};

      mkMyrecordsPackage = system:
        let
          pkgs = pkgsFor system;
          gren = pkgs.gren;
        in
        pkgs.stdenv.mkDerivation {
          pname = "myrecords";
          version = "0.0.1";
          src = ./.;

          buildInputs = [
            gren
            pkgs.nodejs
          ];

          buildPhase = ''
            ${gren}/bin/gren make Main
          '';

          installPhase = ''
            mkdir -p $out/share/myrecords/public
            cp app $out/share/myrecords/
            if [ -n "$(ls -A public 2>/dev/null)" ]; then
              cp -r public/. $out/share/myrecords/public/
            fi

            # Create wrapper script
            mkdir -p $out/bin
            cat > $out/bin/myrecords <<EOF
#!/bin/sh
cd $out/share/myrecords
exec ${pkgs.nodejs}/bin/node app "\$@"
EOF
            chmod +x $out/bin/myrecords
          '';
        };
    in
    {
      # Packages for all systems
      packages = forAllSystems (system: {
        myrecords = mkMyrecordsPackage system;
        ws4sql = ws4sql.packages.${system}.default;
        default = mkMyrecordsPackage system;
      });

      # Development services (process-compose-flake) for all systems
      process-compose = forAllSystems (system:
        let
          pkgs = pkgsFor system;
          myrecords-package = mkMyrecordsPackage system;
        in
        {
          dev.settings.processes = {
            db = {
              command = ''
                mkdir -p ./data
                echo "Database: ./data/myrecords.db"
                ${ws4sql.packages.${system}.default}/bin/ws4sql --quick-db ./data/myrecords.db
              '';
              ready_log_line = "Web Service listening"; # Output that means service is ready.
            };

            server = {
              command = ''
                echo "App deployed at: ${myrecords-package}/share/myrecords"
                ${pkgs.nodejs}/bin/node ${myrecords-package}/share/myrecords/app
              '';
              working_dir = "${myrecords-package}/share/myrecords";
              depends_on.db.condition = "process_log_ready"; # Waits for output from ready_log_line above.
            };
          };
        }
      );

      # Development shell for all systems
      devShells = forAllSystems (system:
        let
          pkgs = pkgsFor system;
        in
        {
          default = pkgs.mkShell {
            buildInputs = [
              pkgs.gren
              pkgs.nodejs
              pkgs.fd
              ws4sql.packages.${system}.default
            ];

            shellHook = ''
              echo ""
              echo "=================================================="
              echo "Welcome to the myrecords development environment."
              echo "Run 'nix run .#dev' to start services."
              echo "Run 'nix build .#myrecords' to build the package."
              echo "=================================================="
            '';
          };
        }
      );

      # Apps for running development services
      apps = forAllSystems (system:
        let
          pkgs = pkgsFor system;
          # Convert process-compose config to YAML
          processComposeConfig = pkgs.writeText "process-compose.yaml"
            (builtins.toJSON self.process-compose.${system}.dev.settings);
          startScript = pkgs.writeShellScript "start-dev" ''
            # If running in a terminal, use TUI mode, otherwise use log mode
            if [ -t 0 ]; then
              exec ${pkgs.process-compose}/bin/process-compose up -f ${processComposeConfig} --keep-project
            else
              exec ${pkgs.process-compose}/bin/process-compose up -f ${processComposeConfig} --tui=false
            fi
          '';
        in
        {
          dev = {
            type = "app";
            program = "${startScript}";
          };
        }
      );

      # Production NixOS module (Linux only)
      nixosModules.myrecords = { config, lib, pkgs, ... }:
        with lib;
        let
          cfg = config.services.myrecords;
          # Use x86_64-linux for the production module
          system = "x86_64-linux";
          myrecords-package = mkMyrecordsPackage system;
        in
        {
          options.services.myrecords = {
            enable = mkEnableOption "Enable myrecords app service";

            domain = mkOption {
              type = types.str;
              description = "Domain name for the application";
            };

            acmeEmail = mkOption {
              type = types.str;
              description = "Email address for ACME/Let's Encrypt";
            };

            enableBackups = mkOption {
              type = types.bool;
              default = true;
              description = "Enable automatic daily backups";
            };

            dataDir = mkOption {
              type = types.path;
              default = "/var/lib/myrecords";
              description = "Directory for application data";
            };

            appPort = mkOption {
              type = types.int;
              default = 3000;
              description = "Port for the Node.js application";
            };

            ws4sqlPort = mkOption {
              type = types.int;
              default = 12321;
              description = "Port for the ws4sql database server";
            };

            basicAuth = {
              enable = mkEnableOption "Enable HTTP Basic authentication";

              htpasswdFile = mkOption {
                type = types.path;
                default = "/etc/htpasswd";
                description = "Path to htpasswd file for HTTP Basic auth";
              };
            };
          };

          config = mkIf cfg.enable {
            # ws4sql database service
            systemd.services.ws4sql-myrecords = {
              description = "ws4sql database server for myrecords";
              wantedBy = [ "multi-user.target" ];

              serviceConfig = {
                ExecStartPre = "${pkgs.coreutils}/bin/echo 'Database: ${cfg.dataDir}/myrecords.db'";
                ExecStart = "${ws4sql.packages.${system}.default}/bin/ws4sql -port ${toString cfg.ws4sqlPort} --quick-db ${cfg.dataDir}/myrecords.db";
                DynamicUser = true;
                StateDirectory = "myrecords";
                Restart = "always";
                RestartSec = "5s";
              };
            };

            # myrecords application service
            systemd.services.myrecords = {
              description = "MyRecords application";
              wantedBy = [ "multi-user.target" ];
              after = [ "ws4sql-myrecords.service" "network-online.target" ];
              wants = [ "network-online.target" ];
              requires = [ "ws4sql-myrecords.service" ];

              serviceConfig = {
                ExecStartPre = "${pkgs.coreutils}/bin/echo 'App deployed at: ${myrecords-package}/share/myrecords'";
                ExecStart = "${pkgs.nodejs}/bin/node ${myrecords-package}/share/myrecords/app --port ${toString cfg.appPort} --ws4sql-port ${toString cfg.ws4sqlPort}";
                WorkingDirectory = "${myrecords-package}/share/myrecords";
                DynamicUser = true;
                User = "myrecords";
                Restart = "always";
                RestartSec = "5s";
              };
            };

            # Optional backup service
            systemd.services.myrecords-backup = mkIf cfg.enableBackups {
              description = "Backup myrecords database";
              serviceConfig = {
                Type = "oneshot";
                ExecStart = pkgs.writeShellScript "myrecords-backup" ''
                  mkdir -p ${cfg.dataDir}/backups
                  ${pkgs.sqlite}/bin/sqlite3 ${cfg.dataDir}/myrecords.db ".backup ${cfg.dataDir}/backups/myrecords-$(date +%Y%m%d-%H%M%S).db"
                  find ${cfg.dataDir}/backups -name "myrecords-*.db" -mtime +60 -delete
                '';
                User = "myrecords";
                DynamicUser = true;
                StateDirectory = "myrecords";
              };
            };

            systemd.timers.myrecords-backup = mkIf cfg.enableBackups {
              description = "Backup timer for myrecords (daily)";
              wantedBy = [ "timers.target" ];
              timerConfig = {
                OnCalendar = "daily";
                Persistent = true;
              };
            };

            # Nginx reverse proxy
            services.nginx = {
              enable = true;
              recommendedProxySettings = true;
              recommendedTlsSettings = true;
              recommendedOptimisation = true;
              recommendedGzipSettings = true;

              virtualHosts.${cfg.domain} = {
                enableACME = true;
                forceSSL = true;
                http2 = false;  # Disable HTTP/2 to enable WebSocket upgrades

                locations."/" = {
                  proxyPass = "http://127.0.0.1:${toString cfg.appPort}";
                  proxyWebsockets = true;
                } // lib.optionalAttrs cfg.basicAuth.enable {
                  basicAuthFile = cfg.basicAuth.htpasswdFile;
                };
              };
            };

            # ACME configuration
            security.acme = {
              acceptTerms = true;
              defaults.email = cfg.acmeEmail;
            };
          };
        };

      nixosModules.default = self.nixosModules.myrecords;
    };
}
