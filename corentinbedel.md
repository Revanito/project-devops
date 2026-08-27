# Project-DevOps
Groupe Maël NOUVEL, Corentin Bédel et Nicolas Bonnifet

Documentation : Assistée par Claude Sonnet 5 - Effort medium (et pas gpt-4o-mini, on a les moyens ici!)

## 1) Architecture de l'application

- `frontend/Dockerfile` : build multi-stage — `node:18-alpine` compile l'app Angular en mode production (`ng build`), puis l'artefact statique est servi par `nginx:alpine`.

- `frontend/nginx.conf` : configuration nginx minimale avec fallback SPA (`try_files ... /index.html`) pour que le routing Angular fonctionne.

- L'URL de l'API backend (`apiUrl`) est injectée au moment du build CI dans `environment.prod.ts` avec la valeur `/api`, en s'appuyant sur l'Ingress AKS pour router `/api/*` vers le service backend (reverse proxy). Pas besoin de reconstruire l'image pour changer d'environnement côté Ingress.

### 1.5) Backend (Node/Express)

- `backend/Dockerfile` : image simple `node:18-alpine`, dépendances installées en mode production (`npm ci --omit=dev`), exécution via `node src/server.js`, port `3000` exposé.

- La configuration (connexion MySQL, port) reste entièrement pilotée par variables d'environnement (`DB_HOST`, `DB_USER`, `DB_PASSWORD`, `DB_NAME`, `DB_DIALECT`, `PORT`), injectées via ConfigMap/Secret Kubernetes en production.

## 2) Choix techniques

### 2.5) Validation locale

- Les deux images ont été testées sur une LXC Proxmox dédiée (Docker installé nativement dans le conteneur, nécessitant l'activation des features `nesting` et `keyctl`, plus un profil AppArmor `unconfined` au niveau de l'hôte Proxmox).

- Test end-to-end réalisé manuellement : conteneur MySQL + conteneur backend + conteneur frontend sur un même réseau Docker, avec exécution du script `scriptSQL.sql` et vérification que l'API répond correctement (`GET /api/tasks`).

## 3) Démarche CI/CD

- Un pipeline GitHub Actions existait déjà mais était mal placé (`frontend/.github/workflows/`, non détecté par GitHub vu que les repos "frontend", "backend" et "consignes" ont été fusionnés) et ciblait la branche `master` au lieu de `main`. Déplacé à la racine du dépôt (`.github/workflows/ci-cd.yml`) et corrigé (branche `main`, `working-directory: frontend`).

- Le pipeline (`.github/workflows/ci-cd.yml`) exécute les tests unitaires Angular (`ng test --browsers ChromeHeadless`) puis construit le bundle de production.

- Job `backend-test` : démarre un service MySQL 8 éphémère (`services: mysql`) avec un health-check (`mysqladmin ping`) pour garantir que la base est prête avant le lancement des tests. Les variables d'environnement (`DB_HOST`, `DB_USER`, `DB_PASSWORD`, `DB_NAME`, `DB_DIALECT`, `PORT`) sont injectées. Deux suites sont exécutées : les tests unitaires du service (`task.service.test.js`) et les tests d'intégration des routes REST (`task.routes.test.js`, via Supertest), avec `--runInBand` (les deux suites partagent la même base MySQL et se marchaient dessus en parallèle).

- L'architecture du workflow repose sur des dépendances strictes : `frontend-build` dépend de `frontend-test` **et** `backend-test`. Le build et le push des images Docker (vers GitHub Container Registry `ghcr.io`) ne se déclenchent que si l'intégralité des tests est au vert.

- Job `deploy` : matrice `[Corentin, Nicolas, Mael]`, chaque exécution liée à son propre GitHub Environment (`environment: ${{ matrix.member }}`) contenant les secrets Azure de ce membre. Le job s'authentifie en OIDC via une Managed Identity (cf. section 5.1), récupère le contexte AKS, remplace dynamiquement le tag `latest` par le Git SHA dans les manifests Kubernetes (via `sed`), applique la configuration (`kubectl apply -f k8s/`) puis installe/met à jour la stack de monitoring (`helm upgrade --install`). `fail-fast: false` pour qu'un cluster pas encore prêt ne bloque pas le déploiement des deux autres.

