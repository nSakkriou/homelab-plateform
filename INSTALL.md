# Guide d'installation — Homelab NixOS

Installation de NixOS depuis une clé USB sur une machine physique vierge,
suivie du déploiement complet du cluster k3s + ArgoCD + Gateway API.

---

## Prérequis

- Image ISO NixOS minimal : https://nixos.org/download (choisir "NixOS minimal ISO")
- Clé USB ≥ 2 Go
- Connexion internet sur le serveur
- Nom de domaine `nathansakkriou.com` pointant vers l'IP publique du serveur

---

## Phase 0 — Création de la clé USB bootable

Sur ton poste de travail :

```bash
# Linux
dd if=nixos-minimal-*.iso of=/dev/sdX bs=4M status=progress conv=fsync

# macOS
diskutil unmountDisk /dev/diskN
sudo dd if=nixos-minimal-*.iso of=/dev/rdiskN bs=4m
```

Démarrer le serveur sur la clé USB (F12 / F2 / DEL selon le BIOS).

---

## Phase 1 — Partitionnement et installation NixOS

Toutes les commandes suivantes sont exécutées **sur le serveur**, depuis la session live de la clé USB.

### 1.1 Identifier le disque cible

```bash
lsblk
# Repérer le disque principal, ex: /dev/nvme0n1 ou /dev/sda
DISK=/dev/nvme0n1   # à adapter
```

### 1.2 Partitionner (GPT + EFI + ext4)

```bash
parted $DISK -- mklabel gpt
parted $DISK -- mkpart ESP fat32 1MB 512MB
parted $DISK -- set 1 esp on
parted $DISK -- mkpart primary ext4 512MB 100%
```

### 1.3 Formater

```bash
mkfs.fat -F 32 -n boot ${DISK}p1
mkfs.ext4 -L nixos  ${DISK}p2
```

### 1.4 Monter les partitions

```bash
mount /dev/disk/by-label/nixos  /mnt
mkdir -p /mnt/boot
mount /dev/disk/by-label/boot   /mnt/boot
```

### 1.5 Générer la configuration hardware

```bash
nixos-generate-config --root /mnt
```

Cela crée `/mnt/etc/nixos/hardware-configuration.nix` — le fichier spécifique à cette machine.

### 1.6 Cloner ce dépôt sur la clé de configuration

```bash
nix-shell -p git

git clone https://github.com/nSakkriou/homelab-plateform /mnt/etc/nixos/homelab

# Copier le hardware-configuration.nix généré dans le repo
cp /mnt/etc/nixos/hardware-configuration.nix \
   /mnt/etc/nixos/homelab/infra/hardware-configuration.nix
```

### 1.7 Installer NixOS depuis le flake

```bash
nixos-install --flake /mnt/etc/nixos/homelab#k3s-node
```

Saisir le mot de passe root quand demandé (à usage unique pour le premier boot).

### 1.8 Reboot

```bash
reboot
```

Retirer la clé USB lors du redémarrage.

---

## Phase 2 — Premier boot et vérifications

Se connecter en SSH depuis ton poste de travail :

```bash
ssh admin@<IP_PUBLIQUE_SERVEUR>
```

Vérifier que k3s est opérationnel :

```bash
kubectl get nodes
# NAME        STATUS   ROLES                  AGE   VERSION
# k3s-node    Ready    control-plane,master   Xm    v1.x.x
```

Vérifier qu'ArgoCD est en cours d'installation :

```bash
kubectl get pods -n argocd
# Attendre que tous les pods soient Running (peut prendre 2-5 min)
```

Récupérer le mot de passe admin ArgoCD :

```bash
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath="{.data.password}" | base64 -d && echo
```

L'UI ArgoCD est accessible sur : **https://\<IP_SERVEUR\>:30443**
Login : `admin` / `<mot de passe ci-dessus>`

---

## Phase 3 — Committer hardware-configuration.nix dans le repo

Sur ton poste de travail, copier le fichier généré depuis le serveur :

```bash
ssh admin@<IP_SERVEUR> "cat /etc/nixos/homelab/infra/hardware-configuration.nix" \
  > infra/hardware-configuration.nix

git add infra/hardware-configuration.nix
git commit -m "feat: add hardware-configuration for k3s-node"
git push
```

