{
  description = "Nix CycloneDX Software Bills of Materials (SBOMs)";

  inputs = {

    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

    flake-utils.url = "github:numtide/flake-utils";

    flake-compat = {
      url = "github:edolstra/flake-compat";
      flake = false;
    };

    flake-parts = {
      url = "github:hercules-ci/flake-parts";
      inputs.nixpkgs-lib.follows = "nixpkgs";
    };

    rust-overlay = {
      url = "github:oxalica/rust-overlay";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.flake-utils.follows = "flake-utils";
    };

    crane = {
      url = "github:ipetkov/crane";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    pre-commit-hooks-nix = {
      url = "github:cachix/pre-commit-hooks.nix";
      inputs = {
        nixpkgs.follows = "nixpkgs";
        flake-utils.follows = "flake-utils";
        flake-compat.follows = "flake-compat";
      };
    };

  };

  outputs = inputs@{ self, flake-parts, ... }: flake-parts.lib.mkFlake { inherit inputs; } (_:
    let
      # This is effectively just boilerplate to allow us to keep the `lib`
      # output.
      libOutputModule = { lib, ... }: flake-parts.lib.mkTransposedPerSystemModule {
        name = "lib";
        option = lib.mkOption {
          type = lib.types.lazyAttrsOf lib.types.anything;
          default = { };
        };
        file = "";
      };
    in
    {

      imports = [
        inputs.pre-commit-hooks-nix.flakeModule
        libOutputModule
      ];

      flake = {
        templates.default = {
          path = builtins.filterSource (path: type: baseNameOf path == "flake.nix")
            ./examples/flakes;
          description = "Build a Bom for GNU hello";
        };
      };

      systems = [
        "x86_64-linux"
        "aarch64-linux"

        "x86_64-darwin"
        "aarch64-darwin"
      ];

      perSystem = { config, system, ... }:
        let
          pkgs = import inputs.nixpkgs {
            inherit system;
            overlays = [ (import inputs.rust-overlay) ];
          };

          rustToolChain = pkgs.rust-bin.fromRustupToolchainFile ./transformer/rust-toolchain.toml;
          craneLib = inputs.crane.lib.${system}.overrideToolchain rustToolChain;

          # Include the Git commit hash as the version of bombon in generated Boms
          GIT_COMMIT = pkgs.lib.optionalString (self ? rev) self.rev;

          commonArgs = {
            src = craneLib.cleanCargoSource ./transformer;
            inherit GIT_COMMIT;
          };
          cargoArtifacts = craneLib.buildDepsOnly commonArgs;
          transformer = craneLib.buildPackage (commonArgs // { inherit cargoArtifacts; });

          buildBom = pkgs.callPackage ./build-bom.nix {
            inherit transformer;
            buildtimeDependencies = pkgs.callPackage ./buildtime-dependencies.nix { };
            runtimeDependencies = pkgs.callPackage ./runtime-dependencies.nix { };
          };
        in
        {

          lib = { inherit buildBom; };

          packages = {
            # This is mostly here for development
            inherit transformer;
            default = transformer;
          };

          checks = {
            clippy = craneLib.cargoClippy (commonArgs // { inherit cargoArtifacts; });
            rustfmt = craneLib.cargoFmt (commonArgs // { inherit cargoArtifacts; });
          } // import ./tests { inherit pkgs buildBom; };

          pre-commit = {
            check.enable = true;

            settings = {
              hooks = {
                nixpkgs-fmt.enable = true;
                typos.enable = true;
              };

              settings.statix.ignore = [ "sources.nix" ];
            };

          };

          devShells.default = pkgs.mkShell {
            shellHook = ''
              ${config.pre-commit.installationScript}
            '';

            inputsFrom = [ transformer ];

            inherit GIT_COMMIT;
          };

        };
    });
}
