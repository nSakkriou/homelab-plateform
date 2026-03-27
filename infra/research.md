# Analyse des fichiers de configuration NixOS — homelab-plateform

## Structure du projet

```
homelab-plateform/
├── README.md
├── age.key                        (clé de chiffrement age — probablement pour sops-nix)
├── infra/
│   ├── configuration.nix          (module principal — 106 lignes)
│   ├── argocd.nix                 (module bootstrap ArgoCD — 55 lignes)
│   └── hardware-configuration.nix ⚠️ ABSENT (importé mais inexistant)
└── apps/                          (vide)
```

---

## Graphe d'imports

```
configuration.nix  (point d'entrée)
├── hardware-configuration.nix  ← ⚠️ ABSENT
└── argocd.nix
    ├── dépend de : pkgs (kubectl, kubernetes-helm)
    └── dépend de : services.k3s (prérequis runtime)
```

---

## configuration.nix — Analyse détaillée

### Identité du système

| Paramètre | Valeur |
|-----------|--------|
| `system.stateVersion` | `"24.11"` (NixOS 24.11 stable) |
| `networking.hostName` | `"k3s-node"` |
| `time.timeZone` | `"Europe/Paris"` |

### Boot

```
bootLoader : systemd-boot (UEFI)
canTouchEfiVariables : true
```

### Localisation

```
i18n.defaultLocale    = "fr_FR.UTF-8"
LC_TIME               = "fr_FR.UTF-8"
LC_NUMERIC            = "fr_FR.UTF-8"
LC_MONETARY           = "fr_FR.UTF-8"
console.keyMap        = "fr"
xserver.xkb.layout    = "fr"
```

### Kernel — modules et paramètres réseau

```nix
boot.kernelModules = [ "br_netfilter" ];

boot.kernel.sysctl = {
  "net.bridge.bridge-nf-call-iptables" = 1;
  "net.ipv4.ip_forward"               = 1;
};
```

Requis par k3s pour le routage des pods via bridges Linux.

### Réseau — Firewall

Ports TCP autorisés en entrée :

| Port | Usage |
|------|-------|
| 22   | SSH |
| 80   | HTTP |
| 443  | HTTPS |
| 6443 | API Kubernetes (k3s) |

> Note : le port 30443 (ArgoCD NodePort) n'est **pas** ouvert dans le firewall — accès uniquement depuis la machine ou via tunnel.

### k3s

```nix
services.k3s = {
  enable = true;
  role   = "server";
  extraFlags = toString [
    "--disable=traefik"
    "--tls-san=k3s-node"
    "--tls-san=127.0.0.1"
  ];
};
```

- Mode serveur mono-nœud (control plane + worker sur la même machine)
- Traefik désactivé (remplacé par une stack gérée via ArgoCD)
- SAN TLS fixés à `k3s-node` et `127.0.0.1` — à étendre si l'on accède via IP publique

### Variable d'environnement système

```nix
environment.variables.KUBECONFIG = "/etc/rancher/k3s/k3s.yaml";
```

Disponible pour tous les utilisateurs.

### Paquets système

```nix
environment.systemPackages = with pkgs; [
  kubectl
  kubernetes-helm
  k9s
  jq
  vim
];
```

### SSH

```nix
services.openssh = {
  enable                  = true;
  settings.PermitRootLogin         = "no";
  settings.PasswordAuthentication  = false;
};
```

Authentification par clé uniquement — SSH root désactivé.

### Utilisateur

```nix
users.users.admin = {
  isNormalUser = true;
  extraGroups  = [ "wheel" "networkmanager" ];
  openssh.authorizedKeys.keys = [
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIM26qaW2Liul3zUiIS6AKUvyr4D6AeZ85JONUnMZbub9 nsakkriou@WX-OR6435545"
  ];
};
```

