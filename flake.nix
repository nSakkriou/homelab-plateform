{
  description = "Homelab NixOS — k3s + ArgoCD + Gateway API";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.11";

    sops-nix = {
      url = "github:Mic92/sops-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, sops-nix, ... }: {
    nixosConfigurations.k3s-node = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      modules = [
        ./infra/configuration.nix
        sops-nix.nixosModules.sops
      ];
    };
  };
}
