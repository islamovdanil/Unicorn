### Балансировка нагрузки и отказоустойчивость

Patroni — для управления кластером и автоматического failover. HAProxy — для маршрутизации трафика. Для этого развернуть ETCD кластер (минимум 3 ноды), настроить сетевые подключений, обеспечить безопасность соединений.
Установить PostgreSQL на все ноды, настроить базовую конфигурацию и утсановить Patroni на ноды. 
Примерный конфиг Patroni
```
postgresql:
    datadir: /var/lib/postgresql/12/main
    bin_dir: /usr/lib/postgresql/12/bin
authentication:
      superuser: {username: 'postgres'}
      parameters:
    max_connections: 100
    wal_level: logical
    max_wal_senders: 5
    wal_keep_segments: 8
    hot_standby: true
etcd:
  host: etcd-node1:2379,etcd-node2:2379,etcd-node3:2379
restapi:
  listen: 0.0.0.0:8008
bootstrap:
  dcs:
    ttl: 30
    scope: postgres-cluster
  initdb:
    encoding: UTF8
    data-checksums: true
  postgresql:
    users:
      admin:
        password: 'secure_password'
        options:
          createrole: true
          login: true
```          
## Примерный конфиг HaProxy
```
global
    log 127.0.0.1 local0
    maxconn 4000
defaults
    log global
    retries 3
    maxconn 2000
    timeout connect 5000ms
    timeout client 50000ms
    timeout server 50000ms
frontend postgres-fe
    bind *:5432
    default_backend postgres-be
backend postgres-be
    balance roundrobin
    option prefer-last-server
    server master 192.168.1.1:5432 check
    server replica1 192.168.1.2:5432 check backup
    server replica2 192.168.1.3:5432 check backup
```
## Структура:
```
+------------------+
|  ETCD Cluster    |
+------------------+
          |
+---------+---------+
| Patroni Cluster   |
+---------+---------+
|          |        |
| PostgreSQL|PostgreSQL|
|  (Master) | (Replica) |
+-----------+-----------+
          |
     +----+----+
     | HAProxy |
     +----+----+
```

### TLS и безопасность
С помощью certbot получить серт для домена
```
certbot certonly \
  --dns-cloudflare \
  --dns-cloudflare-credentials /etc/letsencrypt/cloudflare.ini \
  -d example.local
```
и добавить в cron ``` 0 0 * * * certbot renew --quiet ```
Сгенерировать серты для CA, прокси и апп
```
openssl req -x509 -nodes -days 365 -newkey rsa:2048 -keyout ca.key -out ca.crt
openssl req -newkey rsa:2048 -nodes -keyout nginx.key -out nginx.csr
openssl x509 -req -days 365 -in nginx.csr -CA ca.crt -CAkey ca.key -set_serial 01 -out nginx.crt
openssl req -newkey rsa:2048 -nodes -keyout app.key -out app.csr
openssl x509 -req -days 365 -in app.csr -CA ca.crt -CAkey ca.key -set_serial 02 -out app.crt
```
Дополнить конфиг nginx
```
server {
    listen 443 ssl;
    server_name example.local;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers HIGH:!aNULL:!MD5;
    ssl_certificate /etc/ssl/nginx.crt;
    ssl_certificate_key /etc/ssl/nginx.key;
    ssl_client_certificate /etc/ssl/ca.crt;
    ssl_verify_client on;
```
# Сетевая безопасность
Правила для балансировщика (Nginx):
Входящие:
Порт 80 (HTTP) - только для перенаправления на HTTPS
Порт 443 (HTTPS) - для внешнего доступа
Исходящие:
Порт 53 (DNS) для Let’s Encrypt
Порт 443 для коммуникации с Let’s Encrypt
Правила для внутренних сервисов:
Между балансировщиком и приложениями:
Порт 5000 (или другой внутренний порт) только для трафика от Nginx
Требование клиентского сертификата
Для PostgreSQL:
Порт 5432 только с IP-адресов приложений

### Мониторинг
Ключевые метрики для мониторинга
Application:
http_requests_total - общее количество HTTP запросов
request_duration_seconds - время обработки запроса
process_resident_memory_bytes - используемая память
Balancer:
nginx_connections - активные соединения
nginx_requests_total - общее количество запросов
nginx_upstream_response_time - время ответа бэкендов
Database:
pg_stat_statements_calls - количество запросов
pg_stat_statements_total_time - общее время выполнения запросов
pg_backend_memory_size - использование памяти


