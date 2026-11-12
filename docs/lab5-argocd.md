# ЛР5 — GitOps з Argo CD: команди для виконання та захисту

Команди — для Git Bash. `<...>` — підставити своє.

## 0. Кластер

Docker Desktop → Settings → Resources: щонайменше 6 CPU і 10 GB пам'яті (у ЛР7 у кластері працюють Argo CD, Prometheus, Grafana, Loki і застосунок).

```bash
minikube start --driver=docker --cpus=6 --memory=10g
kubectl get nodes
```

## 1. Образи застосунку (репозиторій DevOps-)

GitHub → Settings → Developer settings → Personal access tokens (classic) → токен з правом `write:packages`.

```bash
cd <папка репозиторію DevOps->
docker login ghcr.io -u blossom-moon            # пароль = токен
bash scripts/build-push.sh 1.0.0 1.1.0 1.2.0 1.3.0
```

Образи відрізняються лише версією, яку повертає `GET /version`. Чотири версії потрібні для ЛР5 (реліз 1.1.0) і ЛР6 (реліз 1.2.0, скасований реліз 1.3.0).

GitHub → профіль → Packages → `tickets-app` → Package settings → Change visibility → **Public**. Тоді кластер завантажує образ без `minikube image load` і без imagePullSecret.

📸 Сторінка пакета з тегами 1.0.0–1.3.0.

## 2. Репозиторій конфігурації

На GitHub створити **публічний** репозиторій `tickets-gitops` (порожній, без README).

```bash
cd <папка tickets-gitops>
git init -b main
git add .
git commit -m "GitOps: chart, root app, tickets app"
git remote add origin https://github.com/blossom-moon/tickets-gitops.git
git push -u origin main
```

Репозиторій публічний, тому підключати його до Argo CD з токеном не потрібно. У Git немає паролів: Secret створюється вручну (крок 4).

## 3. Argo CD

```bash
kubectl create namespace argocd
kubectl apply -n argocd --server-side --force-conflicts \
  -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
kubectl get pods -n argocd -w                  # усі Running
```

CLI: завантажити `argocd-windows-amd64.exe` з https://github.com/argoproj/argo-cd/releases/latest, перейменувати на `argocd.exe` і покласти в папку з PATH (або `choco install argocd-cli`).

```bash
argocd version --client

# веб-інтерфейс: окремий термінал, не закривати
kubectl port-forward svc/argocd-server -n argocd 8080:443

argocd admin initial-password -n argocd        # початковий пароль admin
argocd login localhost:8080 --username admin --insecure
argocd account update-password                 # новий пароль
kubectl delete secret argocd-initial-admin-secret -n argocd
```

https://localhost:8080 → admin / новий пароль.

📸 Вхід в інтерфейс, `argocd version`.

## 4. App of Apps

```bash
kubectl create namespace kostetska
kubectl create secret generic tickets-secrets -n kostetska \
  --from-literal=db-password='<пароль БД>' \
  --from-literal=keycloak-client-secret='<будь-яке значення>'

kubectl apply -f bootstrap/root-app.yaml       # єдиний об'єкт, що застосовується вручну
argocd app list                                # root і tickets
argocd app get tickets
kubectl get pods -n kostetska -w               # застосунок стартує ~1 хв
```

Перевірка застосунку (окремий термінал):

```bash
kubectl port-forward svc/tickets-app -n kostetska 8081:80
curl localhost:8081/version                    # {"version":"1.0.0"}
curl localhost:8081/api/public/info
```

📸 Інтерфейс: `root` → `tickets`, дерево об'єктів `tickets` (Service, Deployment → ReplicaSet → Pods, ConfigMap, PVC) у стані **Synced / Healthy**.

## 5. Реліз через Git

У `charts/tickets/values-minikube.yaml`: `tag: "1.0.0"` → `tag: "1.1.0"`.

```bash
git commit -am "Release 1.1.0"
git push
argocd app get tickets --refresh               # або кнопка Refresh; без неї Argo CD перевіряє Git раз на ~3 хв
kubectl get pods -n kostetska -w
curl localhost:8081/version                    # {"version":"1.1.0"}
```

Port-forward після заміни подів може обірватися — перезапустити його.

📸 Rolling update в інтерфейсі, відповідь 1.1.0, `argocd app history tickets`.

## 6a. Дрейф: без selfHeal і з selfHeal

```bash
kubectl scale deployment tickets-app -n kostetska --replicas=5
argocd app get tickets                         # Sync Status: OutOfSync
argocd app diff tickets                        # replicas: 2 (Git) vs 5 (кластер)
kubectl get pods -n kostetska                  # 5 подів лишаються
```

`selfHeal: false` — Argo CD бачить розбіжність, але сам її не виправляє. `automated` синхронізує лише зміни в Git.

У `argocd-apps/tickets.yaml`: `selfHeal: false` → `selfHeal: true`.

```bash
git commit -am "Enable selfHeal"
git push
argocd app get root --refresh                  # root застосовує новий tickets.yaml
kubectl get pods -n kostetska -w               # повернення до 2 подів

kubectl scale deployment tickets-app -n kostetska --replicas=5
kubectl get deployment tickets-app -n kostetska -w   # за кілька секунд знову 2
```

📸 OutOfSync з diff; повернення до 2 реплік після selfHeal.

## 6b. Synced, але Degraded

У `values-minikube.yaml`: `tag: "1.1.0"` → `tag: "9.9.9"`.

```bash
git commit -am "Release 9.9.9 (non-existent tag)"
git push
argocd app get tickets --refresh
kubectl get pods -n kostetska                  # новий под ImagePullBackOff, старі працюють
```

Через ~2 хв (`progressDeadlineSeconds: 120`): **Synced / Degraded**.

- **Synced**: кластер відповідає Git, бо Deployment має тег 9.9.9, як і записано в Git.
- **Degraded**: Deployment не може завершити оновлення, бо образу з таким тегом немає.

Застосунок продовжує відповідати версією 1.1.0, бо `maxUnavailable: 0`.

📸 Synced + Degraded, `kubectl describe pod` → Events.

## 6c. Відкат через git revert

```bash
git revert --no-edit HEAD
git push
argocd app get tickets --refresh
git log --oneline
argocd app history tickets
curl localhost:8081/version                    # 1.1.0
```

📸 `git log`, `argocd app history`, Healthy.

## 7. Захист — що показати

1. Інтерфейс Argo CD: root → tickets, Synced / Healthy.
2. Реліз комітом: тег → push → Refresh → `/version`.
3. `kubectl scale` → selfHeal повертає.
4. Тег 9.9.9 → Synced + Degraded.
5. `git revert` → Healthy, `argocd app history`.

Якщо викладач попросить змінити значення в Git (наприклад `app.config.message`): змінити в `values-minikube.yaml`, push, Refresh. Зміна ConfigMap змінює контрольну суму в шаблоні пода, тому поди перезапускаються, і нове значення видно в `curl localhost:8081/api/public/info`.
