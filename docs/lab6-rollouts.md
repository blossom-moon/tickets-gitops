# ЛР6 — Progressive delivery з Argo Rollouts: команди для виконання та захисту

Обрано стратегію **canary**.

## 1. Контролер Argo Rollouts через Argo CD

```bash
cd <папка tickets-gitops>
git mv next/lab6/argo-rollouts.yaml argocd-apps/
git commit -m "Add Argo Rollouts controller"
git push
argocd app get root --refresh
argocd app get argo-rollouts                  # Synced / Healthy
kubectl get pods -n argo-rollouts
```

Плагін: завантажити `kubectl-argo-rollouts-windows-amd64` з https://github.com/argoproj/argo-rollouts/releases/latest, перейменувати на `kubectl-argo-rollouts.exe` і покласти в папку з PATH.

```bash
kubectl argo rollouts version
```

## 2. Rollout у чарті

Шаблон `charts/tickets/templates/app-rollout.yaml` рендериться, коли `rollout.enabled: true`. Тоді `app-deployment.yaml` не рендериться. Pod-шаблон спільний (`tickets.app.podTemplate` у `_helpers.tpl`).

У `charts/tickets/values-minikube.yaml`:

```yaml
app:
  replicaCount: 4
...
rollout:
  enabled: true
```

```bash
git commit -am "Switch to Argo Rollouts (canary, 4 replicas)"
git push
argocd app get tickets --refresh
kubectl argo rollouts get rollout tickets-app -n kostetska
```

Argo CD видаляє Deployment і створює Rollout. Перший запуск відбувається без canary-кроків.

## 3. Стратегія (values.yaml → `rollout.canary.steps`)

```yaml
steps:
  - setWeight: 25              # 1 под з 4 — нова версія
  - pause: { duration: 30s }   # пауза з таймером
  - setWeight: 50              # 2 з 4
  - pause: {}                  # ручна пауза — чекає promote
  - setWeight: 75              # 3 з 4
  - pause: { duration: 30s }
```

Без Ingress-контролера частка трафіку визначається співвідношенням подів за одним Service.

Чому canary (для усного пояснення):
- нову версію спершу отримує лише частина користувачів, тож помилка в купівлі квитків зачепить мало запитів;
- реліз можна зупинити на будь-якому кроці;
- blue-green тримає дві повні копії (8 подів замість 4–5), а для minikube це забагато пам'яті;
- canary готує ґрунт для ЛР7, де нову версію автоматично перевіряють за метриками на 25 % трафіку.

## 4. Реліз через Git

Окремий термінал — стан Rollout:

```bash
kubectl argo rollouts get rollout tickets-app -n kostetska --watch
```

Ще один термінал — цикл запитів усередині кластера:

```bash
kubectl run curl-loop -n kostetska --image=curlimages/curl:8.10.1 --restart=Never -- \
  sh -c 'while true; do curl -s http://tickets-app/version; echo; sleep 0.3; done'
kubectl logs -f curl-loop -n kostetska
# після демонстрації: kubectl delete pod curl-loop -n kostetska
```

Реліз:

```bash
# values-minikube.yaml: tag "1.1.0" → "1.2.0"
git commit -am "Release 1.2.0 (canary)"
git push
argocd app get tickets --refresh
```

У `--watch` видно кроки 25 % → пауза 30 с → 50 % → **Paused (CanaryPauseStep)**. У циклі запитів чергуються `1.1.0` і `1.2.0`, приблизно навпіл.

Дашборд (за бажанням): `kubectl argo rollouts dashboard`, потім http://localhost:3100.

```bash
kubectl argo rollouts promote tickets-app -n kostetska
```

Далі 75 % → 30 с → 100 %. У циклі лишається тільки `1.2.0`.

📸 Проміжний стан (2 stable + 2 canary), цикл з обома версіями, promote, фінальний стан. Інтерфейс Argo CD: дерево Rollout → ReplicaSets.

## 5. Скасування релізу

```bash
# values-minikube.yaml: tag "1.2.0" → "1.3.0"
git commit -am "Release 1.3.0"
git push
argocd app get tickets --refresh
# дочекатися Paused на 50 %
kubectl argo rollouts abort tickets-app -n kostetska
kubectl argo rollouts get rollout tickets-app -n kostetska   # Degraded, усі поди — 1.2.0
argocd app get tickets                                        # Synced / Degraded
```

Чому **Synced / Degraded**:
- **Synced**: у кластері Rollout має тег 1.3.0, як і записано в Git.
- **Degraded**: Rollout скасовано, а поди повернуто на stable-версію 1.2.0, тобто фактичний стан не відповідає специфікації.

Argo CD не відкочує Git сам, тому відкат завершується через Git:

```bash
git revert --no-edit HEAD
git push
argocd app get tickets --refresh               # Synced / Healthy, тег 1.2.0
```

📸 Abort, Synced + Degraded в Argo CD, Healthy після revert, `git log --oneline`.

## 6. Захист — що показати

Реліз комітом → проміжний стан (CLI `--watch` або дашборд) → promote → новий реліз → abort → Synced/Degraded → `git revert` → Healthy.