### CI/CD
Примерный github actions с blue/green деплоем
```
name: CI/CD Pipeline
on:
  push:
    branches:
      - main
  pull_request:
    branches:
      - main
jobs:
  build-test:
    runs-on: ubuntu-latest
    steps:
      - name: Checkout code
        uses: actions/checkout@v3
      - name: Set up Docker Buildx
        uses: docker/setup-buildx-action@v2
      - name: Install dependencies
        run: |
          pip install -r requirements.txt
      - name: Run unit tests
        run: |
          pytest tests/unit
      - name: Run integration tests
        run: |
          pytest tests/integration
      - name: Build Docker image
        uses: docker/build-push-action@v3
        with:
          context: .
          file: ./Dockerfile
          tags: registry.example.com/app:${{ github.sha }}
          push: true
  deploy:
    needs: build-test
    runs-on: ubuntu-latest
    steps:
      - name: Checkout code
        uses: actions/checkout@v3
      - name: Set up Docker
        uses: docker/setup-buildx-action@v2
      - name: Deploy to Green Environment
        run: |
          # Развертывание нового окружения
          kubectl set image deployment/app-green app=registry.example.com/app:${{ github.sha }}
          kubectl rollout status deployment/app-green
      - name: Update Traffic Weights
        run: |
          # Направляем 10% трафика на новое окружение
          kubectl patch deployment app-green -p '{"spec":{"template":{"metadata":{"annotations":{"traffic-weight":"10"}}}}}'
      - name: Monitor Green Environment
        id: monitor
        run: |
          # Мониторинг ошибок в новом окружении
          if check_errors; then
            echo "::set-output name=status::success"
          else
            echo "::set-output name=status::failure"
          fi
      - name: Full Traffic Switch
        if: steps.monitor.outputs.status == 'success'
        run: |
          # Переключение всего трафика на новое окружение
          kubectl patch deployment app-green -p '{"spec":{"template":{"metadata":{"annotations":{"traffic-weight":"100"}}}}}'
          kubectl scale deployment app-blue --replicas=0
      - name: Rollback
        if: steps.monitor.outputs.status == 'failure'
        run: |
          # Возврат к старому окружению
          kubectl patch deployment app-green -p '{"spec":{"template":{"metadata":{"annotations":{"traffic-weight":"0"}}}}}'
          kubectl scale deployment app-blue --replicas=1
      - name: Cleanup
        if: always()
        run: |
          # Очистка ресурсов
          sleep 300  # Ждем 5 минут для автоматического отката
          if check_green_status; then
            kubectl delete deployment app-blue
            kubectl apply -f green-deployment.yaml
          else
            kubectl delete deployment app-green
          fi
```
### IaC
Структура ansible
ansible/
├── inventory/
│   ├── production.ini
```
[docker-hosts]
app-server ansible_host=192.168.1.10 ansible_user=admin
db-server ansible_host=192.168.1.11 ansible_user=admin
```
│   └── development.ini
```
[docker-hosts]
localhost ansible_connection=local
```
├── group_vars/
│   └── all.yml
```
docker_networks:
  app-net: {}
  db-net: {}
  frontend-net: {}
services:
  app:
    image: registry.example.com/app:latest
    ports:
      - "5000:5000"    
  nginx:
    image: nginx:latest
    ports:
      - "80:80"
      - "443:443"
  db:
    image: postgres:latest
    env:
      POSTGRES_DB: "{{ vault_db_name }}"
      POSTGRES_USER: "{{ vault_db_user }}"
```
├── roles/
│   ├── network
│   │   ├── tasks
│   │   │   └── main.yml
```
---
- name: Create Docker networks
  ansible.builtin.docker_network:
    name: "{{ item.name }}"
    driver: bridge
  with_items: "{{ docker_networks }}"
```
│   │   └── vars
│   │       └── main.yml
│   ├── database
│   │   ├── tasks
│   │   │   └── main.yml
```
---
- name: Create PostgreSQL volume
  ansible.builtin.docker_volume:
    name: postgres-data
- name: Deploy PostgreSQL container
  ansible.builtin.docker_container:
    name: postgres-db
    image: "{{ services.db.image }}"
    env:
      POSTGRES_DB: "{{ vault_db_name }}"
      POSTGRES_USER: "{{ vault_db_user }}"
      POSTGRES_PASSWORD: "{{ vault_db_password }}"
    volumes:
      - postgres-data:/var/lib/postgresql/data
    networks:
      db-net: {}
```
│   │   └── vars
│   │       └── main.yml
│   └── application
│       ├── tasks
│       │   └── main.yml
```
---
- name: Deploy App containers
  ansible.builtin.docker_container:
    name: "app-{{ item }}"
    image: "{{ services.app.image }}"
    ports: "{{ services.app.ports }}"
    networks:
      app-net: {}
  with_sequence: count=2
- name: Deploy Nginx balancer
  ansible.builtin.docker_container:
```
│       └── vars
│           └── main.yml
├── vault/
│   └── secrets.yml
└── site.yml
```
---
- name: Deploy Docker Infrastructure
  hosts: docker-hosts
  become: yes
  vars_files:
    - vault/secrets.yml
    - group_vars/all.yml
  pre_tasks:
    - name: Install Docker
      ansible.builtin.apt:
        name:
          - docker.io
          - docker-compose
        state: present      
    - name: Start Docker service
      ansible.builtin.service:
        name: docker
        state: started
        enabled: yes
  roles:
    - { role: network, tags: 'network' }
    - { role: database, tags: 'database' }
    - { role: application, tags: 'application' }
  post_tasks:
    - name: Verify all services are running
      ansible.builtin.docker_service:
        name: "{{ item }}"
        state: started
      with_items:
        - app-1
        - app-2
        - nginx-balancer
        - postgres-db
```
Проверить плейбук
```ansible-playbook -i inventory/production.ini site.yml --syntax-check```
Зависимость ролей
```ansible-playbook -i inventory/production.ini site.yml --list-tasks --list-dependencies```
Dry-run
```ansible-playbook -i inventory/production.ini site.yml --check```
Запуск плейбука с подробностями
```ansible-playbook -i inventory/production.ini site.yml -vvv```
Использовать Vault
```ansible-playbook -i inventory/production.ini site.yml --ask-vault-pass```

