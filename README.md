# Proxmox Hosted Workstation

Terraform-конфигурация для развёртывания рабочих станций в Proxmox VE с GPU
passthrough. Цель — сидеть физически за столом: картинка на мониторах, клава /
мышь / USB проброшены в гостя, в Windows или Ubuntu. Две **взаимоисключающие**
VM (`env/windows`, `env/ubuntu`) на одном железе; запуск одной, пока работает
другая, блокируется нативным хукскриптом Proxmox.

## Содержание

- [Стек](#стек)
- [Архитектура](#архитектура)
- [Структура репозитория](#структура-репозитория)
- [Требования](#требования)
- [Настройка хоста (GPU passthrough)](#настройка-хоста-gpu-passthrough)
- [Переключение ОС (lock)](#переключение-ос-lock)
- [Секреты и Vault](#секреты-и-vault)
- [Использование](#использование)
- [Переменные](#переменные)
- [Известные ограничения](#известные-ограничения)
- [Заметки](#заметки)

## Стек

```
OS:               Proxmox VE 9.2.2 x86_64
Kernel:           Linux 7.0.2-6-pve   (Proxmox перескочил на своё «7.0»)
Bootloader:       GRUB
Terraform:        >= 1.16.1
Provider:         bpg/proxmox 0.111.1
State backend:    S3-compatible (MinIO)
Secrets:          HashiCorp Vault
Guests:           Windows 10 22H2 · Ubuntu 26.04 desktop
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

- **`mod/vm`** — универсальный модуль виртуальной машины Proxmox с опциональным
  GPU passthrough через `proxmox_hardware_mapping_pci`.
- **`env/<name>`** — конкретные окружения, вызывают `mod/vm` с нужными
  параметрами:
  - `env/windows` — Windows-рабочка. **Владеет** cluster PCI-маппингами
    (`manage_mappings = true`).
  - `env/ubuntu` — Ubuntu 26.04 desktop. Те же 5 устройств, но
    `manage_mappings = false` — только **привязывает** маппинги по имени.

Каждое окружение хранит своё состояние отдельно (S3 backend, ключ
`<env>/terraform.tfstate`).

**`env/windows` и `env/ubuntu` взаимоисключающие** — одно железо (GPU + USB +
звук). Обе VM с `on_boot = false`, одновременно **не запускаются**: хукскрипт
`scripts/gpu-arbiter.sh` на `pre-start` отменяет старт, если другая VM
работает — см. [Переключение ОС](#переключение-ос-lock). Обе создаются
Terraform одновременно и просто лежат выключенными; `terraform destroy` для
переключения не нужен.

> `env/ubuntu` раньше пробовали как GPU-sharing LXC (ветка истории) — контейнер
> не может стать DRM-master и зажечь физический монитор из unprivileged-окружения,
> плюс `dev[n]`/`hookscript`/feature-флаги в LXC — root@pam-only. Для «сидеть за
> столом» подходит только VM с полным passthrough.

### Провайдеры

Один экземпляр провайдера `bpg/proxmox`, аутентификация только API-токеном
(`terraform@pve`) — для всех ресурсов, включая `proxmox_hardware_mapping_pci`.
Root (`root@pam`) в проекте не используется вообще. Подробности и как это
проверить — см. [Права токена Terraform](#права-токена-terraform).

## Структура репозитория

```
proxmox-hosted-workstation/
├── env/
│   ├── windows/
│   │   ├── backend.tf        # S3 (MinIO) backend
│   │   ├── main.tf           # вызов модуля mod/vm
│   │   ├── providers.tf      # провайдер: API token
│   │   └── variables.tf
│   └── ubuntu/               # то же самое, manage_mappings=false, gpu_primary=true
│       ├── backend.tf
│       ├── main.tf
│       ├── providers.tf
│       └── variables.tf
├── mod/
│   └── vm/
│       ├── main.tf           # ресурсы: VM + hardware_mapping_pci
│       ├── outputs.tf
│       ├── variables.tf
│       └── versions.tf       # required_providers
├── scripts/
│   ├── iommu-vfio-setup.sh          # идемпотентная настройка хоста под vfio-pci
│   ├── gpu-arbiter.sh               # Proxmox pre-start хук: «одна ОС за раз» (движок)
│   ├── workstation.sh              # CLI поверх арбитра: status / start --force / stop
│   ├── workstation-resume.service   # systemd: до-старт после reboot (--via-reboot)
│   ├── install-gpu-arbiter.sh       # разложить хукскрипт + повесить на обе VM
│   ├── ubuntu-guest-provision.sh    # внутри Ubuntu VM: NVIDIA + Steam/Discord/VS Code
│   └── apply-wrapper.sh             # обёртка terraform: тянет секреты из Vault
├── .gitignore
└── README.md
```

## Требования

- Terraform >= 1.16.1
- Доступ к Proxmox VE API по токену (роль с `Mapping.Modify` + `Mapping.Use`,
  см. [Права токена Terraform](#права-токена-terraform)) — root не требуется
- HashiCorp Vault с настроенными секретами (см. [Секреты и Vault](#секреты-и-vault))
- S3-совместимое хранилище для state (в проекте — MinIO)
- Для GPU passthrough: хост с настроенным IOMMU/VFIO (см. ниже)

## Настройка хоста (GPU passthrough)

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
   `nvidiafb`, `nova_core` — последний это in-tree Rust-драйвер NVIDIA в
   ядре 7.0+, он тоже перехватывает карту).
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

### PCI hardware mapping в Proxmox

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

## Переключение ОС (lock)

Обе VM делят один GPU и один комплект USB-контроллеров, обе с `on_boot = false`.
Интерлок «одна ОС за раз» — **нативный хукскрипт Proxmox**
`scripts/gpu-arbiter.sh`, повешенный на обе VM как `pre-start`.

### Модель

- Обе VM создаются Terraform и лежат выключенными. `terraform destroy` для
  переключения не нужен.
- Любой запуск — `qm start`, кнопка Start в веб-морде, API — дёргает
  `pre-start` хук: `flock`; если запущена **другая** workstation-VM → `exit 1`
  → **Proxmox отменяет старт**. Иначе проверяет, что GPU+USB на `vfio-pci`
  (страховка), и пускает.
- Остановка одной VM другую **не** запускает (`post-*` — no-op).
- Драйверы на хосте **не переключаются** — обе VM хотят `vfio-pci`, хост всегда
  в одном режиме (`iommu-vfio-setup.sh`). Лог: `/var/log/gpu-arbiter.log`.

### Установка (разово на ноду)

Хукскрипт не из Terraform (bpg грузит snippets только по SSH; `hookscript:` в
конфиге гостя — root@pam-only). Ставится на ноде:

```bash
scp scripts/gpu-arbiter.sh scripts/workstation.sh scripts/install-gpu-arbiter.sh \
    scripts/workstation-resume.service scripts/ubuntu-guest-provision.sh root@bare-pve:/root/
ssh root@bare-pve 'cd /root && bash install-gpu-arbiter.sh'   # кладёт snippet + qm set --hookscript на обе VM
```

### Команды

```bash
qm start <vmid>                                    # хук сам откажет, если другая VM up
ssh bare-pve /usr/local/sbin/workstation.sh status
ssh bare-pve /usr/local/sbin/workstation.sh start ubuntu --force   # погасить windows -> qm start ubuntu
ssh bare-pve /usr/local/sbin/workstation.sh stop                   # погасить всё
```

> Маппинги `proxmox_hardware_mapping_pci` при переключении не трогаются — это
> метаданные, Proxmox сверяет их только при старте VM.

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

```bash
cd env/windows
terraform init
terraform plan
terraform apply
```

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

### `env/ubuntu`

| Переменная               | Тип         | По умолчанию                          | Описание                          |
|---------------------------|-------------|-----------------------------------------|-------------------------------------|
| `proxmox_node`             | string      | `bare-pve`                              | Целевая нода Proxmox                |
| `proxmox_endpoints`        | map(string) | —                                        | Карта `нода → endpoint API`         |
| `proxmox_insecure`         | bool        | `true`                                   | Пропускать проверку TLS-сертификата |
| `proxmox_api_token`        | string      | — (sensitive)                            | API-токен `terraform@pve`           |
| `vm_name`                  | string      | `ubuntu-workstation`                     | Имя VM                              |
| `cores`                    | number      | `4`                                      | Количество ядер CPU                 |
| `memory`                   | number      | `12288`                                  | RAM, МиБ (как у windows)            |
| `mac`                      | string      | `BC:24:11:AB:CD:01`                      | MAC-адрес (отличается от windows)   |
| `os_type`                  | string      | `l26`                                    | Тип гостевой ОС                     |
| `agent_enabled`            | bool        | `false`                                  | QEMU guest agent (после `apt install qemu-guest-agent`) |
| `gpu_primary`              | bool        | `true`                                   | x-vga на GTX 950. `true` сразу — nouveau зажигает монитор на этапе KMS установщика |
| `iso_file_id`              | string      | `local:iso/ubuntu-26.04-desktop-amd64.iso` | **desktop**-ISO (не server/live-server) |

`env/ubuntu` жёстко задаёт `on_boot = false` и `manage_mappings = false`
(маппинги создаёт `env/windows`).

### `mod/vm`

| Переменная           | Тип                                  | По умолчанию   | Описание                                        |
|-----------------------|---------------------------------------|-----------------|---------------------------------------------------|
| `name`                | string                                 | —               | Имя VM                                            |
| `node_name`           | string                                 | —               | Нода Proxmox                                      |
| `cores`               | number                                 | `1`             | Количество ядер                                   |
| `memory`              | number                                 | `512`           | RAM, МБ                                           |
| `cpu_type`            | string                                 | `host`          | Модель CPU (`host` для passthrough-рабочки)       |
| `agent_enabled`       | bool                                   | `false`         | Канал QEMU guest agent                            |
| `on_boot`             | bool                                   | `true`          | Автозапуск на буте. `env/windows` и `env/ubuntu` ставят `false` — стартом рулит арбитр |
| `manage_mappings`     | bool                                   | `true`          | Создавать cluster PCI-маппинги. `false` — только привязывать по имени |
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

## Установка Ubuntu с нуля

В отличие от Windows экран установщика **видно на мониторе сразу**: OVMF/GRUB
тёмные, но `nouveau` зажигает карту на этапе KMS, ещё до graphical.target
установщика. `gpu_primary = true` можно оставить.

```bash
# 0. хост в vfio-режиме (iommu-vfio-setup.sh + reboot), арбитр разложен
#    (install-gpu-arbiter.sh)

# 1. desktop-ISO на ноду (не server!)
ssh bare-pve 'cd /var/lib/vz/template/iso && wget https://releases.ubuntu.com/26.04/ubuntu-26.04-desktop-amd64.iso'

# 2. VM
source scripts/apply-wrapper.sh && terraform -chdir=env/ubuntu apply

# 3. первый старт (арбитр проверит, что windows не запущена)
ssh bare-pve /usr/local/sbin/workstation.sh start ubuntu
#    первый холодный старт с пустым efidisk0 -> выбрать 'UEFI QEMU DVD-ROM' в
#    OVMF Boot Manager один раз (с клавиатуры за столом, она уже проброшена)

# 4. поставить Ubuntu обычным установщиком за столом

# 5. драйвер NVIDIA + приложения — в терминале внутри Ubuntu:
scp scripts/ubuntu-guest-provision.sh ubuntu-workstation:/tmp/    # или через ISO/USB
sudo bash /tmp/ubuntu-guest-provision.sh
#    ставит проприетарный NVIDIA (ubuntu-drivers; DKMS собирается против ядра
#    самой VM — никакой возни с ядром хоста), Steam (+i386), Discord, VS Code

# 6. reboot VM; отмонтировать ISO
terraform -chdir=env/ubuntu apply -var iso_file_id=null -var agent_enabled=true
```

GTX 950 = Maxwell → **ветка драйвера 580 последняя** с поддержкой. Если
`ubuntu-drivers` не предложит подходящий — `NVIDIA_METHOD=run
NVIDIA_RUN_VERSION=580.178.04 sudo -E bash ubuntu-guest-provision.sh` (проверено:
580.178.04 собирается).

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
