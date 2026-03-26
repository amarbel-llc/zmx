{
  description = "zmx - session persistence for terminal processes";

  inputs = {
    utils.url = "https://flakehub.com/f/numtide/flake-utils/0.1.102";
    nixpkgs-master.url = "github:NixOS/nixpkgs/e2dde111aea2c0699531dc616112a96cd55ab8b5";
    nixpkgs.url = "github:NixOS/nixpkgs/3e20095fe3c6cbb1ddcef89b26969a69a1570776";
  };

  outputs =
    {
      nixpkgs,
      nixpkgs-master,
      utils,
      ...
    }:
    (utils.lib.eachSystem
      [
        "x86_64-linux"
        "aarch64-linux"
        "aarch64-darwin"
        "x86_64-darwin"
      ]
      (
        system:
        let
          pkgs = import nixpkgs { inherit system; };
        in
        {
          packages = {
            zmx-libvterm = pkgs.callPackage ./package.nix { useLibvterm = true; };
            default = pkgs.callPackage ./package.nix { useLibvterm = true; };
          };

          devShells.default = pkgs.mkShell {
            buildInputs = [
              pkgs.just
              pkgs.zig_0_15
              pkgs.libvterm-neovim
            ];
          };
        }
      )
    );
}