Un seul utilisateur `admin`, clé ED25519 de la machine `WX-OR6435545` (poste de travail de l'auteur).

### Nix Flakes

```nix
nix.settings.experimental-features = [ "nix-command" "flakes" ];
```

Activés, mais aucun `flake.nix` n'est présent dans le dépôt — le projet utilise la configuration classique (`nixos-rebuild switch -I`).

---

## argocd.nix — Analyse détaillée

### Service systemd : `argocd-bootstrap`

```
Type        : oneshot
RemainAfterExit : true
Restart     : on-failure
RestartSec  : 30s
After/Requires  : k3s.service
WantedBy    : multi-user.target
```

Ce service s'exécute une seule fois au démarrage, après k3s, et reste marqué "actif" une fois terminé.

### Phase de pré-démarrage (ExecStartPre)

```bash
until kubectl get nodes 2>/dev/null | grep -q " Ready"; do sleep 5; done
```

Boucle d'attente : poll toutes les 5 secondes jusqu'à ce que k3s signale le nœud comme `Ready`.

### Phase d'exécution (ExecStart)

```bash
# 1. Ajout du repo Helm ArgoCD
helm repo add argo https://argoproj.github.io/argo-helm 2>/dev/null || true

# 2. Mise à jour des repos
helm repo update

# 3. Installation / mise à jour d'ArgoCD
helm upgrade --install argocd argo/argo-cd \
  --namespace argocd \
  --create-namespace \
  --version 2.13.3 \
  --set server.service.type=NodePort \
  --set server.service.nodePortHttps=30443 \
  --wait \
  --timeout 10m
```

| Paramètre Helm | Valeur |
|----------------|--------|
| Chart | `argo/argo-cd` |
| Version | `2.13.3` (fixée) |
| Namespace | `argocd` (créé automatiquement) |
| Service type | `NodePort` |
| Port HTTPS | `30443` |
| Timeout install | 10 minutes |

### Ordre d'exécution au boot

```
1. Kernel (br_netfilter chargé)
2. Réseau + firewall (ports 22/80/443/6443 ouverts)
3. k3s démarre sur le port 6443
4. argocd-bootstrap attend k3s.service
5. ExecStartPre : poll kubectl jusqu'à "Ready"
6. Helm repo add + update
7. Helm install ArgoCD (NodePort 30443)
8. UI disponible sur https://<IP>:30443
```

### Récupération du mot de passe admin post-install

```bash
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath="{.data.password}" | base64 -d && echo
```

---

## Fichier manquant : hardware-configuration.nix

Ce fichier est importé à la ligne 5 de `configuration.nix` mais **n'existe pas** dans le dépôt.

```nix
imports = [
  ./hardware-configuration.nix  # ← manquant
  ./argocd.nix
];
```

**Conséquence** : un `nixos-rebuild switch` échouera tel quel.

Ce fichier doit être généré sur la machine cible :

```bash
nixos-generate-config --show-hardware-config > /etc/nixos/hardware-configuration.nix
```

Il contient typiquement : filesystems, UUID des partitions, drivers CPU/GPU, modules kernel spécifiques au matériel.

---

## Fichier age.key

Présent à la racine du dépôt. Son usage n'est pas encore référencé dans les fichiers Nix, mais la présence de cette clé suggère une préparation pour [sops-nix](https://github.com/Mic92/sops-nix) — gestionnaire de secrets chiffrés pour NixOS.

---

## Récapitulatif global

| Aspect | Valeur |
|--------|--------|
| Distribution | NixOS 24.11 |
| Bootloader | systemd-boot (EFI) |
| Nœud Kubernetes | k3s mono-nœud (server + worker) |
| GitOps | ArgoCD 2.13.3 via Helm |
| Ports firewall | 22, 80, 443, 6443 |
| ArgoCD UI | `https://<IP>:30443` (NodePort, hors firewall) |
| Auth SSH | Clé ED25519 uniquement, root désactivé |
| Utilisateur | `admin` (wheel) |
| Langue / TZ | fr_FR.UTF-8 / Europe/Paris |
| Flakes | Activés (pas de flake.nix) |
| Secrets | age.key présent, sops-nix non configuré |
| Fichier manquant | `hardware-configuration.nix` |

---

## Points d'attention

1. **`hardware-configuration.nix` absent** — le système ne peut pas être rebuild sans ce fichier.
2. **Port 30443 non ouvert** dans le firewall — ArgoCD n'est pas accessible depuis l'extérieur. À ajouter si l'accès distant est souhaité.
3. **SANs TLS k3s limités** (`k3s-node`, `127.0.0.1`) — si l'IP publique ou un DNS est utilisé, il faut ajouter les `--tls-san` correspondants.
4. **Version Helm chart ArgoCD fixée** à `2.13.3` — à mettre à jour manuellement lors des montées de version.
5. **Pas de flake.nix** malgré les Flakes activés — la reproductibilité complète n'est pas garantie sans lock file.
6. **age.key en clair dans le dépôt** — cette clé ne devrait pas être committée, surtout si le dépôt est public.