### Диагностика и откладка
1. Первичная оценка ситуации
Сбор информации от пользователей: время и период проблемы, какое приложение/запрос/элемент АРМа, как часто проявляется. География пользователей
2. Анализ метрик и логов
Время ответа API
CPU/Memory usage
Количество запросов в секунду
Время выполнения запросов к БД
Распределение нагрузки
Время ответа бэкендов
Количество ошибок
Время выполнения запросов
Очередь запросов
Блокировки
Инструменты мониторинга:
Prometheus + Grafana для визуализации метрик
ELK Stack для анализа логов
Zabbix для инффраструктуры
OpenTelemetry для трассировки запросов

### Структура инфры
                        +------------------+
                        |   Cloud Provider |
                        +------------------+
                               |
                               v
        +---------------------+---------------------+
        |     Load Balancer Layer                   |
        +---------------------+---------------------+
                  | DNS                             |
                  v                                 |
        +---------+---------+     +----------------+
        |  NGINX  |         |     |  NGINX  |       |
        |Balancer |         |     | Balancer|       |
        +---------+---------+     +----------------+
                  |            \    /              |
                  |             \  /               |
                  v              \/               v
        +---------------------+---------------------+
        |     Application Layer                   |
        +---------------------+---------------------+
        |                    |                     |
        |  App Service 1     |   App Service 2     |
        |  (Docker Container)|  (Docker Container) |
        |  + Flask App       |   + Flask App       |
        |  + Health Checks   |   + Health Checks   |
        +--------------------+---------------------+
                               |
                               v
        +---------------------+---------------------+
        |     Database Layer                        |
        +---------------------+---------------------+
        |                    |                     |
        |   PostgreSQL       |   PostgreSQL Replica |
        |  + Persistent Vol  |   + Read Replica     |
        |  + WAL Replication |                     |
        +--------------------+---------------------+
                               |
                               v
        +---------------------+---------------------+
        |     Monitoring & Logging               |
        +---------------------+---------------------+
        |                    |                     |
        |   Prometheus       |   ELK Stack         |
        |   + Metrics        |   + Log Aggregation |
        |   + Alerting       |   + Visualization   |
        +--------------------+---------------------+
                               |
                               v
        +---------------------+---------------------+
        |     Security Layer                        |
        +---------------------+---------------------+
        |                    |                     |
        |   HashiCorp Vault  |   TLS Termination   |
        |   + Secrets Mgmt   |   + mTLS            |
        +--------------------+---------------------+

















