{
  description = "A tool to convert binary OpenWrt packages from old IPK to new APK v2 format";

  inputs = {
    nixpkgs-stable.url = "https://flakehub.com/f/NixOS/nixpkgs/0.2511.tar.gz";
    nixpkgs.follows = "nixpkgs-stable";
  };

  outputs = { self, nixpkgs, ... }:
    let
      supportedSystems = nixpkgs.lib.systems.flakeExposed;
      forAllSystems = nixpkgs.lib.genAttrs supportedSystems;
    in
    {
      packages = forAllSystems (system:
        let
          lib = nixpkgs.lib;
          pkgs = nixpkgs.legacyPackages.${system};
        in
        {
          default = pkgs.stdenv.mkDerivation {
            pname = "openwrt-ipk2apk";
            version = "1.0.0";

            src = ./openwrt-ipk2apk.py;

            buildInputs = [ pkgs.python3 ];

            dontUnpack = true;

            installPhase = ''
              runHook preInstall
              install -Dm755 $src $out/bin/openwrt-ipk2apk
              runHook postInstall
            '';

            meta = with pkgs.lib; {
              description = "Convert OpenWrt IPK packages to strict APK v2 format";
              license = licenses.mit;
              mainProgram = "openwrt-ipk2apk";
            };
          };
        }
      );

      apps = forAllSystems (system:
        let
          lib = nixpkgs.lib;
          packages' = self.packages.${system};
        in
        {
          default = {
            type = "app";
            program = lib.meta.getExe packages'.default;
          };
        });

      formatter = forAllSystems (system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
        in
        pkgs.writeShellApplication {
          name = "repo-formatter";
          runtimeInputs = with pkgs; [
            nixpkgs-fmt
            black
            mdformat
          ];
          text = ''
            set -x
            nixpkgs-fmt .
            black .
            mdformat .
          '';
        });

    };
}
