#!/usr/bin/env bash
# Прогон демонстрации HPA от начала до конца: кластер, манифесты, нагрузка, логи.
# Нужны: minikube, kubectl, python3 с установленным locust (pip install locust).
# Логи складываются в ./logs, скриншоты дашборда делаются руками (minikube dashboard).
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p logs

USERS="${USERS:-400}"        # одновременных пользователей locust
SPAWN="${SPAWN:-40}"         # скорость добавления пользователей в секунду
DURATION="${DURATION:-4m}"   # длительность нагрузки

log() { echo "[$(date '+%H:%M:%S')] $*"; }

log "Поднимаю кластер"
minikube status >/dev/null 2>&1 || minikube start --cpus=2 --memory=4096
minikube addons enable metrics-server

log "Применяю манифесты"
kubectl apply -f deployment.yaml -f service.yaml -f hpa.yaml
kubectl rollout status deployment/scaletestapp --timeout=180s

# На macOS с docker-драйвером minikube service держит туннель в foreground, поэтому запускаю в фоне и читаю URL из вывода.
minikube service scaletestapp --url > logs/00_service_url.log 2>&1 &
TUN=$!
URL=""
for _ in $(seq 1 30); do
  URL="$(grep -oE 'http://[0-9.]+:[0-9]+' logs/00_service_url.log | head -n1 || true)"
  [ -n "$URL" ] && break
  sleep 1
done
[ -n "$URL" ] || { echo "Не получил URL сервиса, смотри logs/00_service_url.log"; exit 1; }
log "Приложение доступно по $URL"
curl -s "$URL/" || true

log "Жду, пока metrics-server начнёт отдавать метрики"
for _ in $(seq 1 24); do
  if kubectl top pod -l app=scaletestapp >/dev/null 2>&1; then break; fi
  sleep 5
done

{
  echo "=== $(date) до нагрузки ==="
  kubectl get pods -l app=scaletestapp -o wide
  kubectl top pod -l app=scaletestapp
  kubectl get hpa scaletestapp
} | tee logs/01_before.log

log "Запускаю наблюдателей"
kubectl get hpa scaletestapp -w > logs/02_hpa_watch.log 2>&1 &
W1=$!
kubectl get pods -l app=scaletestapp -w > logs/03_pods_watch.log 2>&1 &
W2=$!
(
  while true; do
    echo "--- $(date '+%H:%M:%S')"
    kubectl top pod -l app=scaletestapp 2>/dev/null || true
    sleep 15
  done
) > logs/04_top_every_15s.log 2>&1 &
W3=$!
trap 'kill $W1 $W2 $W3 $TUN 2>/dev/null || true' EXIT

log "Нагрузка: $USERS пользователей, +$SPAWN/с, $DURATION"
locust -f locustfile.py --headless -u "$USERS" -r "$SPAWN" -t "$DURATION" \
  --host "$URL" --csv logs/locust --only-summary 2>&1 | tee logs/05_locust.log

{
  echo "=== $(date) сразу после нагрузки ==="
  kubectl get hpa scaletestapp
  kubectl get pods -l app=scaletestapp -o wide
  kubectl top pod -l app=scaletestapp
  echo
  kubectl describe hpa scaletestapp
} | tee logs/06_after_load.log

log "Жду отката реплик вниз (2 минуты)"
sleep 120
{
  echo "=== $(date) после остывания ==="
  kubectl get hpa scaletestapp
  kubectl get pods -l app=scaletestapp
} | tee logs/07_after_cooldown.log

log "Готово. Дашборд: minikube dashboard (раздел Workloads -> Deployments и Horizontal Pod Autoscalers)"
