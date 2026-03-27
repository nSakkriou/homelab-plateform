{ config, pkgs, ... }:

{
  imports = [
    ./hardware-configuration.nix
    ./argocd.nix
  ];

  system.stateVersion = "24.11";

  # ---------------------------------------------------------------------------
  # Boot
  # ---------------------------------------------------------------------------

  boot.loader.systemd-boot.enable      = true;
  boot.loader.efi.canTouchEfiVariables = true;

  # Modules et paramètres noyau requis par k3s (routage inter-pods via bridges)
  boot.kernelModules   = [ "br_netfilter" ];
  boot.kernel.sysctl   = {
    "net.bridge.bridge-nf-call-iptables" = 1;
    "net.ipv4.ip_forward"                = 1;
  };

  # ---------------------------------------------------------------------------
  # Localisation
  # ---------------------------------------------------------------------------

  time.timeZone = "Europe/Paris";

  i18n.defaultLocale      = "fr_FR.UTF-8";
  i18n.extraLocaleSettings = {
    LC_TIME     = "fr_FR.UTF-8";
    LC_NUMERIC  = "fr_FR.UTF-8";
    LC_MONETARY = "fr_FR.UTF-8";
  };

  console.keyMap       = "fr";
  services.xserver.xkb = { layout = "fr"; };

  # ---------------------------------------------------------------------------
  # Réseau
  # ---------------------------------------------------------------------------

  networking = {
    hostName = "k3s-node";
    firewall = {
      enable           = true;
      allowedTCPPorts  = [
        22    # SSH
        80    # HTTP  (Gateway API — Envoy)
        443   # HTTPS (Gateway API — Envoy)
        6443  # API Kubernetes (kubectl distant)
        30443 # ArgoCD NodePort — bootstrap uniquement, à retirer après Phase 3
      ];
    };
  };

  # ---------------------------------------------------------------------------
  # k3s
  # ---------------------------------------------------------------------------

  services.k3s = {
    enable = true;
    role   = "server";
    extraFlags = builtins.concatStringsSep " " [
      "--disable=traefik"
      "--tls-san=k3s-node"
      "--tls-san=127.0.0.1"
      "--tls-san=nathansakkriou.com"
    ];
  };

  # ---------------------------------------------------------------------------
  # Secrets — sops-nix
  # La clé age doit être présente sur le serveur dans /var/lib/sops-nix/key.txt
  # (jamais dans Git — déjà dans .gitignore).
  # Décommenter et populer secrets/secrets.yaml quand des secrets sont nécessaires.
  # ---------------------------------------------------------------------------

  # sops = {
  #   defaultSopsFile = ./secrets/secrets.yaml;
  #   age.keyFile     = "/var/lib/sops-nix/key.txt";
  #   secrets."mon_secret" = {};
  # };

  # ---------------------------------------------------------------------------
  # SSH
  # ---------------------------------------------------------------------------

  services.openssh = {
    enable = true;
    settings = {
      PermitRootLogin              = "no";
      PasswordAuthentication       = false;
      KbdInteractiveAuthentication = false;
      Ciphers      = [ "chacha20-poly1305@openssh.com" "aes256-gcm@openssh.com" ];
      Macs         = [ "hmac-sha2-512-etm@openssh.com" "hmac-sha2-256-etm@openssh.com" ];
      KexAlgorithms = [ "curve25519-sha256" "curve25519-sha256@libssh.org" ];
    };
  };

  # ---------------------------------------------------------------------------
  # Protection brute-force SSH
  # ---------------------------------------------------------------------------

  services.fail2ban = {
    enable   = true;
    maxretry = 5;
    bantime  = "1h";
    bantime-increment = {
      enable       = true;
      multipliers  = "1 2 4 8 16 32 64";
      maxtime      = "168h";
      overalljails = true;
    };
  };

  # ---------------------------------------------------------------------------
  # Utilisateurs
  # ---------------------------------------------------------------------------

  users.users.admin = {
    isNormalUser = true;
    extraGroups  = [ "wheel" "networkmanager" ];
    openssh.authorizedKeys.keys = [
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIM26qaW2Liul3zUiIS6AKUvyr4D6AeZ85JONUnMZbub9 nsakkriou@WX-OR6435545"
    ];
  };

  # KUBECONFIG disponible pour les sessions interactives de l'utilisateur admin uniquement
  environment.etc."profile.d/k3s.sh".text = ''
    if [ "$(whoami)" = "admin" ]; then
      export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
    fi
  '';

  # ---------------------------------------------------------------------------
  # Paquets système
  # ---------------------------------------------------------------------------

  environment.systemPackages = with pkgs; [
    kubectl
    kubernetes-helm
    k9s
    jq
    vim
    git
  ];

  # ---------------------------------------------------------------------------
  # Nix
  # ---------------------------------------------------------------------------

  nix.settings.experimental-features = [ "nix-command" "flakes" ];
}
