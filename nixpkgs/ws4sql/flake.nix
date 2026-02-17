{
  description = "ws4sql - SQL over HTTP server for SQLite and DuckDB";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = nixpkgs.legacyPackages.${system};

        ws4sql = pkgs.buildGoModule {
          pname = "ws4sql";
          version = "v0.17dev7";

          src = pkgs.fetchFromGitHub {
            owner = "proofrock";
            repo = "ws4sqlite";
            rev = "63e6b6a667450455d393e19018d186d4a02e39e1";
            hash = "sha256-y/RMRt8VdWeNkBVP9gYNAGvwBaRItfOdPRMcq+TmZcw=";
          };

          # Source code is in src/ subdirectory
          sourceRoot = "source/src";

          # Go module path
          modRoot = ".";

          vendorHash = "sha256-L3ygTaTv9B0oPmb5cpvkRdO69Cbk834/4/caogGsj2s=";

          # Skip tests - they fail in the build environment
          doCheck = false;

          meta = with pkgs.lib; {
            description = "SQL over HTTP server for SQLite and DuckDB";
            homepage = "https://github.com/proofrock/ws4sqlite";
            license = licenses.isc;
            maintainers = [ ];
          };
        };
      in
      {
        packages = {
          ws4sql = ws4sql;
          default = ws4sql;
        };
      }
    );
}
