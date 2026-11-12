# ЛР7 — Observability і відкат за метриками: команди для виконання та захисту

Передумова: ЛР5 і ЛР6 виконані, у кластері працюють Rollout і 4 репліки. Образи з ЛР5 уже містять `/metrics` і JSON-логи.

## 1. Стек моніторингу через Argo CD

```bash
cd <папка tickets-gitops>
git mv next/lab7/kube-prometheus-stack.yaml next/lab7/loki.yaml next/lab7/alloy.yaml argocd-apps/
git commit -m "Add monitoring stack: kube-prometheus-stack, Loki, Alloy"
git push
argocd app get root --refresh
argocd app list                                # усі Synced / Healthy (5–10 хв)
kubectl get pods -n monitoring
```

Grafana (окремий термінал):

```bash
kubectl port-forward svc/kps-grafana -n monitoring 3000:80
kubectl get secret kps-grafana -n monitoring -o jsonpath="{.data.admin-password}" | base64 -d; echo
```

http://localhost:3000 → `admin` / пароль з команди.

📸 `kubectl get pods -n monitoring`, головна сторінка Grafana.

## 2–4. Метрики, логи, дашборд, навантаження — увімкнення в чарті

У `charts/tickets/values-minikube.yaml`:

```yaml
metrics:
  serviceMonitor:
    enabled: true
  prometheusRule:
    enabled: true
analysis:
  enabled: true
dashboard:
  enabled: true
loadgen:
  enabled: true
```

```bash
git commit -am "Enable ServiceMonitor, alert, analysis, dashboard, load generator"
git push
argocd app get tickets --refresh
```

### Метрики (п. 2)

`/metrics` віддає Micrometer у форматі Prometheus:
- `http_server_requests_seconds_count{method, uri, status}` — лічильник запитів;
- `http_server_requests_seconds_bucket{le, ...}` — гістограма тривалості.

`uri` — шаблон маршруту (`/api/tickets/{id}`), а не сирий URL, тому кардинальність мала.

```bash
kubectl port-forward svc/kps-prometheus -n monitoring 9090:9090
```

http://localhost:9090 → Status → Targets → `serviceMonitor/kostetska/tickets-app/0` — **UP**.

Запити:

```promql
sum by (uri, status) (rate(http_server_requests_seconds_count{namespace="kostetska"}[1m]))
histogram_quantile(0.95, sum by (le) (rate(http_server_requests_seconds_bucket{namespace="kostetska"}[1m])))
```

### Логи (п. 3)

Кожен запит пишеться в stdout одним рядком JSON (`@timestamp`, `level`, `message`, `method`, `route`, `status`, `duration_ms`). Alloy пересилає логи в Loki.

Grafana → Explore → Loki:

```logql
{namespace="kostetska", container="app"} | json
{namespace="kostetska", container="app"} | json | status >= 500
```

### Дашборд (п. 4)

Grafana → Dashboards → **Tickets — застосунок**. Панелі: RPS (загалом і за версіями), частка 5xx, p95, CPU, пам'ять, логи Loki.

Дашборд зберігається у `charts/tickets/files/dashboard.json`. Його доставляє ConfigMap `tickets-app-dashboard` з міткою `grafana_dashboard: "1"`, а sidecar Grafana підхоплює такі ConfigMap.

### Навантаження і ще одна зміна (п. 5)

Генератор `tickets-loadgen` (2 поди, цикл `curl` до `/version` і `/api/public/info`) уже працює. На дашборді видно RPS, p95 і CPU.

Ще одна зміна — збільшення реплік через Git:

```bash
# values-minikube.yaml: replicaCount: 4 → 6
git commit -am "Scale to 6 replicas"
git push
argocd app get tickets --refresh
```

На панелях CPU і пам'яті з'являються нові поди, а навантаження на один под знижується. Після показу повернути 4.

📸 Target UP, PromQL-запит, LogQL з `status >= 500`, дашборд під навантаженням.