## 4) Configuration AKS

- Manifests organisés dans `k8s/` et appliqués de manière séquentielle grâce à un préfixe numérique pour garantir l'ordre de création (Namespace > Secret/PVC > Déploiements) :
  - `00-namespace.yaml` : création du namespace `todolist`.
  - `01-database.yaml` : Secret Kubernetes pour les credentials, PVC pour la persistance, Déploiement et Service MySQL (`strategy: Recreate` obligatoire — un `RollingUpdate` classique tenterait de démarrer un nouveau pod avant de libérer le PVC `ReadWriteOnce`, ce qui bloque indéfiniment).
  - `02-backend.yaml` / `03-frontend.yaml` : Déploiements utilisant les images poussées sur GHCR (`imagePullPolicy: IfNotPresent`) et Services (Node.js port 3000, Nginx port 80).
  - `04-ingress.yaml` : Ingress NGINX routant `/api` vers le backend et `/` vers le frontend.
  - `05-servicemonitor.yaml` : `ServiceMonitor` (CRD Prometheus Operator) pour que Prometheus scrape `/metrics` sur le backend (métriques custom via `prom-client`, cf. section 6).
- `ingress-nginx` installé séparément via Helm (pas dans les manifests `kubectl apply`, car c'est une brique d'infrastructure du cluster, pas de l'application) :
  ```
  helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
  helm install ingress-nginx ingress-nginx/ingress-nginx --namespace ingress-nginx --create-namespace
  ```

## 5) Infrastructure Terraform

- Prérequis : Terraform >= 1.5.0, Azure CLI connecté (`az login`), une Subscription ID valide.
- `iac/main.tf` provisionne un cluster AKS (`azurerm_kubernetes_cluster`) dans un resource group **existant** (fourni par l'école, lu via `data "azurerm_resource_group"`, jamais créé par Terraform). Node pool `Standard_B2ms`, identité `SystemAssigned`, `network_policy = "azure"` activée dès la création.
- Chaque ressource créée porte le tag `user = <myuid>` obligatoire, hérité automatiquement des tags du resource group (déjà conforme à la policy de l'école) via un `merge()`.
- `iac/terraform.tfvars` (non versionné, personnel à chaque membre) : copier `terraform.tfvars.example`, renseigner `resource_group_name`, `myuid` et `github_environment_name`.
- Utilisation : `terraform init`, `terraform plan`, `terraform apply` depuis `iac/`. `terraform output` donne ensuite la commande `az aks get-credentials` prête à l'emploi ainsi que les secrets nécessaires côté GitHub Actions (cf. 5.1).

### 5.1) Identité CI/CD gérée par Terraform

En plus du cluster AKS, `iac/main.tf` provisionne tout ce dont le pipeline GitHub Actions a besoin
pour s'authentifier auprès d'Azure sans aucun secret stocké côté Azure :
- `azurerm_user_assigned_identity` : une Managed Identity par étudiant.
- `azurerm_role_assignment` : rôle `Contributor` sur le resource group (nécessaire pour
  `az aks get-credentials` et `kubectl apply`).
- `azurerm_federated_identity_credential` : le lien de confiance OIDC entre GitHub Actions et
  cette identité (fédération de jeton — GitHub prouve son identité à Azure sans mot de passe ni
  client secret).

`terraform output` affiche directement les 5 valeurs à coller dans les secrets GitHub Actions
(`Settings > Environments > <votre prénom>`) : `AKS_RG`, `AKS_CLUSTER`, `AZURE_CLIENT_ID`,
`AZURE_TENANT_ID`, `AZURE_SUBSCRIPTION_ID`.

**Pourquoi une Managed Identity et pas une App Registration classique ?** L'école bloque la
création d'App Registrations pour les comptes étudiants (`Insufficient privileges to complete
the operation` — la permission de créer des applications Azure AD est désactivée au niveau du
tenant). Une Managed Identity contourne ce blocage : sa création passe par une permission ARM
(`Microsoft.ManagedIdentity/*`), pas par Microsoft Graph, donc elle n'a pas besoin de cette
permission désactivée.

## 6) Monitoring

- Stack `kube-prometheus-stack` (Prometheus + Grafana + Alertmanager + node-exporter + kube-state-metrics)
  installée via Helm, release `monitoring`, namespace `monitoring`. Intégrée au pipeline CI/CD
  (`deploy` job, `helm upgrade --install`) — pas seulement une installation manuelle.
- Récupération du mot de passe admin Grafana :
  ```
  kubectl get secret --namespace monitoring monitoring-grafana -o jsonpath="{.data.admin-password}" | base64 --decode ; echo
  ```
- Accès local (pas d'exposition publique de Grafana pour ce projet) :
  ```
  kubectl port-forward -n monitoring svc/monitoring-grafana 3000:80
  ```

### 6.1) Métriques custom du backend

- Ajout de `prom-client` au backend (`backend/src/config/metrics.js`) : endpoint `GET /metrics`,
  un `Histogram` (durée des requêtes HTTP) et un `Counter` (nombre de requêtes), tous deux labellisés
  par méthode/route/status code, en plus des métriques par défaut (CPU, mémoire, event loop).
- `k8s/05-servicemonitor.yaml` déclare un `ServiceMonitor` pour que Prometheus scrape cet endpoint.
- **Piège rencontré** : `ServiceMonitor.spec.selector` filtre sur les labels du **Service**
  Kubernetes lui-même (`metadata.labels`), pas sur les labels des pods derrière ce Service. Le
  Service `backend` n'avait pas de label `app: backend` sur lui-même (seuls le Deployment et ses
  pods l'avaient) → la cible apparaissait dans Prometheus mais toujours en `droppedTargets`,
  jamais scrapée. Correction : ajout du label directement sur le Service.
- **Second piège** : même avec les flags Helm `podMonitorSelectorNilUsesHelmValues=false` et
  `serviceMonitorSelectorNilUsesHelmValues=false`, Prometheus ne surveille par défaut que les
  `ServiceMonitor` situés dans **son propre namespace** (`monitoring`). Notre `ServiceMonitor` vit
  dans `todolist` → il fallait en plus `serviceMonitorNamespaceSelector={}` /
  `podMonitorNamespaceSelector={}` (syntaxe Helm : `--set-json`, car `--set foo={}` ne produit pas
  un objet vide valide) pour autoriser Prometheus à regarder dans tous les namespaces.
- Dashboard Grafana custom exporté dans `monitoring/` (`backend-custom-metrics-dashboard.json` +
  capture d'écran) : taux de requêtes par route, latence p95, requêtes par status code, nombre de
  replicas backend up — toutes alimentées par les métriques custom ci-dessus, données réelles du
  cluster.

## 7) Difficultés rencontrées

- Repérer et lever le conflit entre deux stratégies possibles d'injection de l'URL API (substitution runtime vs. génération au build CI) avant qu'il ne cause une régression silencieuse.

- Docker ne démarrait pas nativement dans la LXC Proxmox (erreur `sysctl net.ipv4.ip_unprivileged_port_start: permission denied`) : nécessité d'activer `nesting`/`keyctl` et d'ajouter `lxc.apparmor.profile: unconfined` côté hôte Proxmox.

- Une synchronisation de fichiers via `tar` vers la LXC a temporairement recréé un working tree Git divergent, sur un clone séparé du dépôt présent sur la LXC — résolu par un `git checkout --` ciblé plutôt qu'un reset destructif.

- Erreur de taille de nœuds lors du déploiement de l'infra avec Terraform (`Standard_B2s` jugé trop juste par le formateur, besoin de `Standard_B2ms`) : Azure ne permet pas de redimensionner un node pool existant en place. Testé `temporary_name_for_rotation` (rotation via un pool temporaire) mais le compte étudiant n'a pas le rôle `agentPools/delete` nécessaire — résolu par un `terraform destroy` / `plan` / `apply` complet à la place.

### 7.1) L'authentification OIDC GitHub Actions ↔ Azure

De loin la difficulté la plus longue du projet (plusieurs heures étalées sur deux jours). Résumé
des étapes et des impasses, dans l'ordre :

1. **L'école bloque la création d'App Registrations classiques** (`az ad sp create-for-rbac`) :
   `Insufficient privileges to complete the operation`. Solution : Managed Identity + fédération
   OIDC à la place (cf. section 5.1) — ne nécessite pas cette permission.
2. **`MissingSubscription` sur `az role assignment create`** : en réalité un bug Git Bash sous
   Windows — MSYS2 convertit automatiquement tout argument commençant par `/` en chemin Windows
   avant de le passer à `az.exe`, corrompant `--scope /subscriptions/...`. Fix : préfixer la
   commande avec `MSYS_NO_PATHCONV=1`.
3. **Le subject OIDC dépend de la présence ou non de `environment:` dans le job GitHub Actions.**
   Avec `environment: ${{ matrix.member }}` (nécessaire pour que chaque membre de l'équipe utilise
   ses propres secrets), le subject devient `repo:{owner}@{ownerId}/{repo}@{repoId}:environment:{env}`
   au lieu du classique `repo:{owner}/{repo}:ref:refs/heads/{branche}`. Le federated credential
   doit matcher exactement ce format, sinon `AADSTS700213`.
4. **L'issuer doit se terminer par un `/`** (`https://token.actions.githubusercontent.com/`), sans
   quoi Azure renvoie `AADSTS700211` — message trompeur qui ressemble à un problème de subject
   alors que c'est bien l'issuer qui ne correspond pas. Piège d'autant plus vicieux que la plupart
   des exemples/docs en ligne omettent ce slash.
5. **`azure/login@v2` attend le Client ID (Application ID), pas l'Object ID (Principal ID)** de la
   Managed Identity — deux GUID différents pour la même ressource. Confusion testée sur suggestion
   du formateur, sans succès (mais cela a au moins confirmé que ce n'était pas la cause).
6. **Mise à jour Terraform en place (`~ update in-place`) vs suppression/recréation** : changer
   l'issuer d'un `azurerm_federated_identity_credential` déjà existant via un simple `terraform
   apply` (qui fait un `PATCH`) n'a pas suffi pour deux des trois membres de l'équipe — la
   suppression puis recréation explicite via `az identity federated-credential delete` + `create`
   a débloqué la situation. Leçon retenue : sur cette ressource spécifique, préférer un
   delete+create à une mise à jour en place en cas de comportement incohérent.
7. **Cas non résolu** : malgré la suppression/recréation du federated credential, une attente de
   30+ minutes sans aucune modification, et même la création d'une **toute nouvelle** Managed
   Identity de zéro (nouveau nom, nouveau Client ID, nouveau rôle, nouveau federated credential —
   donc aucune ressource partagée avec les tentatives précédentes), l'authentification OIDC
   échoue encore pour un des trois comptes, avec le message `AADSTS700211`/`700213` en alternance,
   sans qu'aucune configuration incorrecte n'ait pu être identifiée. Hypothèse la plus probable :
   un état incohérent côté backend Azure AD, propre à ce compte/resource group, probablement lié
   au volume inhabituel de créations/suppressions effectuées dessus pendant le débogage.
   Contournement retenu : déploiement manuel (`az aks get-credentials` + `kubectl apply -f k8s/`
   depuis un terminal déjà authentifié), qui fonctionne parfaitement et ne dépend pas de cette
   authentification OIDC.

### 7.2) Autres difficultés notables

- **GitHub Actions cesse silencieusement de se déclencher sur `push`** après une série d'échecs et
  de re-lancements manuels rapprochés dans la même journée (probablement une protection
  anti-boucle côté GitHub) — aucune erreur visible, juste une absence totale de nouveau run.
  `workflow_dispatch` (déclenchement manuel) continuait de fonctionner normalement, ce qui a permis
  de continuer à tester. Ajout du trigger `workflow_dispatch: {}` au workflow (utile de toute façon).
  Piège associé : les jobs conditionnés par `if: github.event_name == 'push'` ne se déclenchaient
  plus du tout en `workflow_dispatch` (skip silencieux) — condition élargie à
  `(github.event_name == 'push' || github.event_name == 'workflow_dispatch')`.
- **Packages GHCR non liés au dépôt** : des images poussées manuellement via un token personnel ne
  sont pas automatiquement accessibles en écriture aux autres collaborateurs du dépôt via
  `GITHUB_TOKEN`. Il faut explicitement lier chaque package au dépôt (Package Settings > Manage
  Actions access > Add Repository, rôle Write).
- **`.git` imbriqué accidentel** : un `git init` lancé par erreur depuis `iac/` a créé un second
  dépôt Git vide directement dans ce dossier, masquant le vrai dépôt dès que le terminal s'y
  trouvait (`git status` affichait "No commits yet"). Résolu en supprimant simplement ce `.git`
  imbriqué (aucun commit n'y avait été fait, donc aucune perte).

## 8) Déploiement manuel (contournement)

Comme expliqué en section 7.1, l'authentification OIDC entre GitHub Actions et Azure ne fonctionne
pas de façon fiable pour tous les membres de l'équipe (cause probable : incohérence côté backend
Azure AD, non reproductible à volonté, jamais résolue malgré une recréation complète des
ressources concernées). Le pipeline CI/CD reste donc fonctionnel pour les tests, le build et le
push des images (aucun de ces jobs ne dépend d'Azure), mais **le déploiement automatisé sur AKS
n'est pas garanti à 100 % selon le compte**. Pour ne pas dépendre de ce point de friction externe
au projet, voici la procédure de déploiement manuel complète — strictement équivalente à ce que
fait le job `deploy` du workflow, exécutée à la main depuis un poste déjà authentifié
(`az login`) :

**1. Infrastructure (une seule fois, ou après un `terraform destroy`)**
```
cd iac
terraform init
terraform plan
terraform apply
```

**2. Credentials du cluster**
```
az aks get-credentials --resource-group <resource_group_name> --name <cluster_name>
kubectl get nodes   # vérifie que le cluster répond
```

**3. Ingress controller (une seule fois par cluster — brique d'infrastructure, pas applicative)**
```
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
helm repo update
helm install ingress-nginx ingress-nginx/ingress-nginx --namespace ingress-nginx --create-namespace
kubectl get svc -n ingress-nginx ingress-nginx-controller   # récupère l'IP publique (EXTERNAL-IP)
```

**4. Application (à chaque nouvelle version)**
```
git pull
kubectl apply -f k8s/
kubectl get pods -n todolist   # vérifie que tous les pods passent Running
```

**5. Monitoring (une seule fois, ou pour mettre à jour la stack)**
```
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update
helm upgrade --install monitoring prometheus-community/kube-prometheus-stack \
  --namespace monitoring \
  --create-namespace \
  --set grafana.adminPassword=<mot_de_passe_au_choix> \
  --set-json prometheus.prometheusSpec.podMonitorSelectorNilUsesHelmValues=false \
  --set-json prometheus.prometheusSpec.serviceMonitorSelectorNilUsesHelmValues=false \
  --set-json prometheus.prometheusSpec.podMonitorNamespaceSelector='{}' \
  --set-json prometheus.prometheusSpec.serviceMonitorNamespaceSelector='{}' \
  --wait
```

**6. Vérification de bout en bout**
```
curl http://<EXTERNAL-IP>/           # doit répondre 200 (frontend)
curl http://<EXTERNAL-IP>/api/tasks  # doit répondre [] ou la liste des tâches (backend + DB)
```
