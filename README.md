# Proxmox Hosted Workstation

Terraform-конфигурация для развёртывания рабочих станций в Proxmox VE с доступом
к дискретному GPU хоста. Два способа отдать одну и ту же карту:

- **`env/windows`** — полноценная VM с PCI-passthrough через `vfio-pci`
  (`mod/vm` + `proxmox_hardware_mapping_pci`).
- **`env/ubuntu`** — LXC-контейнер, который **разделяет** драйвер ядра хоста и
  получает GPU как набор device-нод (`/dev/nvidia*`, `/dev/dri/*`). Ни OVMF,
  ни vfio, ни Code 43. `mod/ct` создаёт контейнер тем же API-токеном, а
  root@pam-only части (`dev[n]`, `hookscript`, feature-флаги кроме `nesting`)
  доводит `scripts/lxc-ct-passthrough.sh` на ноде — см.
  [root@pam-ограничения LXC](#rootpam-ограничения-lxc).

Оба варианта нацелены на одно железо и **взаимоисключающи** — см.
[Архитектура](#архитектура).

## Содержание

- [Стек](#стек)
- [Архитектура](#архитектура)
- [Структура репозитория](#структура-репозитория)
- [Требования](#требования)
- [Настройка хоста (GPU passthrough)](#настройка-хоста-gpu-passthrough)
- [root@pam-ограничения LXC](#rootpam-ограничения-lxc)
- [Переключение ОС (lock)](#переключение-ос-lock)
- [Секреты и Vault](#секреты-и-vault)
- [Использование](#использование)
- [Переменные](#переменные)
- [Известные ограничения](#известные-ограничения)
- [Заметки](#заметки)

## Стек

```
OS:               Proxmox VE 9.2.2 x86_64
Kernel:           Linux 7.0.2-6-pve
Bootloader:       GRUB
Terraform:        >= 1.16.1
Provider:         bpg/proxmox 0.111.1
State backend:    S3-compatible (MinIO)
Secrets:          HashiCorp Vault
LXC guest:        Ubuntu 26.04 LTS · NVIDIA 580.178.04 (host + CT userspace)
```

Целевое железо (нода `bare-pve`):

```
CPU:  Intel (VT-d поддерживается и включён в BIOS)
GPU:  NVIDIA GeForce GTX 950 — единственная карта, передаётся в VM целиком
      PCI 01:00.0 (VGA) + 01:00.1 (Audio), IOMMU group 1 (чистая изоляция)
Board: ASRock H81M-VG4 R2.0, UEFI P1.50
```

### Whole-workstation passthrough (нода `bare-pve`)

Цель — «как будто хоста нет»: в гость уходят **все** периферийные контроллеры,
хосту остаётся только storage и сеть.

| Устройство                 | PCI            | IOMMU | Маппинг         |
|----------------------------|----------------|-------|------------------|
| GTX 950 (видео + HDMI-звук) | `0000:01:00`   | 1     | `gtx950` (primary/x-vga) |
| USB 3.0 xHCI               | `0000:00:14.0` | 2     | `usb-xhci`       |
| USB 2.0 EHCI #1            | `0000:00:1d.0` | 8     | `usb-ehci1`      |
| USB 2.0 EHCI #2            | `0000:00:1a.0` | 4     | `usb-ehci2`      |
| Onboard audio (Intel HDA)  | `0000:00:1b.0` | 5     | `onboard-audio`  |

Остаётся хосту: SATA-контроллер (IOMMU 9, с него грузится PVE), Realtek NIC
(IOMMU 10, `vmbr0`), MEI. Сеть гостя — виртуальная (`e1000`/`virtio`).

Следствие: локальная консоль хоста (USB-клавиатура на самом хосте) перестаёт
работать — доступ к `bare-pve` только по SSH / IPMI.

## Архитектура

Репозиторий разделён на переиспользуемый модуль и окружения:

- **`mod/vm`** — универсальный модуль VM Proxmox с GPU-passthrough через
  `proxmox_hardware_mapping_pci` (vfio-pci, целые PCI-функции).
- **`mod/ct`** — универсальный модуль LXC-контейнера. GPU не пробрасывается как
  PCI-устройство: контейнер работает на ядре хоста и получает device-ноды
  (`/dev/nvidia*`, `/dev/dri/*`) через `dev[n]:` — их ставит
  `scripts/lxc-ct-passthrough.sh` (root@pam-only), а не токен-terraform.
- **`env/<name>`** — конкретные окружения:
  - `env/windows` — Windows-рабочка (VM, `mod/vm`).
  - `env/ubuntu` — Ubuntu 26.04 **desktop LXC** (`mod/ct`), рабочий стол
    физически на мониторах. LXC (общее ядро хоста), а не VM, потому что
    **анти-читы банят гипервизоры** (по CPUID); LXC для них — не VM.
    Шаблон — обычный minimal-rootfs (не cloud-образ);
    `scripts/lxc-ubuntu-desktop-provision.sh` доставляет **XFCE** + userspace
    NVIDIA + Steam/Discord/Chrome/VS Code.

Каждое окружение хранит своё состояние отдельно (S3 backend, ключ
`<env>/terraform.tfstate`).

### `env/windows` и `env/ubuntu` взаимоисключающи

Это одно и то же железо (GPU + USB-контроллеры `bare-pve`), и его нельзя
одновременно отдать в `vfio-pci` (VM) и в родные драйверы + `nvidia` (LXC):

| | `env/windows` (VM) | `env/ubuntu` (LXC) |
|---|---|---|
| GPU `01:00.0` | `vfio-pci` | `nvidia` |
| HDMI-audio `01:00.1` | `vfio-pci` | `snd_hda_intel` (звук в CT через `/dev/snd`) |
| USB-контроллеры | `vfio-pci` (целые PCI-функции) | `xhci_pci`/`ehci-pci` + `/dev/bus/usb` в CT |
| Первичная подготовка хоста | `scripts/iommu-vfio-setup.sh` | `scripts/lxc-nvidia-host-setup.sh` |
| RAM | 12 ГБ | 12 ГБ |

**Обе гостевые ОС по умолчанию выключены** (`on_boot=false` /
`start_on_boot=false`) — на буте они не гонятся за картой. Жизненным циклом
управляет `scripts/workstation.sh` (см.
[Переключение ОС](#переключение-ос-lock)): единственный триггер — `start`, он
берёт lock, отказывает если запущена другая ОС, живьём перепривязывает
GPU + USB под нужный режим и стартует гостя. Остановка одной ОС **не** запускает
другую.

> **Картинку контейнер отдаёт прямо на физические мониторы.** Хост headless
> (Proxmox сам X не поднимает), поэтому Xorg внутри CT открывает
> `/dev/dri/card0` и сам становится DRM-master. Ни display manager, ни VT:
> systemd-сервис запускает `xinit … X :0 vt7 -keeptty -novtswitch` от
> пользователя. DE — **XFCE** (GNOME требует logind-сессию, которую
> unprivileged LXC не создаёт; Plasma 6.6 на 26.04 — только Wayland). Ввод —
> **evdev** (libinput не работает без udev). См.
> [Известные ограничения → LXC](#lxc-envubuntu).

### Провайдеры

Один экземпляр провайдера `bpg/proxmox`, аутентификация только API-токеном
(`terraform@pve`) — для всех ресурсов, включая `proxmox_hardware_mapping_pci`.
Root (`root@pam`) в API/terraform не используется. Часть конфига LXC Proxmox
запрещает токену на уровне исходников — эти операции делает CLI на ноде (тоже не
через API), см. [root@pam-ограничения LXC](#rootpam-ограничения-lxc).

## Структура репозитория

```
proxmox-hosted-workstation/
├── env/
│   ├── windows/
│   │   ├── backend.tf        # S3 (MinIO) backend
│   │   ├── main.tf           # вызов модуля mod/vm
│   │   ├── providers.tf      # провайдер: API token
│   │   └── variables.tf
│   └── ubuntu/
│       ├── backend.tf        # S3 (MinIO) backend
│       ├── main.tf           # вызов модуля mod/ct
│       ├── providers.tf      # провайдер: API token
│       └── variables.tf
├── mod/
│   ├── vm/
│   │   ├── main.tf           # ресурсы: VM + hardware_mapping_pci
│   │   ├── outputs.tf
│   │   ├── variables.tf
│   │   └── versions.tf       # required_providers
│   └── ct/
│       ├── main.tf           # ресурс: LXC-контейнер (token-safe: nesting only)
│       ├── outputs.tf
│       ├── variables.tf
│       └── versions.tf
├── scripts/
│   ├── iommu-vfio-setup.sh              # хост -> vfio-pci (первичная подготовка, env/windows)
│   ├── lxc-nvidia-host-setup.sh         # хост -> драйвер nvidia 580 (первичная подготовка, env/ubuntu)
│   ├── lxc-ct-passthrough.sh            # на ноде: root@pam-биты CT (dev[n] GPU / features / hookscript / USB)
│   ├── lxc-ubuntu-desktop-provision.sh  # внутри CT: XFCE + userspace NVIDIA + manual-Xorg сессия + Steam/Discord/Chrome/VS Code
│   ├── gpu-arbiter.sh                   # Proxmox pre-start хук: своп GPU/USB + lock (движок)
│   ├── workstation.sh                   # CLI поверх арбитра: status / start --force / --via-reboot
│   ├── workstation-resume.service       # systemd: до-старт после reboot (--via-reboot)
│   ├── install-gpu-arbiter.sh           # разложить хукскрипт + юнит на ноду
│   └── apply-wrapper.sh                 # обёртка terraform: тянет секреты из Vault
├── .gitignore
└── README.md
```

## Требования

- Terraform >= 1.16.1
- Доступ к Proxmox VE API по токену (роль с `Mapping.Modify` + `Mapping.Use`,
  см. [Права токена Terraform](#права-токена-terraform)) — root не требуется
- HashiCorp Vault с настроенными секретами (см. [Секреты и Vault](#секреты-и-vault))
- S3-совместимое хранилище для state (в проекте — MinIO)
- Хост, подготовленный под нужный режим GPU (см.
  [Настройка хоста](#настройка-хоста-gpu-passthrough)): vfio-pci для `env/windows`
  **или** драйвер NVIDIA для `env/ubuntu` (LXC)

## Настройка хоста (GPU passthrough)

Хост можно подготовить под **один** из двух режимов (см.
[взаимоисключающи](#env-windows-и-env-ubuntu-взаимоисключающи)).

### Режим A — vfio-pci (для `env/windows`)

Перед первым использованием GPU passthrough хост должен быть подготовлен:
VT-d/AMD-Vi включены в BIOS, IOMMU включён в ядре, GPU забиндена на `vfio-pci`.

Это делает идемпотентный скрипт `scripts/iommu-vfio-setup.sh`. Запуск удалённо:

```bash
ssh <proxmox-host> 'bash -s' < scripts/iommu-vfio-setup.sh
```

Скрипт автоматически:

1. Определяет вендора CPU (Intel/AMD) и добавляет `intel_iommu=on iommu=pt`
   (или `amd_iommu=on`) в `/etc/default/grub`, если ещё не добавлено.
2. Добавляет модули `vfio`, `vfio_iommu_type1`, `vfio_pci` в `/etc/modules`.
3. Автоопределяет дискретный GPU через `lspci` (VGA-функцию и связанную
   аудио-функцию), биндит обе на `vfio-pci` через `/etc/modprobe.d/vfio.conf`.
   При `WS_FULL_PASSTHROUGH=1` (по умолчанию) туда же добавляет каждый USB-
   контроллер, чья IOMMU-группа состоит только из USB-контроллеров, и onboard
   HDA-контроллер, если он один в своей группе.
4. Добавляет в blacklist конфликтующие драйверы (`nouveau`, `nvidia`,
   `nvidiafb`).
5. Настраивает `softdep`, чтобы `vfio-pci` захватывал устройства раньше
   `nvidia`/`nouveau`/`nvidiafb` (и `xhci_pci`/`ehci_pci`/`snd_hda_intel`
   при full-passthrough).
6. Пересобирает `initramfs` только если конфигурация реально изменилась.
7. Выводит диагностику IOMMU-группы устройства и предупреждает, если группа
   не изолирована чисто (актуально для старых чипсетов без ACS override).
8. В конце печатает сводку изменений и явно указывает, требуется ли reboot.

Скрипт полностью идемпотентен — повторный запуск на уже настроенном хосте
не вносит изменений и явно об этом сообщает.

**Важно:** после первого запуска, если скрипт сообщил `REBOOT REQUIRED`,
хост нужно перезагрузить вручную — скрипт этого не делает сам.

Проверка после перезагрузки:

```bash
dmesg | grep -e IOMMU -e DMAR
lspci -k -s <gpu-pci-addr>   # ожидаем "Kernel driver in use: vfio-pci"
```

### Режим B — драйвер NVIDIA на хосте (для `env/ubuntu` LXC)

`scripts/lxc-nvidia-host-setup.sh` — зеркало `iommu-vfio-setup.sh`, идемпотентный,
**без reboot**. Что делает:

1. Добавляет apt-репо `pve-no-subscription` (enterprise без ключа отдаёт 401 →
   headers ядра недоступны), отключает нерабочие enterprise-репо.
2. Ставит `proxmox-headers-$(uname -r)` + `build-essential` + `dkms`.
3. blacklist: `nouveau` + `nova_core` (in-tree Rust-драйвер NVIDIA — тоже
   перехватил бы карту), **не** `nvidia`. Убирает nvidia-softdep, вычищает
   GPU-`id`ы из `vfio.conf` (USB/audio-`id`ы остаются — они для Windows-VM).
4. Освобождает GPU от vfio-pci в рантайме (откажет, если Windows-VM запущена).
5. Ставит **проприетарный** драйвер NVIDIA (`--dkms`) версии `NVIDIA_VERSION`
   (дефолт `580.178.04` — проверено: собирается и грузится на ядре
   `7.0.2-6-pve`). GTX 950 = Maxwell → **ветка 580 последняя**; open-модули не
   годятся (Turing+).
6. `modules-load.d` + `nvidia-drm modeset=1 fbdev=1` + udev (`nvidia-modprobe`)
   — `/dev/nvidia*`, `/dev/dri/*`, `/dev/fb0` и DRM-коннекторы без X-сервера
   (нужны, чтобы Xorg внутри CT зажёг мониторы). `update-initramfs`.

```bash
ssh bare-pve 'NVIDIA_VERSION=580.178.04 bash -s' < scripts/lxc-nvidia-host-setup.sh
# проверка (reboot не нужен):
nvidia-smi                                   # NVIDIA GeForce GTX 950, 2048 MiB
/var/lib/vz/snippets/gpu-arbiter.sh status   # host mode -> ubuntu
```

Дальше — полный порядок в
[Установка Ubuntu с нуля (LXC)](#установка-ubuntu-с-нуля-lxc). Userspace-половина
того же драйвера ставится внутри CT (`--no-kernel-module`, версия обязана
совпадать с хостом).

> Разовая подготовка. Дальнейшие переключения vfio-pci ↔ nvidia — уже
> `gpu-arbiter.sh` / `workstation.sh`, живьём, без reboot.

### PCI hardware mapping в Proxmox (режим A)

Каждое устройство передаётся через отдельный `proxmox_hardware_mapping_pci`.
Модуль строит их из списка `var.passthrough` (`for_each` по `name`), по одной
записи `map` **на ноду**:

```hcl
{
  node         = "bare-pve"
  path         = "0000:01:00"   # адрес БЕЗ функции -> пробрасываются все функции
  id           = "10de:1402"     # vendor:device основной функции
  iommu_group  = 1               # номер IOMMU-группы
  subsystem_id = "10de:1402"     # subsystem vendor:device
}
```

**Ключевой момент:** `map` — это список альтернатив *по нодам кластера*, а не
список функций устройства. Две записи для одной ноды (`…:00.0` и `…:00.1`)
приводят к тому, что Proxmox пробрасывает только первую — так и получился
«чёрный монитор»: в гость уходила лишь HDMI-аудио функция. Правильно —
**одна** запись с `path = "0000:01:00"` (без `.0`), это форма «all functions».

Узнать значения:

```bash
lspci -nn | grep -i vga                                    # path + id
lspci -vnn -s <addr> | grep -i subsystem                   # subsystem_id
readlink -f /sys/bus/pci/devices/0000:<addr>/iommu_group   # iommu_group (последний сегмент пути)
```

## root@pam-ограничения LXC

`hardware_mapping_pci` (для VM) на токене работает — [Права токена
Terraform](#права-токена-terraform) это разбирает: миф из README провайдера про
«нужен root» устарел. **Для LXC история другая и это не миф.** В
`pve-container`, `src/PVE/LXC.pm` → `check_ct_modify_config_perm`:

```perl
return 1 if $authuser eq 'root@pam';
...
} elsif ($opt =~ m/^dev\d+$/) {
    raise_perm_exc("configuring device passthrough is only allowed for root\@pam");
...
} elsif ($opt eq 'hookscript') {
    raise_perm_exc("changing the hookscript is only allowed for root\@pam");
```

— `raise_perm_exc` **без проверки привилегий**. Ни одна роль/ACL не даёт токену:

| ключ конфига CT | кто может |
|---|---|
| `dev[n]:` (device passthrough) | только `root@pam` |
| `hookscript:` | только `root@pam` |
| `features:` — всё кроме `nesting` (`keyctl`, `fuse`, `mount`) | только `root@pam` |
| `features: nesting=1` (на **unprivileged** CT) | токен + `VM.Allocate` ✓ |
| rootfs, net, memory, cores, tags, … | токен ✓ |

Варианты обхода у сообщества: (а) токен `root@pam!...` с `privsep=0` — тогда
`$authuser eq 'root@pam'` и `return 1` пропускает всё; (б) конфиг на ноде под
root (`pct set` в CLI работает как `root@pam`; либо правка
`/etc/pve/lxc/<id>.conf` напрямую — классический до-8.2 способ).

**Этот проект — (б).** `terraform` тем же токеном, что и VM, создаёт CT и ставит
`nesting`; `scripts/lxc-ct-passthrough.sh` на ноде доводит остальное:

```bash
ssh bare-pve scripts/lxc-ct-passthrough.sh <ctid>
```

- GPU-ноды → **нативный** `pct set --devN` (Proxmox сам делает cgroup allow +
  mount + права ноды в unprivileged CT);
- `pct set --features nesting=1,keyctl=1,fuse=1`;
- `pct set --hookscript local:snippets/gpu-arbiter.sh`;
- `/dev/bus/usb` + `/dev/input` + `/dev/snd` (у них нет `dev[n]`-аналога) —
  сырыми `lxc.mount.entry` в конфиг + host-udev `MODE="0666"`.

Повторять после `terraform apply`, который пересоздаёт CT.

## Переключение ОС (lock)

`env/windows` (VM) и `env/ubuntu` (LXC) делят один GPU и один комплект
USB-контроллеров. Механизм переключения — **нативный хукскрипт Proxmox**
`scripts/gpu-arbiter.sh`, повешенный на оба гостя как `pre-start`.
`scripts/workstation.sh` — CLI-обёртка сверху.

### Модель

- Обе гостевые ОС по умолчанию **выключены** (`on_boot=false` в `mod/vm`,
  `start_on_boot=false` в `mod/ct`). На буте гонки за карту нет.
- Остановка одной ОС **никогда** не запускает другую. Ничего не сцепляется
  автоматически (`post-stop` — no-op). Валидное состояние — «обе выключены».
- Любой запуск гостя — `qm start`, `pct start`, кнопка Start в веб-морде,
  API, routine — дёргает `pre-start` хук, который:
  1. берёт `flock` (`/run/lock/gpu-arbiter.lock`);
  2. определяет себя по `/etc/pve/qemu-server/<id>.conf` (→ windows/vfio) или
     `/etc/pve/lxc/<id>.conf` (→ ubuntu/nvidia);
  3. если запущен **другой** гость — `exit 1` → **Proxmox отменяет старт**
     (это и есть lock: нативная отмена pre-start);
  4. если драйвер GPU не соответствует режиму цели — **живьём** перепривязывает
     GPU + HDMI-audio + USB-функции (`driver_override` + `unbind` +
     `drivers_probe`), для ubuntu ждёт появления `/dev/nvidia*`, `/dev/dri/*`;
  5. `exit 0` → Proxmox запускает гостя.
- Лог всех действий — `/var/log/gpu-arbiter.log` (иначе провал хука виден
  только как `Failed to run lxc.hook.pre-start`).

### Установка (разово на ноду)

Хукскрипт не заливается терраформом дважды: (1) bpg умеет `snippets` только по
SSH ([#2112](https://github.com/bpg/terraform-provider-proxmox/issues/2112)
`wontfix`), (2) `hookscript:` в конфиге CT — root@pam-only. Кладём вручную:

```bash
scp scripts/gpu-arbiter.sh scripts/workstation.sh scripts/install-gpu-arbiter.sh \
    scripts/workstation-resume.service scripts/lxc-ct-passthrough.sh root@bare-pve:/root/
ssh root@bare-pve 'cd /root && bash install-gpu-arbiter.sh'
```

`scripts/lxc-ct-passthrough.sh <ctid>` (см.
[root@pam-ограничения LXC](#rootpam-ограничения-lxc)) делает
`pct set <ctid> --hookscript local:snippets/gpu-arbiter.sh` заодно с
device-нодами. Для Windows-VM — по желанию:
`qm set <winid> --hookscript local:snippets/gpu-arbiter.sh` (или просто
`workstation.sh` для винды).

### Команды

```bash
# просто через Proxmox — хук всё сделает сам:
pct start <ctid>            # свопнёт GPU на nvidia (если надо) и стартанёт CT
qm  start <winid>           # свопнёт на vfio-pci; откажет, если CT запущен

# CLI-обёртка (status / --force / --via-reboot):
ssh bare-pve /usr/local/sbin/workstation.sh status
ssh bare-pve /usr/local/sbin/workstation.sh start windows --force  # погасить ubuntu -> своп -> qm start
ssh bare-pve /usr/local/sbin/workstation.sh stop                   # погасить всё, НИЧЕГО не стартовать
ssh bare-pve /usr/local/sbin/workstation.sh switch ubuntu          # только своп (обе ОС должны стоять)
```

Типичный цикл:

```
stop windows  ->  (карта осталась на vfio-pci)  ->  start ubuntu
   |                                                      |
   |  pre-start хук: host=windows != ubuntu, другой       |
   |  гость не запущен -> GPU vfio-pci -> nvidia,          |
   v  USB -> xhci_pci, ждём /dev/nvidia* -> pct стартует   v
 обе off  <----------------  stop ubuntu  <----------------  ubuntu up
```

### Живой своп vs. reboot

Перепривязка `vfio-pci <-> nvidia` в рантайме работает, когда устройство никто
не держит (другой гость остановлен — хук это уже проверил; `nvidia-persistenced`
хук гасит сам). Если всё же занято — хук делает `exit 1` (старт отменён) с
подсказкой; резерв — через перезагрузку:

```bash
ssh bare-pve /usr/local/sbin/workstation.sh switch ubuntu --via-reboot
```

Пишет `/var/lib/workstation/pending-start`, ребутит ноду; после бута (карту ещё
никто не держит) `workstation-resume.service` до-выполняет `start ubuntu`.
Юнит ставит `install-gpu-arbiter.sh`.

> Cluster-маппинги `proxmox_hardware_mapping_pci` при свопе **не трогаются** —
> это просто метаданные, Proxmox сверяет их только при старте VM. «Свап
> маппинга» на практике = смена драйвера PCI-функций на хосте.

## Секреты и Vault

Секреты не хранятся в репозитории (`.gitignore` исключает `terraform.tfvars`
и файлы состояния). Используется `scripts/apply-wrapper.sh`, который перед
`terraform apply`/`plan` подтягивает из Vault:

- `proxmox/terraform-provider` → `TF_VAR_proxmox_api_token`
- `minio/credentials` → `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY`
  (для S3 backend)

Использование обёртки:

```bash
source scripts/apply-wrapper.sh   # подключает функцию terraform() с автоподгрузкой секретов
vault login -method=userpass username=<you>
terraform -chdir=env/windows apply
```

## Использование

Terraform только **создаёт** гостей (обоих можно держать созданными
одновременно — они выключены). Запуск/остановку/своп железа делает
`scripts/workstation.sh` — см. [Переключение ОС](#переключение-ос-lock).

```bash
source scripts/apply-wrapper.sh
vault login -method=userpass username=<you>

terraform -chdir=env/windows init && terraform -chdir=env/windows apply   # создать VM
terraform -chdir=env/ubuntu  init && terraform -chdir=env/ubuntu  apply   # создать LXC

ssh bare-pve scripts/workstation.sh start windows    # запустить одну из них
```

`env/ubuntu` при первом `apply` **пересоздаёт** ресурс (был
`proxmox_virtual_environment_vm`, стал `proxmox_virtual_environment_container`
в том же state-ключе `ubuntu/terraform.tfstate`) — `moved`-блок между разными
типами ресурсов невозможен, старую VM Terraform снесёт и создаст контейнер.

### Права токена Terraform

Официальный README провайдера (bpg/proxmox, секция Known Issues) утверждает,
что `hardware_mapping_pci` требует `root@pam` из-за IOMMU-специфики Proxmox
API. На практике (провайдер `>= 0.111.1`, PVE `9.2.11`) это устарело: и
создание, и использование маппинга работают на обычном API-токене — нужны
только `Mapping.Modify` (создание/изменение маппинга) и `Mapping.Use`
(привязка уже созданного маппинга к `hostpci` в VM). Роль на форуме Proxmox
подтверждает разработчик (`Mapping.Modify`/`Mapping.Use` — рядовые
привилегии, root не требуется концептуально); в актуальной странице
`docs/` (Authentication → SSH Connection) `hardware_mapping_pci` тоже нет в
списке операций, требующих SSH/root.

Проверено эмпирически в этом проекте: `terraform apply`/`destroy` на
изолированном тестовом ресурсе `proxmox_hardware_mapping_pci` через один
токен (без root) — create и destroy оба прошли успешно.

Право добавляется к уже существующей роли (append — `pveum role modify`
перезаписывает список целиком, так что нужно передать весь текущий набор
плюс новые права одной строкой):

```bash
pveum role modify TerraformProv --privs "<существующие-права-через-запятую>,Mapping.Modify,Mapping.Use"
```

Проверить, что применилось:

```bash
pvesh get /access/roles --output-format json-pretty | grep -A3 '"roleid" : "TerraformProv"'
```

## Переменные

### `env/windows`

| Переменная               | Тип         | По умолчанию               | Описание                                  |
|---------------------------|-------------|-----------------------------|---------------------------------------------|
| `proxmox_node`             | string      | `bare-pve`                  | Целевая нода Proxmox                        |
| `proxmox_endpoints`        | map(string) | —                            | Карта `нода → endpoint API`                 |
| `proxmox_insecure`         | bool        | `true`                       | Пропускать проверку TLS-сертификата         |
| `proxmox_api_token`        | string      | — (sensitive)                | API-токен `terraform@pve`                   |
| `vm_name`                  | string      | `windows-workstation`        | Имя VM                                      |
| `cores`                    | number      | `2`                          | Количество ядер CPU                         |
| `memory`                   | number      | `4096`                       | RAM, МБ                                     |
| `mac`                      | string      | `BC:24:11:F9:5D:82`          | MAC-адрес сетевого интерфейса               |
| `os_type`                  | string      | `win10`                      | Тип гостевой ОС (`win10`, `win11`, `l26`)   |
| `agent_enabled`            | bool        | `false`                      | QEMU guest agent (включать после установки virtio-тулзов) |
| `iso_file_id`              | string      | `local:iso/Win10_22H2_...`   | Volume ID установочного ISO                 |

`env/windows` передаёт в `mod/vm` `on_boot = false` — стартом управляет
`scripts/workstation.sh`, автозапуска на буте нет.

### `env/ubuntu` (LXC)

| Переменная          | Тип          | По умолчанию                                            | Описание                                       |
|---------------------|--------------|--------------------------------------------------------|------------------------------------------------|
| `proxmox_node`      | string       | `bare-pve`                                              | Целевая нода Proxmox                            |
| `proxmox_endpoints` | map(string)  | —                                                      | Карта `нода → endpoint API`                     |
| `proxmox_insecure`  | bool         | `true`                                                  | Пропускать проверку TLS-сертификата             |
| `proxmox_api_token` | string       | — (sensitive)                                           | API-токен `terraform@pve`                       |
| `ct_name`           | string       | `ubuntu-workstation`                                    | Hostname контейнера                             |
| `cores`             | number       | `4`                                                    | Ядра CPU                                        |
| `memory`            | number       | `12288`                                                 | RAM, МиБ (как у `env/windows` — вместе не запускаются) |
| `swap`              | number       | `0`                                                    | Swap, МиБ                                       |
| `unprivileged`      | bool         | `true`                                                  | Unprivileged CT (GPU-ноды приходят с `mode=0666`) |
| `template_file_id`  | string       | `local:vztmpl/ubuntu-26.04-standard_26.04-1_amd64.tar.zst` | LXC-шаблон (minimal rootfs, **не** cloud); `pveam download local <...>` |
| `disk_size`         | number       | `40`                                                   | rootfs, ГиБ                                     |
| `mac`               | string       | `BC:24:11:AB:CD:01`                                     | MAC (отличается от windows)                     |
| `ipv4_address`      | string       | `dhcp`                                                  | `dhcp` или статический CIDR                     |
| `ipv4_gateway`      | string       | `null`                                                  | Шлюз для статического адреса                    |
| `ssh_public_keys`   | list(string) | `[]`                                                    | Ключи root внутри CT                            |

`env/ubuntu` жёстко задаёт `start_on_boot = false` и `nesting`. GPU-ноды,
`hookscript`, `keyctl`/`fuse`, USB/input/sound — всё через
`scripts/lxc-ct-passthrough.sh` на ноде (root@pam-only, см.
[root@pam-ограничения LXC](#rootpam-ограничения-lxc)).

### `mod/ct`

| Переменная            | Тип          | По умолчанию | Описание                                                        |
|-----------------------|--------------|--------------|----------------------------------------------------------------|
| `name`                | string       | —            | Hostname / имя CT                                               |
| `node_name`           | string       | —            | Нода Proxmox                                                    |
| `vm_id`               | number       | `null`       | Явный CTID (`null` — следующий свободный)                       |
| `cores` / `memory` / `swap` | number | `2` / `2048` / `0` | Ресурсы                                                  |
| `unprivileged`        | bool         | `true`       | Unprivileged CT                                                 |
| `template_file_id`    | string       | —            | Volume id LXC-шаблона                                           |
| `os_type`             | string       | `ubuntu`     | Дистрибутив для CT-тулинга Proxmox                              |
| `datastore_id_rootfs` | string       | `local-lvm`  | Datastore под rootfs                                            |
| `disk_size`           | number       | `32`         | rootfs, ГиБ                                                     |
| `network_bridge` / `mac` | string    | `vmbr0` / `null` | Сеть                                                       |
| `ipv4_address` / `ipv4_gateway` | string | `dhcp` / `null` | IPv4                                                    |
| `nameservers` / `search_domain` | list(string) / string | `null` | DNS (`null` — наследовать от ноды)               |
| `nesting`             | bool         | `true`       | `features.nesting` — **единственный** feature-флаг, доступный токену (на unprivileged CT). keyctl/fuse/mount — root@pam, через `lxc-ct-passthrough.sh` |
| `started`             | bool         | `true`       | Запустить ли CT после create. В `ignore_changes` — только на первый `apply`, дальше run-state у арбитра |
| `start_on_boot`       | bool         | `true`       | Автостарт на буте ноды                                          |
| `startup_order`       | number       | `null`       | Слот в порядке загрузки                                         |
| `tags`                | list(string) | `[]`         | Теги CT                                                         |
| `ssh_public_keys` / `password` | list(string) / string | `[]` / `null` | Доступ root в CT                            |
| `mount_points`        | list(object) | `[]`         | Доп. mount points. Поля: `volume`, `path`, `size`, `read_only`, `acl`, `backup`, `mount_options` |

### `mod/vm`

| Переменная           | Тип                                  | По умолчанию   | Описание                                        |
|-----------------------|---------------------------------------|-----------------|---------------------------------------------------|
| `name`                | string                                 | —               | Имя VM                                            |
| `node_name`           | string                                 | —               | Нода Proxmox                                      |
| `cores`               | number                                 | `1`             | Количество ядер                                   |
| `memory`              | number                                 | `512`           | RAM, МБ                                           |
| `cpu_type`            | string                                 | `host`          | Модель CPU (`host` для passthrough-рабочки)       |
| `agent_enabled`       | bool                                   | `false`         | Канал QEMU guest agent                            |
| `on_boot`             | bool                                   | `true`          | Автозапуск на буте (`env/windows` ставит `false` — стартом рулит арбитр) |
| `hook_script_file_id` | string                                 | `null`          | Volume id хукскрипта. Тоже root@pam-only для VM — `qm set <winid> --hookscript` на ноде |
| `datastore_id_disk`   | string                                 | `local-lvm`     | Datastore для дисков VM                           |
| `disk_interface`      | string                                 | `sata0`         | Интерфейс основного диска (`sata0`/`scsi0`)       |
| `disk_size`           | number                                 | `10`            | Размер диска, ГБ                                  |
| `cdrom_interface`     | string                                 | `ide3`          | Слот установочного ISO                            |
| `iso_file_id`         | string                                 | `null`          | Volume ID ISO (`null` — пустой привод)            |
| `network_bridge`      | string                                 | `vmbr0`         | Сетевой мост                                      |
| `mac`                 | string                                 | `BC:24:11:...`  | MAC-адрес                                         |
| `network_model`       | string                                 | `e1000`         | Модель сетевой карты                              |
| `os_type`             | string                                 | `win10`         | `win10`/`win11` — Windows, `l26` — Linux          |
| `passthrough`         | list(object)                           | `[]`            | Список целых PCI-устройств → `hostpci0..N`. Поля: `name`, `path` (без функции = все функции), `id`, `subsystem_id`, `iommu_group`, `primary_gpu`, `rom_file` |
| `usb_devices`         | list(object)                           | `[]`            | Отдельные USB-устройства по id/порту (запасной вариант, если не пробрасывается весь контроллер) |

`boot_order` больше не переменная — выводится как `[cdrom_interface, disk_interface]`.

## Известные ограничения

- **`map` — это альтернативы по нодам, а не по функциям устройства** — одна
  запись на ноду; `path` без функции (`0000:01:00`) = «all functions». Две
  записи на одну ноду → Proxmox берёт только первую (был баг «чёрный монитор»:
  пробрасывалась лишь `01:00.1` HDMI-аудио).
- **`cdrom.interface` не гарантирует фактическое размещение** — провайдер
  может сам выбрать другой IDE-слот (в текущей конфигурации фактически
  используется `ide3`, а не запрошенный `ide2`). После `apply` необходимо
  сверить `/etc/pve/qemu-server/<vmid>.conf` и синхронизировать `boot_order`
  с реальным слотом — иначе OVMF не найдёт загрузочное устройство
  (`BdsDxe: No bootable option or device was found`).
- **Без явного `efi_disk` — временный efivars** — Proxmox предупреждает
  `WARN: no efidisk configured!` и использует непостоянный NVRAM, что ломает
  сохранение UEFI boot-записей между рестартами. Блок `efi_disk` в модуле
  обязателен для GPU passthrough конфигураций на OVMF.
- **Первый холодный старт с пустым `efidisk0`** требует ручного выбора
  загрузочного устройства через OVMF Boot Manager Menu (сообщение
  `Press any key to enter the Boot Manager Menu`) — это разовое действие,
  после установки ОС NVRAM запоминает boot-запись.
- **`x-vga=1` отключает графическую VNC-консоль Proxmox** — при передаче
  всей карты гостю встроенная веб-консоль автоматически переключается на
  serial redirect (при наличии `serial_device {}` в конфиге VM). Это
  ожидаемое поведение, не баг.
- **GTX 950-эпохи железо на бюджетных платах** может не иметь в BIOS опций
  Above 4G Decoding / Resizable BAR — не блокер.
- **Монитор тёмный на экране OVMF** (primary GPU, `x-vga=1`) — подтверждено на
  GTX 950: `dmesg` даёт `vfio-pci 0000:01:00.0: No more image in the PCI ROM`,
  а sysfs-дамп ROM содержит **только legacy-образ** (codetype 0, ~58 КБ), без
  UEFI GOP. OVMF без GOP не может зажечь монитор до загрузки ОС — но **как
  только стартует драйвер (nouveau на Linux / NVIDIA на Windows), монитор
  загорается**, оба выхода карты, 144 Гц, без Code 43. Проверено рабочим.
  - Чтобы монитор работал уже на экране POST/OVMF/GRUB: нужен полный UEFI-vBIOS
    (legacy + EFI-образ). Скачать под конкретную карту (`10de:1402`) с
    TechPowerup, при наличии проверить/срезать NVIDIA-хедер, положить в
    `/usr/share/kvm/gtx950.rom`, `rom_file = "gtx950.rom"` в записи `passthrough`.

### LXC (`env/ubuntu`)

- **root@pam-only части конфига CT** — `dev[n]`, `hookscript`, feature-флаги
  кроме `nesting`. Токен получает 403 (hardcoded в `pve-container`, не роль).
  Делает `scripts/lxc-ct-passthrough.sh` на ноде. См.
  [отдельный раздел](#rootpam-ограничения-lxc).
- **Версия драйвера хост == CT.** Модуль ядра `nvidia` (580.178.04) на хосте, в
  контейнер идёт только userspace (`--no-kernel-module`). Разъезд →
  `nvidia-smi` в CT: `Failed to initialize NVML: Driver/library version
  mismatch`. Обновлять хост и `lxc-ubuntu-desktop-provision.sh` синхронно.
- **Ядро PVE 9.2 = `7.0.2-6-pve`** (Proxmox перескочил на своё «7.0»). NVIDIA
  580.178.04 `.run --dkms` собирается и грузится (проверено). Более старые 580.x
  могут не собраться — брать свежий билд.
- **`nova_core`** (in-tree Rust-драйвер NVIDIA в ядре 7.0) тоже перехватил бы
  карту — `lxc-nvidia-host-setup.sh` его блэклистит вместе с `nouveau`.
- **`nvidia-persistenced`** этот `.run` не ставит юнитом — ноды создают udev +
  `modules-load.d` + `nvidia-modprobe` из `lxc-nvidia-host-setup.sh`.
- **Физический монитор из контейнера — работает.** Хост headless → DRM-master
  свободен, Xorg в CT его берёт. Ключевое:
  - `lxc-nvidia-host-setup.sh`: `nvidia-drm modeset=1 fbdev=1` → `/dev/fb0` +
    DRM-коннекторы.
  - `lxc-ct-passthrough.sh` seat-блок: `/dev/fb0`, `/dev/tty7` (host-tty, ноду
    хост не использует), `/dev/vga_arbiter`, cgroup `c 4/29/226`. **НЕ**
    `/dev/console` и `/dev/tty0` (LXC ими владеет → `sync_wait: 34`), **НЕ**
    bind `/dev/dri` каталогом (autodev-mknod `card0` → «File exists», hook
    status 17).
  - Ни display manager, ни VT: `workstation-session.service` (`User=`,
    `TTYPath=/dev/tty7`) → `xinit … X :0 vt7 -keeptty -nolisten tcp
    -novtswitch`. `Xwrapper.config` → `needs_root_rights=yes`.
    `loginctl enable-linger <user>` для `systemd --user`.
  - **XFCE**, не GNOME/Plasma: GNOME требует logind-сессию (в unprivileged CT
    `CreateSession` падает), Plasma 6.6 на 26.04 — Wayland-only.
  - Ввод — **evdev**, не libinput (тот не стартует без udev, которого в CT
    нет). `gen-xorg-input` строит явные `InputDevice` из
    `/proc/bus/input/devices` перед каждым стартом X.
  - Раскладку мониторов (лево/право, Гц) один раз в XFCE «Дисплей» — сохраняется.
- **USB-контроллер целиком в LXC — нельзя** (PCI, только VM). Эквивалент:
  bind-mount `/dev/bus/usb` + `/dev/input` + `/dev/snd` + cgroup major
  189/13/116/166 → все устройства, hotplug. + host-udev `MODE="0666"` (иначе
  unprivileged CT видит ноды как `nobody:nogroup`).
- **Смена VM → LXC пересоздаёт ресурс** (разные типы, `moved` невозможен). У
  `env/ubuntu` стейт был пустой (VM-версию не применяли), так что 1 to add.

## Установка Windows с нуля

OVMF без GOP => на экране установщика ничего не видно при `x-vga=1`. Порядок:

1. `terraform -chdir=env/windows apply -var gpu_primary=false` — эмулированный
   std VGA остаётся основным, работает веб-консоль Proxmox.
2. Свежий `efidisk0` => OVMF висит в Boot Manager. Выбрать `UEFI QEMU DVD-ROM`
   один раз — через веб-консоль или по serial:
   `socat - UNIX-CONNECT:/var/run/qemu-server/<vmid>.serial0` (Enter → выбор →
   пробел на «Press any key to boot from CD»).
3. Windows: диск ≥ 60 ГБ (Setup отвергает 10 ГБ). Для локальной учётки без
   пароля на 22H2 — отрубить сеть на шаге OOBE (`qm monitor` → `set_link net0
   off`), после десктопа вернуть (`set_link net0 on`).
4. Поставить драйвер NVIDIA (например
   `curl.exe -L -o c:\nv.exe https://us.download.nvidia.com/Windows/580.97/580.97-desktop-win10-win11-64bit-international-dch-whql.exe`
   → `c:\nv.exe -s -noreboot`; 580.xx — последняя ветка для Maxwell).
5. `terraform -chdir=env/windows apply` (дефолт `gpu_primary = true`),
   `qm stop <vmid> && qm start <vmid>` — вывод уходит на монитор.

## Установка Ubuntu с нуля (LXC)

```bash
# 0. Хост -> режим nvidia (разово, без reboot)
ssh bare-pve 'NVIDIA_VERSION=580.178.04 bash -s' < scripts/lxc-nvidia-host-setup.sh
ssh bare-pve nvidia-smi   # NVIDIA GeForce GTX 950

# 1. Арбитр + скрипты на ноду (разово)
scp scripts/{gpu-arbiter,workstation,install-gpu-arbiter,lxc-ct-passthrough,lxc-ubuntu-desktop-provision}.sh \
    scripts/workstation-resume.service root@bare-pve:/root/
ssh bare-pve 'cd /root && bash install-gpu-arbiter.sh'

# 2. Шаблон (обычный minimal rootfs, не cloud)
ssh bare-pve 'pveam update && pveam download local ubuntu-26.04-standard_26.04-1_amd64.tar.zst'

# 3. Terraform создаёт CT (токеном; только nesting из feature-флагов)
source scripts/apply-wrapper.sh && terraform -chdir=env/ubuntu apply

# 4. root@pam-биты на ноде: GPU dev[n] + features + hookscript + USB
ssh bare-pve 'bash /root/lxc-ct-passthrough.sh <ctid>'

# 5. Рестарт -> pre-start хук проверит режим и стартанёт
ssh bare-pve 'pct stop <ctid>; pct start <ctid>'   # или: workstation.sh start ubuntu

# 6. Провижн десктопа внутри CT (~20-30 мин): XFCE + userspace NVIDIA +
#    manual-Xorg сессия + Steam/Discord/Chrome/VS Code
ssh bare-pve 'pct push <ctid> /root/lxc-ubuntu-desktop-provision.sh /root/provision.sh
              pct exec <ctid> -- env NVIDIA_VERSION=580.178.04 SEAT_USER=<you> bash /root/provision.sh'

# 7. Рестарт CT -> мониторы загораются с XFCE
ssh bare-pve 'workstation.sh start ubuntu'
ssh bare-pve 'pct exec <ctid> -- nvidia-smi'
```

Мониторы загораются сразу после старта CT (`workstation-session.service`).
Первый раз — разложить экраны/Гц в XFCE «Дисплей» (сохраняется). Пароль
пользователя по умолчанию — `workstation`, поменять.

## Code 43

Proxmox сам добавляет `kvm=off` + `hv_vendor_id` при `ostype = win10/win11`
(видно в `qm showcmd`) — для Maxwell/Pascal этого хватает, драйвер 580.97
ставится без Code 43. Если всё же вылезет —
`qm set <vmid> -args "-cpu host,kvm=off,hv_vendor_id=whatever,-hypervisor"`
(bpg-провайдер raw-`args` не поддерживает) или через hookscript.

## Заметки

- Proxmox endpoint не обязательно должен соответствовать ноде, на которой
  будет расположен ресурс — целевая нода указывается явно через `node_name`
  в каждом ресурсе.
- Ресурс `proxmox_virtual_environment_hardware_mapping_pci` **deprecated**
  в версии 0.111.1 — используйте `proxmox_hardware_mapping_pci`.
