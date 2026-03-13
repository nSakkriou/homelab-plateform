{ config, pkgs, ... }:

{
  imports = [
    ./argocd.nix
  ];

  system.stateVersion = "24.11";

  # --- Réseau ----------------------------------------------------------------
  # On ouvre uniquement les ports nécessaires à Kubernetes et au trafic web.

  networking = {
    hostName = "k3s-node";
    firewall = {
      enable = true;
      allowedTCPPorts = [
        6443  # API Kubernetes
        80    # HTTP
        443   # HTTPS
      ];
    };
  };

  # --- Paramètres noyau requis par k3s ---------------------------------------
  # Sans ça, le réseau inter-pods ne fonctionne pas.

  boot.kernel.sysctl = {
    "net.bridge.bridge-nf-call-iptables" = 1;
    "net.ipv4.ip_forward"                = 1;
  };
  boot.kernelModules = [ "br_netfilter" ];

  # --- k3s -------------------------------------------------------------------
  # Mode serveur mono-nœud. On désactive Traefik pour le gérer via ArgoCD.

  services.k3s = {
    enable = true;
    role   = "server";
    extraFlags = builtins.concatStringsSep " " [
      "--disable=traefik"
      "--tls-san=k3s-node"       # Ajouter ici votre IP publique ou DNS
      "--tls-san=127.0.0.1"
    ];
  };

  # --- Kubeconfig accessible facilement --------------------------------------

  environment.etc."profile.d/k3s.sh".text = ''
    export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
  '';

  # --- Paquets utiles --------------------------------------------------------

  environment.systemPackages = with pkgs; [
    kubectl
    kubernetes-helm
    k9s
    jq
    vim
  ];

  # --- SSH (clé uniquement) --------------------------------------------------

  services.openssh = {
    enable = true;
    settings = {
      PermitRootLogin        = "no";
      PasswordAuthentication = false;
    };
  };

  users.users.admin = {
    isNormalUser = true;
    extraGroups  = [ "wheel" ];
    openssh.authorizedKeys.keys = [
      # Remplacer par votre clé SSH publique :
      # "ssh-ed25519 AAAA... admin@pc"
    ];
  };

  # --- Nix : activer les flakes ----------------------------------------------

  nix.settings.experimental-features = [ "nix-command" "flakes" ];
}
