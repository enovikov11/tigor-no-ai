{
  inputs = {
    # 2026-09-09 https://github.com/NixOS/nixpkgs/commits/nixos-26.05/
    nixpkgs.url = "github:NixOS/nixpkgs/6aefcda9401be8acc2b74244fb3b37520ea1f0a8";
  };

  outputs = { self, nixpkgs, ... }:
    let
      system = "x86_64-linux";
      pkgs = nixpkgs.legacyPackages.${system};

      cloudHvFirmware = pkgs.OVMF.override {
        projectDscPath = "OvmfPkg/CloudHv/CloudHvX64.dsc";
        fwPrefix = "CLOUDHV";
      };

      cloudHvFirmwarePath = cloudHvFirmware.mergedFirmware;
    in {
      devShells.${system}.default = pkgs.mkShell {
        env.CLOUDHV_FIRMWARE = cloudHvFirmwarePath;

        packages = [
          pkgs.cloud-hypervisor
        ];
      };
    };
}