## 6. Автоматичний відкат за метриками

`charts/tickets/templates/analysistemplate.yaml` визначає частку не-5xx запитів **лише подів нової версії**: фільтр за міткою `rollouts_pod_template_hash`. Поріг — 0,95.

Крок `analysis` вставляється після `setWeight: 25`. Робиться 4 виміри з інтервалом 20 с, допускається не більше 1 невдалого.

Погана версія — `FAIL_RATE`: частка запитів, що отримують 500.

Термінали:
- `kubectl argo rollouts get rollout tickets-app -n kostetska --watch`
- Grafana: дашборд;
- Prometheus → Alerts.

```bash
# values-minikube.yaml: failRate: "0" → failRate: "0.3"
git commit -am "Bad release: FAIL_RATE=0.3"
git push
argocd app get tickets --refresh
```

Що відбувається:
1. Rollout створює canary-под з `FAIL_RATE=0.3`: зміна ConfigMap змінює хеш шаблону пода.
2. На кроці analysis створюється AnalysisRun, і частка успішних запитів canary становить ~0,7 < 0,95.
3. AnalysisRun **Failed**, після чого Rollout робить автоматичний **abort** і повертається на stable.

```bash
kubectl get analysisrun -n kostetska
kubectl describe analysisrun -n kostetska <ім'я>   # Measurements: value ~0.7, Phase: Failed
kubectl argo rollouts get rollout tickets-app -n kostetska
argocd app get tickets                              # Synced / Degraded
```

- Дашборд: сплеск на панелі «Частка помилок 5xx», а на RPS за версіями — окрема лінія нового хешу.
- Loki: `{namespace="kostetska", container="app"} | json | status >= 500`. У мітках записів `rollouts_pod_template_hash` — лише хеш нової версії. Для порівняння: `sum by (rollouts_pod_template_hash) (count_over_time({namespace="kostetska", container="app"} | json | status >= 500 [5m]))`.
- (d*) Prometheus → Alerts: `TicketsHighErrorRate` спершу Pending, через 1 хв — Firing. Загальна частка 5xx ≈ 25 % × 30 % ≈ 7,5 %, це більше за поріг 5 %.

Завершити відкат через Git:

```bash
git revert --no-edit HEAD
git push
argocd app get tickets --refresh               # Synced / Healthy
```

📸 AnalysisRun Failed, автоматичний abort, сплеск 5xx на дашборді, логи 5xx лише з подів нової версії, алерт Firing, Healthy після revert.

## 7. Захист — підказки для довільних запитів

PromQL:
```promql
sum(rate(http_server_requests_seconds_count{namespace="kostetska"}[1m]))                                   # RPS
sum(rate(http_server_requests_seconds_count{namespace="kostetska", status=~"5.."}[1m]))
  / sum(rate(http_server_requests_seconds_count{namespace="kostetska"}[1m]))                               # частка 5xx
histogram_quantile(0.99, sum by (le) (rate(http_server_requests_seconds_bucket{namespace="kostetska"}[5m]))) # p99
sum by (pod) (rate(container_cpu_usage_seconds_total{namespace="kostetska", container="app"}[1m]))         # CPU
up{namespace="kostetska"}                                                                                   # цілі
```

LogQL:
```logql
{namespace="kostetska", container="app"} | json | route="/version"
{namespace="kostetska", container="app"} | json | duration_ms > 100
sum by (status) (count_over_time({namespace="kostetska", container="app"} | json [1m]))
```

## Якщо щось не стартує

- Під у `Pending` з `Insufficient memory`: збільшити пам'ять minikube або тимчасово `replicaCount: 2`, `loadgen.replicas: 1`.
- Loki не синхронізується: у Argo CD → loki → помилка рендерингу. Найчастіше причина в значеннях `deploymentMode`/`storage` для іншої версії чарта. Помилку надіслати мені.