---

## Phase 4 — Configurer kubectl en local

```bash
# Récupérer le kubeconfig du serveur et remplacer l'adresse
ssh admin@<IP_SERVEUR> "sudo cat /etc/rancher/k3s/k3s.yaml" \
  | sed "s/127.0.0.1/nathansakkriou.com/g" \
  > ~/.kube/homelab.yaml

# Tester
export KUBECONFIG=~/.kube/homelab.yaml
kubectl get nodes
```

Ajouter dans `~/.ssh/config` pour simplifier l'accès :

```
Host homelab
  HostName nathansakkriou.com
  User admin
  IdentityFile ~/.ssh/id_ed25519
```

---

## Phase 5 — Déploiement GitOps via ArgoCD

### 5.1 Appliquer l'App-of-Apps

```bash
# Depuis ton poste ou depuis le serveur
kubectl apply -f apps/app-of-apps.yaml
```

ArgoCD va détecter et déployer automatiquement dans cet ordre :
- **Wave 1** : cert-manager, envoy-gateway
- **Wave 2** : ClusterIssuers Let's Encrypt (staging + prod)
- **Wave 3** : GatewayClass, Gateway (`homelab-gateway`), Certificate TLS
- **Wave 4** : HTTPRoute ArgoCD (`argocd.nathansakkriou.com`)

Suivre la progression dans l'UI ArgoCD ou :

```bash
kubectl get applications -n argocd
kubectl get gateway -n gateway
kubectl get certificate -n gateway
```

### 5.2 Vérifier les certificats TLS

```bash
# Attendre que le certificat soit émis (Let's Encrypt peut prendre 1-2 min)
kubectl get certificate -n gateway
# NAME                 READY   SECRET               AGE
# nathansakkriou-tls   True    nathansakkriou-tls   Xm
```

### 5.3 Tester l'accès HTTPS à ArgoCD

```bash
curl -I https://argocd.nathansakkriou.com
# HTTP/2 200
```

---

## Phase 6 — Finaliser la configuration (fermer le port 30443)

Une fois ArgoCD accessible via `https://argocd.nathansakkriou.com`, fermer le port NodePort de bootstrap.

Modifier `infra/configuration.nix` — retirer `30443` des ports :

```nix
networking.firewall.allowedTCPPorts = [
  22
  80
  443
  6443
  # 30443 retiré
];
```

Modifier `infra/argocd.nix` — passer ArgoCD en ClusterIP :

```yaml
# Dans argocdValues, remplacer le contenu par :
server:
  service:
    type: ClusterIP
configs:
  params:
    server.insecure: "true"
```

Appliquer depuis ton poste de travail :

```bash
nixos-rebuild switch --flake .#k3s-node \
  --target-host admin@nathansakkriou.com \
  --use-remote-sudo
```

---

## Récapitulatif des commandes rapides

```bash
# Rebuild NixOS à distance
nixos-rebuild switch --flake .#k3s-node \
  --target-host admin@nathansakkriou.com \
  --use-remote-sudo

# Mot de passe ArgoCD
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath="{.data.password}" | base64 -d && echo

# Logs ArgoCD bootstrap
sudo journalctl -u argocd-bootstrap -f

# État du cluster
kubectl get nodes && kubectl get pods -A

# Certificats TLS
kubectl get certificates -A
kubectl get gateways -A
```

---

## Déployer une nouvelle application

1. Créer `apps/k8s/<mon-app>/` avec les manifests Kubernetes
2. Créer `apps/infrastructure/<mon-app>.yaml` (Application ArgoCD)
3. Ajouter l'HTTPRoute dans `apps/k8s/<mon-app>/httproute.yaml` :

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: mon-app
  namespace: mon-app
spec:
  parentRefs:
    - name: homelab-gateway
      namespace: gateway
      sectionName: https
  hostnames:
    - mon-app.nathansakkriou.com
  rules:
    - backendRefs:
        - name: mon-app-svc
          port: 8080
```

4. Ajouter le hostname dans `apps/k8s/envoy-gateway/certificate.yaml`
5. `git push` → ArgoCD détecte et déploie automatiquement
