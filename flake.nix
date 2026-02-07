{
  description = "zmx - session persistence for terminal processes";

  inputs = {
    utils.url = "https://flakehub.com/f/numtide/flake-utils/0.1.102";
    nixpkgs-master.url = "github:NixOS/nixpkgs/fa83fd837f3098e3e678e6cf017b2b36102c7211";
    nixpkgs.url = "github:NixOS/nixpkgs/54b154f971b71d260378b284789df6b272b49634";
    zig2nix.url = "github:Cloudef/zig2nix";
  };

  outputs =
    { zig2nix, nixpkgs, nixpkgs-master, utils, ... }:
    let
      flake-utils = zig2nix.inputs.flake-utils;
    in
    (flake-utils.lib.eachSystem [ "x86_64-linux" "aarch64-linux" ] (
      system:
      let
        env = zig2nix.outputs.zig-env.${system} {
          zig = zig2nix.outputs.packages.${system}.zig-0_15_2;
        };
        pkgs = env.pkgs;
      in
      with builtins;
      with pkgs.lib;
      let
        zmx-package = env.package {
          src = cleanSource ./.;
          zigBuildFlags = [ "-Doptimize=ReleaseSafe" ];
        };
        zmx-libvterm = env.package {
          src = cleanSource ./.;
          zigBuildFlags = [ "-Doptimize=ReleaseSafe" "-Dbackend=libvterm" ];
          buildInputs = [ pkgs.libvterm-neovim ];
          # Remove ghostty dependency from zon file - not needed for libvterm backend
          postPatch = ''
            sed -i '/.ghostty = .{/,/},/d' build.zig.zon
          '';
        };
      in
      {
        packages = {
          zmx = zmx-package;
          zmx-libvterm = zmx-libvterm;
          default = zmx-package;
        };

        apps = {
          zmx = {
            type = "app";
            program = "${zmx-package}/bin/zmx";
          };
          default = {
            type = "app";
            program = "${zmx-package}/bin/zmx";
          };

          build = env.app [ ] "zig build \"$@\"";

          test = env.app [ ] "zig build test -- \"$@\"";
        };

        devShells.default = env.mkShell {
          buildInputs = [ pkgs.libvterm-neovim ];
        };
      }
    ));
}
