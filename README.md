# Proxmox Hosted Workstation

Terraform-конфигурация для развёртывания виртуальных машин в Proxmox VE с
поддержкой GPU passthrough (PCI passthrough видеокарты хоста в гостевую VM).

## Содержание

- [Стек](#стек)
- [Архитектура](#архитектура)
- [Структура репозитория](#структура-репозитория)
- [Требования](#требования)
- [Настройка хоста (GPU passthrough)](#настройка-хоста-gpu-passthrough)
- [Секреты и Vault](#секреты-и-vault)
- [Использование](#использование)
- [Переменные](#переменные)
- [Известные ограничения](#известные-ограничения)
- [Заметки](#заметки)

## Стек

```
OS:               Proxmox VE 9.2.11 x86_64
Kernel:           Linux 7.0.14-14-pve
Bootloader:       GRUB
Terraform:        >= 1.16.1
Provider:         bpg/proxmox 0.111.1
State backend:    S3-compatible (MinIO)
Secrets:          HashiCorp Vault
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
- **`env/<name>`** — конкретные окружения, которые вызывают модуль с нужными
  параметрами (нода, CPU/RAM, GPU, ISO и т.д.):
  - `env/windows` — Windows-рабочка.
  - `env/ubuntu` — Ubuntu 26.04 desktop.

Каждое окружение хранит своё состояние отдельно (S3 backend, ключ
`<env>/terraform.tfstate`).

**`env/windows` и `env/ubuntu` взаимоисключающие** — это одно и то же железо
(GPU + USB-контроллеры + звук `bare-pve`), и каждое из них создаёт cluster
PCI-маппинги с одинаковыми именами (`manage_mappings = true` по умолчанию).
Одновременно применён может быть только один. Переключение:

```bash
terraform -chdir=env/windows destroy
terraform -chdir=env/ubuntu  apply
```

Флаг `manage_mappings = false` в модуле оставлен для будущего варианта, когда
маппинги вынесут в отдельный общий env.

### Провайдеры

Используются **два** экземпляра провайдера `bpg/proxmox`:

| Provider              | Auth                     | Назначение                                                             |
|-----------------------|--------------------------|-------------------------------------------------------------------------|
| `proxmox`              | API token (`terraform@pve`) | Все обычные ресурсы: VM, диски, сеть                                  |
| `proxmox.root` (alias) | `root@pam` + пароль       | Только `proxmox_hardware_mapping_pci` — Proxmox API разрешает создание/изменение hardware mapping исключительно под root@pam (ограничение самого Proxmox, не провайдера) |

## Структура репозитория

```
proxmox-hosted-workstation/
├── env/
│   └── windows/
│       ├── backend.tf        # S3 (MinIO) backend
│       ├── main.tf           # вызов модуля mod/vm
│       ├── providers.tf      # 2 провайдера: обычный + root-алиас
│       └── variables.tf
├── mod/
│   └── vm/
│       ├── main.tf           # ресурсы: VM + hardware_mapping_pci
│       ├── outputs.tf
│       ├── variables.tf
│       └── versions.tf       # required_providers + configuration_aliases
├── scripts/
│   ├── iommu-vfio-setup.sh   # идемпотентная настройка хоста под GPU passthrough
│   ├── apply-wrapper.sh      # обёртка terraform: тянет секреты из Vault
│   └── vault-policy-init.sh  # инициализация Vault-политики для проекта
├── .gitignore
└── README.md
```

## Требования

- Terraform >= 1.16.1
- Доступ к Proxmox VE API (токен) и к учётке `root@pam` (для hardware mapping)
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

## Секреты и Vault

Секреты не хранятся в репозитории (`.gitignore` исключает `terraform.tfvars`
и файлы состояния). Используется `scripts/apply-wrapper.sh`, который перед
`terraform apply`/`plan` подтягивает из Vault:

- `pve-workstation/api` → `TF_VAR_proxmox_root_password`
- `proxmox/terraform-provider` → `TF_VAR_proxmox_api_token`
- `proxmox/minio-credentials` → `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY`
  (для S3 backend)

Инициализация Vault-путей и политики — `scripts/vault-policy-init.sh`.

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

При первом запуске Terraform запросит `proxmox_root_password` (если не
подтянут через Vault-обёртку).

### Права токена Terraform

API-токену (`terraform@pve`), помимо стандартных VM-прав, требуется право
`Mapping.Use` для запуска VM с уже созданным hardware mapping (создание
самого mapping выполняется отдельно от `root@pam`, см. [Архитектура](#архитектура)).
Право добавляется к уже существующей роли:

```bash
pveum role modify TerraformProv --privs "<существующие-права-через-запятую>,Mapping.Use"
```

## Переменные

### `env/windows`

| Переменная               | Тип         | По умолчанию               | Описание                                  |
|---------------------------|-------------|-----------------------------|---------------------------------------------|
| `proxmox_node`             | string      | `bare-pve`                  | Целевая нода Proxmox                        |
| `proxmox_endpoints`        | map(string) | —                            | Карта `нода → endpoint API`                 |
| `proxmox_insecure`         | bool        | `true`                       | Пропускать проверку TLS-сертификата         |
| `proxmox_api_token`        | string      | — (sensitive)                | API-токен `terraform@pve`                   |
| `proxmox_root_password`    | string      | — (sensitive)                | Пароль `root@pam` (нужен только для mapping)|
| `vm_name`                  | string      | `windows-workstation`        | Имя VM                                      |
| `cores`                    | number      | `2`                          | Количество ядер CPU                         |
| `memory`                   | number      | `4096`                       | RAM, МБ                                     |
| `mac`                      | string      | `BC:24:11:F9:5D:82`          | MAC-адрес сетевого интерфейса               |
| `os_type`                  | string      | `win10`                      | Тип гостевой ОС (`win10`, `win11`, `l26`)   |
| `agent_enabled`            | bool        | `false`                      | QEMU guest agent (включать после установки virtio-тулзов) |
| `iso_file_id`              | string      | `local:iso/Win10_22H2_...`   | Volume ID установочного ISO                 |

### `mod/vm`

| Переменная           | Тип                                  | По умолчанию   | Описание                                        |
|-----------------------|---------------------------------------|-----------------|---------------------------------------------------|
| `name`                | string                                 | —               | Имя VM                                            |
| `node_name`           | string                                 | —               | Нода Proxmox                                      |
| `cores`               | number                                 | `1`             | Количество ядер                                   |
| `memory`              | number                                 | `512`           | RAM, МБ                                           |
| `cpu_type`            | string                                 | `host`          | Модель CPU (`host` для passthrough-рабочки)       |
| `agent_enabled`       | bool                                   | `false`         | Канал QEMU guest agent                            |
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

- **`proxmox_hardware_mapping_pci` доступен только под `root@pam`** — жёсткое
  ограничение Proxmox API (взаимодействие с IOMMU), не решается выдачей ролей
  обычному пользователю/токену. Отсюда — второй provider-alias в конфиге.
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
