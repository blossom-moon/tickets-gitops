# tickets-gitops

Репозиторій конфігурації (GitOps) для застосунку [tickets](https://github.com/blossom-moon/DevOps-). Бажаний стан кластера minikube описано тут, Argo CD приводить кластер до нього.

| Каталог | Призначення |
|---|---|
| `bootstrap/` | кореневий Application (App of Apps) і інструкція створення Secret — застосовуються вручну один раз |
| `argocd-apps/` | Application, які Argo CD бере з Git через кореневий Application |
| `next/lab6/`, `next/lab7/` | Application для ЛР6 і ЛР7; переносяться в `argocd-apps/` під час виконання цих робіт |
| `charts/tickets/` | Helm-чарт застосунку з ЛР4, доповнений для ЛР5–7 |
| `charts/tickets/values-minikube.yaml` | значення для minikube; зміни тут доставляються в кластер комітом |
| `docs/` | покрокові команди ЛР5–7 |

## Схема

```
git push ──► GitHub (tickets-gitops)
                 │  Argo CD опитує репозиторій
                 ▼
argocd/root ──► argocd-apps/*.yaml
                 ├── tickets ──────────► charts/tickets + values-minikube.yaml ──► ns kostetska
                 ├── argo-rollouts (ЛР6) ► чарт argo-helm/argo-rollouts ──────────► ns argo-rollouts
                 ├── kube-prometheus-stack (ЛР7) ──────────────────────────────────► ns monitoring
                 ├── loki (ЛР7) ───────────────────────────────────────────────────► ns monitoring
                 └── alloy (ЛР7) ──────────────────────────────────────────────────► ns monitoring
```

## Образ застосунку

`ghcr.io/blossom-moon/tickets-app:<версія>`. Збирається в репозиторії застосунку скриптом `scripts/build-push.sh <версія>`; версія передається в образ при збірці (`APP_VERSION`) і повертається ендпоінтом `GET /version`.

## Нові параметри чарта (порівняно з ЛР4)

| Параметр | За замовчуванням | Опис |
|---|---|---|
| `secrets.existingSecret` | `""` | ім'я Secret, створеного вручну; якщо задано, чарт не створює Secret |
| `keycloak.enabled` | `true` | розгортати Keycloak (у minikube вимкнено для економії пам'яті) |
| `tests.enabled` | `true` | Pod для `helm test` |
| `app.progressDeadlineSeconds` | `120` | після цього часу оновлення без прогресу — Degraded |
| `app.config.failRate` | `"0"` | частка запитів, що отримують 500 (`FAIL_RATE`) |
| `rollout.enabled` | `false` | Rollout (Argo Rollouts) замість Deployment |
| `rollout.canary.steps` | 25% → пауза 30 с → 50% → ручна пауза → 75% → пауза 30 с | кроки canary |
| `metrics.serviceMonitor.enabled` | `false` | ServiceMonitor для Prometheus |
| `metrics.prometheusRule.enabled` | `false` | алерт на частку 5xx > 5% |
| `analysis.enabled` | `false` | AnalysisTemplate і крок `analysis` у canary |
| `analysis.afterStep` | `0` | після якого кроку вставляється `analysis` |
| `analysis.threshold` | `0.95` | мінімальна частка успішних запитів |
| `dashboard.enabled` | `false` | дашборд Grafana (ConfigMap `grafana_dashboard`) |
| `loadgen.enabled` | `false` | генератор навантаження в кластері |

## Порядок

1. [ЛР5 — Argo CD](docs/lab5-argocd.md)
2. [ЛР6 — Argo Rollouts](docs/lab6-rollouts.md)
3. [ЛР7 — Observability](docs/lab7-observability.md)
