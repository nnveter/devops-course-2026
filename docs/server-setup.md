# Конфигурация виртуальной машины devops-vm

Документ позволяет восстановить конфигурацию сервера со снимка `01-clean-install`.
Все команды выполняются от имени `devops` (кроме шагов, явно помеченных как выполняемые на хосте).

## 1. Параметры машины

| Параметр | Значение |
|---|---|
| Имя в VirtualBox | `devops-vm-salnikov` |
| Гостевая ОС | Ubuntu Server 22.04 LTS (cloud image) |
| Оперативная память | 4096 МБ |
| Процессор | 1 vCPU |
| Диск | 32 ГБ, динамически расширяемый |
| Имя узла | `devops-vm` (FQDN `devops-vm.devops.local`) |

## 2. Сетевые интерфейсы

| Адаптер | Тип | Интерфейс | Адрес | Назначение |
|---|---|---|---|---|
| 1 | NAT | `enp0s3` | 10.0.2.15/24 (DHCP) | доступ в Интернет (apt, docker pull), SSH через проброс порта |
| 2 | Host-only (`VirtualBox Host-Only Ethernet Adapter #2`) | `enp0s8` | 192.168.57.23/24 | доступ с хоста: `devops.local`, HTTP/HTTPS |

## 3. Правило проброса портов (адаптер 1, NAT)

| Имя | Протокол | Адрес хоста | Порт хоста | Порт гостя |
|---|---|---|---|---|
| ssh | TCP | 127.0.0.1 | 2222 | 2222 |

```powershell
VBoxManage controlvm devops-vm-salnikov natpf1 "ssh,tcp,127.0.0.1,2222,,2222"
```

## 4. Учётные записи

| Имя | Группы | Аутентификация |
|---|---|---|
| `devops` | `devops`, `sudo`, `docker` | только ключ ed25519 (`~/.ssh/devops_vm` на хосте) |
| `root` | — | вход по SSH запрещён |

```bash
sudo adduser devops && sudo usermod -aG sudo devops
# на хосте:
ssh-keygen -t ed25519 -C "devops-vm-key" -f ~/.ssh/devops_vm
ssh-copy-id -i ~/.ssh/devops_vm.pub -p 2222 devops@127.0.0.1
# права на сервере: ~/.ssh — 700, ~/.ssh/authorized_keys — 600
```

Файл `~/.ssh/config` на хосте:

```
Host devops
    HostName 127.0.0.1
    Port 2222
    User devops
    IdentityFile ~/.ssh/devops_vm
    IdentitiesOnly yes
```

## 5. Служба SSH

Основной файл `/etc/ssh/sshd_config` не изменяется (эталонная копия — `/etc/ssh/sshd_config.backup`).
Директивы задаются в `/etc/ssh/sshd_config.d/99-hardening.conf`:

```
Port 2222
PermitRootLogin no
PasswordAuthentication no
KbdInteractiveAuthentication no
PubkeyAuthentication yes
PermitEmptyPasswords no
MaxAuthTries 3
LoginGraceTime 30
AllowUsers devops
X11Forwarding no
ClientAliveInterval 300
ClientAliveCountMax 2
```

Файлы `50-cloud-init.conf` и `60-cloudimg-settings.conf` содержат `PasswordAuthentication no` и не конфликтуют.
Применение (не закрывая текущую сессию):

```bash
sudo sshd -t && sudo systemctl restart ssh
sudo sshd -T | grep -Ei "^(port|permitrootlogin|passwordauthentication|maxauthtries|allowusers)"
sudo ss -tlnp | grep sshd        # 0.0.0.0:2222
```

`ssh.socket` отключён, работает `ssh.service` (`systemctl disable --now ssh.socket; systemctl enable --now ssh.service`).

## 6. Правила межсетевого экрана

Политики: `deny (incoming)`, `allow (outgoing)`, `deny (routed)`. Журналирование: `medium`.

```bash
sudo ufw default deny incoming
sudo ufw default allow outgoing
sudo ufw limit 2222/tcp comment 'SSH rate-limited'
sudo ufw allow 80/tcp comment 'HTTP'
sudo ufw allow 443/tcp comment 'HTTPS'
sudo ufw logging medium
sudo ufw enable
```

| № | Порт | Действие | Комментарий |
|---|---|---|---|
| 1 | 2222/tcp | LIMIT IN | SSH rate-limited |
| 2 | 80/tcp | ALLOW IN | HTTP |
| 3 | 443/tcp | ALLOW IN | HTTPS |

Имя `devops.local` на хосте: строка `192.168.57.23 devops.local` в `C:\Windows\System32\drivers\etc\hosts`.
FQDN узла: `127.0.1.1 devops-vm.devops.local devops-vm` в `/etc/hosts` (и в шаблоне cloud-init `/etc/cloud/templates/hosts.debian.tmpl`).

## 7. Снимки состояния

| Снимок | Момент создания |
|---|---|
| `01-clean-install` | после установки ОС и создания учётной записи |
| `02-keys-configured` | вход по ключу проверен |
| `03-ssh-hardened` | SSH на порту 2222, root и пароль запрещены |
| `04-nginx-https` | Nginx с HTTPS (ПР № 6) |
| `05-docker-compose` | приложение + PostgreSQL (ПР № 7) |
| `06-before-kr2` | перед КР № 2 |
| `07-kr2` | после КР № 2 |

## 8. Веб-сервер

| Параметр | Значение |
|---|---|
| Пакет | `nginx` (Ubuntu, `apt install -y nginx`), версия 1.18.0 |
| Конфигурация ресурса | `/etc/nginx/sites-available/devops-site`, ссылка в `/etc/nginx/sites-enabled/`; ссылка на `default` удалена |
| Каталог ресурса | `/var/www/devops-site`, владелец `devops:devops`, каталоги 755, файлы 644 |
| Сертификат | `/etc/ssl/certs/devops.crt`, `root:root`, 644, CN и SAN `devops.local`, срок 365 дней |
| Закрытый ключ | `/etc/ssl/private/devops.key`, `root:root`, 600 |
| Журналы | `/var/log/nginx/devops-site.access.log`, `/var/log/nginx/devops-site.error.log` |
| Доставка | `scripts/deploy.sh` (rsync `--delete --chmod=D755,F644`) |

Формирование сертификата:

```bash
sudo openssl req -x509 -nodes -days 365 -newkey rsa:2048   -keyout /etc/ssl/private/devops.key   -out /etc/ssl/certs/devops.crt   -subj "/CN=devops.local"   -addext "subjectAltName=DNS:devops.local"
```

Конфигурация ресурса — блок перенаправления HTTP → HTTPS (`return 301`) и блок HTTPS
(`listen 443 ssl`, `ssl_protocols TLSv1.2 TLSv1.3`, `root /var/www/devops-site`, `error_page 404 /404.html`).
Полный текст хранится в репозитории: `nginx/devops-site`. Применение: `sudo nginx -t && sudo systemctl reload nginx`.
