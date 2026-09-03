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

## Архитектура

Репозиторий разделён на переиспользуемый модуль и окружения:

- **`mod/vm`** — универсальный модуль виртуальной машины Proxmox с опциональным
  GPU passthrough через `proxmox_hardware_mapping_pci`.
- **`env/<name>`** — конкретные окружения (например, `env/windows`), которые
  вызывают модуль с нужными параметрами (нода, CPU/RAM, GPU, ISO и т.д.).

Каждое окружение хранит своё состояние отдельно (S3 backend, ключ
`<env>/terraform.tfstate`).

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
4. Добавляет в blacklist конфликтующие драйверы (`nouveau`, `nvidia`,
   `nvidiafb`).
5. Настраивает `softdep`, чтобы `vfio-pci` гарантированно захватывал
   устройство раньше `nvidia`/`nouveau`.
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

GPU передаётся в VM через `proxmox_hardware_mapping_pci`, который требует
4 обязательных атрибута на каждое PCI-устройство:

```hcl
{
  node         = "bare-pve"
  path         = "0000:01:00.0"   # PCI-адрес
  id           = "10de:1402"       # vendor:device ID
  iommu_group  = 1                 # номер IOMMU-группы
  subsystem_id = "10de:1402"       # subsystem vendor:device ID
}
```

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
| `memory`                   | number      | `2048`                       | RAM, МБ                                     |
| `mac`                      | string      | `BC:24:11:F9:5D:82`          | MAC-адрес сетевого интерфейса               |
| `os_type`                  | string      | `win10`                      | Тип гостевой ОС (`win10`, `l26` и т.д.)     |

### `mod/vm`

| Переменная           | Тип                                  | По умолчанию   | Описание                                        |
|-----------------------|---------------------------------------|-----------------|---------------------------------------------------|
| `name`                | string                                 | —               | Имя VM                                            |
| `node_name`           | string                                 | —               | Нода Proxmox                                      |
| `cores`               | number                                 | `1`             | Количество ядер                                   |
| `memory`              | number                                 | `512`           | RAM, МБ                                           |
| `gpu_name`            | string                                 | `gtx950`        | Имя PCI hardware mapping                          |
| `datastore_id_disk`   | string                                 | `local-lvm`     | Datastore для дисков VM                           |
| `disk_interface`      | string                                 | `sata0`         | Интерфейс основного диска (`sata0`/`scsi0`)       |
| `disk_size`           | number                                 | `10`            | Размер диска, ГБ                                  |
| `iso_file_id`         | string                                 | —               | Volume ID уже загруженного ISO (`local:iso/...`)  |
| `boot_order`          | list(string)                          | `["ide3","sata0"]` | Порядок загрузки — **должен совпадать** с фактическим интерфейсом cdrom (см. известные ограничения) |
| `network_bridge`      | string                                 | `vmbr0`         | Сетевой мост                                      |
| `mac`                 | string                                 | —               | MAC-адрес                                         |
| `network_model`       | string                                 | `e1000`         | Модель сетевой карты                              |
| `gpu_devices`         | list(object)                          | `[]`            | Список PCI-устройств для passthrough (`path`, `id`, `iommu_group`, `subsystem_id`) |
| `os_type`             | string                                 | `win10`         | `win10` — Windows, `l26` — Linux                  |

## Известные ограничения

- **`proxmox_hardware_mapping_pci` доступен только под `root@pam`** — жёсткое
  ограничение Proxmox API (взаимодействие с IOMMU), не решается выдачей ролей
  обычному пользователю/токену. Отсюда — второй provider-alias в конфиге.
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
  Above 4G Decoding / Resizable BAR — при появлении `Code 43` у NVIDIA-драйвера
  внутри Windows-гостя решается программно на уровне QEMU-аргументов
  (`args: -cpu host,hidden-state=on,kvm=off`), без правки BIOS.

## Заметки

- Proxmox endpoint не обязательно должен соответствовать ноде, на которой
  будет расположен ресурс — целевая нода указывается явно через `node_name`
  в каждом ресурсе.
- Ресурс `proxmox_virtual_environment_hardware_mapping_pci` **deprecated**
  в версии 0.111.1 — используйте `proxmox_hardware_mapping_pci`.
