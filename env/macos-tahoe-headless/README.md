# macOS Tahoe Headless

Отдельная, независимая от остального репозитория Terraform-среда: macOS Tahoe
26.2 (или последняя стабильная Tahoe на момент установки) как
**headless-хакинтош-VM** на ноде `pve-rog` — другой ноде кластера, чем
`bare-pve`.

**Не имеет отношения к `env/windows` / `env/ubuntu` / `mod/vm` / `mod/ct` /
`scripts/gpu-arbiter.sh`.** Никакого GPU passthrough, никакого разделяемого
железа, никакого арбитра — этот VM не участвует в GPU-мьютексе `bare-pve`
вообще, потому что на `pve-rog` нет физического GPU (интегрированной Iris Pro
5200 хватает на std VGA framebuffer, которого достаточно для CLI/SSH и
изредка VNC/Screen Sharing; никакого Metal/GPU-acceleration нет и не будет).

Назначение — **backend для сборок под свежий Xcode** (CLI/SSH), не десктоп.

## Содержание

- [Стек](#стек)
- [Архитектура](#архитектура)
- [Структура](#структура)
- [Требования](#требования)
- [Переменные](#переменные)
- [Установка macOS Tahoe с нуля](#установка-macos-tahoe-с-нуля)
- [Доступ](#доступ)
- [Известные ограничения](#известные-ограничения)
- [Источники](#источники)

## Стек

```
Нода:             pve-rog (Proxmox VE 9.2.2)
CPU ноды:         Intel i7-4700HQ, 8 потоков (Haswell, AVX2)
RAM ноды:         23.38 GiB всего, ~4 GiB занято другими гостями
Диск ноды:        thin-pool 337.9G (LVM-thin), ~30G занято другими VM/CT
Terraform:        >= 1.16.1
Provider:         bpg/proxmox >= 0.112.0 (нужен kvm_arguments)
State backend:    S3-совместимое (MinIO), тот же бакет, отдельный ключ
Guest:            macOS Tahoe 26.x, OpenCore bootloader, без GPU-driver
```

## Архитектура

Новый модуль **`mod/vm-headless`** — сознательно НЕ `mod/vm` с опциональным
passthrough. `mod/vm` целиком построен вокруг
`proxmox_hardware_mapping_pci` / `hostpci` для *whole-workstation*
GPU-передачи одному из двух взаимоисключающих гостей на `bare-pve`; здесь
этой темы нет вообще, а нужный набор атрибутов (`kvm_arguments`, `vga`,
`tablet_device`, второй опциональный `disk` для install-media) — свой.
Смешивать это в один модуль с флагом-переключателем усложнило бы оба случая
ради несуществующей переиспользуемости — GPU-workstation и headless-VM без
GPU не разделяют почти ничего в конфигурации ресурса, кроме `machine`/`bios`.

Ключевое отличие от `env/windows`: OpenCore, а не встроенный в Proxmox
Windows-путь. OpenCore — это и есть загрузчик (attach'ится как `cdrom` **на
каждый** boot, не только на установку) + отдельный опциональный `disk` для
recovery/BaseSystem media на время установки (импортируется один раз при
create, не live-mount — см. `mod/vm-headless/variables.tf`).

Никакого `hardware_mapping_pci`, никакого `hostpci`, никакого `usb`-passthrough
блока — Terraform-ресурс здесь строго проще, чем в `mod/vm`.

## Структура

```
env/macos-tahoe-headless/
├── backend.tf        # S3 (MinIO), ключ macos-tahoe-headless/terraform.tfstate
├── main.tf            # вызов mod/vm-headless
├── providers.tf        # провайдер: API token, endpoint pve-rog
├── variables.tf
└── README.md           # этот файл
mod/vm-headless/
├── main.tf             # ресурс: VM, без passthrough
├── outputs.tf
├── variables.tf
└── versions.tf
```

## Требования

- Terraform >= 1.16.1
- Доступ к Proxmox VE API по токену (тот же `terraform@pve`, что и у
  остальных env — правами на `pve-rog` управляет тот же ACL/роль)
- HashiCorp Vault + `scripts/apply-wrapper.sh` (см. корневой README —
  переиспользуются как есть, ничего нового не заводилось)
- S3-совместимое хранилище для state (MinIO, тот же инстанс)
- На `pve-rog`: storage с включённым content-type `iso` (обычно уже есть,
  `local`) **и** `import` (новее, может потребоваться
  `pvesm set local --content iso,vztmpl,backup,import` — без него
  `import_from` для recovery-диска откажет)
- Собранный и загруженный на ноду OpenCore ISO — см.
  [Установка macOS Tahoe с нуля](#установка-macos-tahoe-с-нуля). Terraform
  его не собирает и не хранит в себе — это ручной, итеративный артефакт.

## Переменные

### `env/macos-tahoe-headless`

| Переменная                | Тип         | По умолчанию                | Описание                                    |
|----------------------------|-------------|-------------------------------|-----------------------------------------------|
| `proxmox_node`              | string      | `pve-rog`                      | Целевая нода                                   |
| `proxmox_endpoints`         | map(string) | —                              | Карта `нода → endpoint API`                    |
| `proxmox_insecure`          | bool        | `true`                         | Пропускать проверку TLS                        |
| `proxmox_api_token`         | string      | — (sensitive)                  | API-токен `terraform@pve`                      |
| `vm_name`                   | string      | `macos-tahoe-headless`         | Имя VM                                         |
| `cores`                     | number      | `6`                             | Ядра CPU (из 8 потоков ноды)                   |
| `memory`                    | number      | `16288`                        | RAM, МиБ (hard reservation, без balloon)       |
| `disk_size`                 | number      | `100`                          | Главный диск macOS, ГиБ (thin-provisioned)     |
| `opencore_iso_file_id`      | string      | — (обязательна)                | Volume ID загруженного OpenCore ISO            |
| `installer_image_file_id`   | string      | `null`                          | Volume ID recovery/BaseSystem-образа (install) |
| `mac`                       | string      | `BC:24:11:7A:04:0E`             | MAC (отличается от windows/ubuntu)             |
| `network_model`              | string      | `vmxnet3`                       | Нативный macOS-драйвер, без кекста             |

### `mod/vm-headless`

| Переменная                 | Тип     | По умолчанию | Описание                                                        |
|-------------------------------|---------|---------------|------------------------------------------------------------------|
| `name` / `node_name`           | string  | —             | Имя VM / нода                                                     |
| `cores`                         | number  | `1`           | Ядра CPU                                                           |
| `memory`                        | number  | `512`         | RAM, МиБ. Нет `floating` — balloon-устройство не поднимается вовсе |
| `cpu_type`                      | string  | `host`        | Косметический — реальный `-cpu` идёт через `kvm_arguments`         |
| `agent_enabled`                 | bool    | `false`       | QEMU guest agent — стоковый macOS его не понимает                 |
| `on_boot`                       | bool    | `false`       | Автостарт на буте ноды                                             |
| `datastore_id_disk`             | string  | `local-lvm`   | Datastore                                                          |
| `disk_interface`                | string  | `sata0`       | Интерфейс главного диска macOS                                    |
| `disk_size`                     | number  | `100`         | ГиБ, thin-provisioned потолок                                     |
| `cdrom_interface`               | string  | `ide0`        | Интерфейс OpenCore ISO (грузится **каждый** boot)                 |
| `opencore_iso_file_id`          | string  | — (обязательна) | Volume ID OpenCore ISO                                          |
| `installer_interface`           | string  | `sata1`       | Интерфейс recovery/BaseSystem-диска                                |
| `installer_image_file_id`       | string  | `null`        | Volume ID recovery-образа; `null` = диск не создаётся               |
| `network_bridge` / `mac`         | string  | `vmbr0` / —   | Сеть                                                               |
| `network_model`                 | string  | `vmxnet3`     | Нативный macOS-драйвер                                             |
| `os_type`                       | string  | `other`       | У Proxmox нет `ostype` для macOS                                  |
| `vga_type`                      | string  | `std`         | Программный framebuffer, без ускорения                            |
| `tablet_device`                 | bool    | `true`        | USB-таблет для VNC/Screen Sharing курсора                          |
| `kvm_arguments`                 | string  | см. код       | SMC-устройство, SMBIOS type 2, USB HID, `-cpu`-override            |
| `efi_pre_enrolled_keys`         | bool    | `false`       | Secure Boot должен быть выключен — OpenCore не подписан            |

## Установка macOS Tahoe с нуля

**Это набросок процесса, не рецепт «сработает с первого раза».** Собранного
и проверенного EFI под конкретно эту связку (Proxmox 9 + QEMU + Haswell +
headless + Tahoe) в сообществе на сентябрь 2026 ещё нет — Tahoe вышла лишь
несколько месяцев назад, а headless/без-GPU конфигурации — не самый
протоптанный путь даже для куда более обжитых версий macOS.

1. **Собрать OpenCore ISO.** Быстрый старт —
   [`LongQT-sea/OpenCore-ISO`](https://github.com/LongQT-sea/OpenCore-ISO)
   (явно заявляет поддержку вплоть до macOS 26, собран под Proxmox/QEMU).
   Канонический источник для ручной сборки/донастройки —
   [Dortania OpenCore Install Guide](https://dortania.github.io/OpenCore-Install-Guide/).
   В `config.plist`:
   - **SMBIOS: `MacPro7,1`.** Из четырёх Intel-моделей, которые Tahoe ещё
     официально поддерживает (`MacBookPro16,1`, `MacPro7,1`, `MacBookPro16,2`
     — 13" 4×TB3 2020, `iMac20,1`/`iMac20,2` — см.
     [macOS Tahoe page](https://dortania.github.io/OpenCore-Install-Guide/extras/tahoe.html)),
     это единственная, чьё реальное железо массово продаётся вовсе без GPU
     (Mac Pro 2019 без MPX-модуля) — ближе всего к std-VGA-без-ускорения
     реальности этой VM. `iMacPro1,1`, который
     [smbios-support](https://dortania.github.io/OpenCore-Install-Guide/extras/smbios-support.html)
     обычно советует для headless/без-iGPU сборок, в список Tahoe уже не
     входит — понадобился бы OpenCore Legacy Patcher, а не ваниль.
   - Сгенерировать серийники (`macserial`/`GenerateOCSerials`) под
     `MacPro7,1` — не переиспользовать примеры из гайдов.
   - **`AppleMCEReporterDisabler.kext`** обязателен при спуфинге
     `MacPro7,1` на не-Xeon CPU (иначе паника на чтении MCA-регистров).
   - Базовый набор: `Lilu.kext`, `VirtualSMC.kext` (+ `SMCProcessor`/
     `SMCSuperIO` по вкусу). **Без `WhateverGreen`, без framebuffer-патчей**
     — GPU-ускорения нет и не планируется, это сознательно убирает самую
     хрупкую часть типичного hackintosh-EFI.
   - `csr-active-config`: оставить SIP включённым (`00000000`) по
     умолчанию, если не появится конкретная причина его понижать.
2. Загрузить `OpenCore.iso` на `pve-rog` (`scp` в
   `/var/lib/vz/template/iso/` либо через веб-интерфейс) → volume id
   `local:iso/OpenCore.iso`.
3. Создать VM-заглушку (без install-диска):
   ```bash
   source scripts/apply-wrapper.sh
   vault login -method=userpass username=<you>
   terraform -chdir=env/macos-tahoe-headless init
   terraform -chdir=env/macos-tahoe-headless apply \
     -var opencore_iso_file_id="local:iso/OpenCore.iso"
   ```
4. Достать recovery/BaseSystem-образ конкретно под Tahoe — прямого
   Apple-ISO не существует, используется
   [`macrecovery.py` из OSX-KVM](https://github.com/kholia/OSX-KVM)
   (тянет официальный образ Apple по board-id/product, без реального Mac).
   Результат — `BaseSystem.dmg` → сконвертировать в raw `BaseSystem.img`.
5. Загрузить `BaseSystem.img` на `pve-rog` в storage с content-type
   `import` → volume id вида `local:import/BaseSystem.img`, подключить:
   ```bash
   terraform -chdir=env/macos-tahoe-headless apply \
     -var opencore_iso_file_id="local:iso/OpenCore.iso" \
     -var installer_image_file_id="local:import/BaseSystem.img"
   ```
6. Стартовать VM и открыть **VNC-консоль** (для самого инсталла GUI не
   избежать — Disk Utility и установщик Recovery интерактивны):
   `qm start <vmid>` → в пикере OpenCore выбрать BaseSystem → Disk Utility:
   стереть основной диск (APFS, GUID) → запустить установку Tahoe из
   Recovery (тянет остаток системы у Apple по сети — `vmxnet3` + DHCP
   должны просто работать) → несколько ребутов (OpenCore-пикер переживает
   их, это тот же примонтированный cdrom).
7. После первого входа (Setup Assistant, тоже разово через VNC) отключить
   install-диск — он больше не нужен, содержимое главного диска macOS не
   трогает. Просто не передавать `-var installer_image_file_id=...` при
   следующем apply (переменная вернётся к дефолту `null` — **не** передавать
   пустую строку, это не то же самое, что `null`, и провайдер откажет на
   пустом `import_from`):
   ```bash
   terraform -chdir=env/macos-tahoe-headless apply \
     -var opencore_iso_file_id="local:iso/OpenCore.iso"
   ```
8. Включить SSH из того же разового GUI-сеанса: `sudo systemsetup
   -setremotelogin on`. Дальше — только по SSH.

## Доступ

- **SSH** — основной путь. `ssh <user>@<vm-ip>`.
- **Xcode** без повторного похода в GUI — через
  [`xcodes`](https://github.com/XcodesOrg/xcodes) (Apple ID auth прямо в
  терминале, без App Store).
- **VNC/Screen Sharing** — изредка, см. следующий раздел про честные
  ограничения.

## Известные ограничения

- **Headless-only, без Metal/GPU-acceleration.** `vga = std` — программный
  framebuffer. Осознанный компромисс: это backend для сборок, не десктоп.
- **Screen Sharing/VNC не гарантирован.** `WindowServer` без
  Apple-распознаваемого GPU-драйвера (а `WhateverGreen`/framebuffer-патчи
  сюда намеренно не добавлены) может не поднять полноценную GUI-сессию —
  тогда Screen Sharing по ARD/VNC не заработает, хотя SSH и все
  CLI-демоны при этом будут живы (они не зависят от WindowServer). Считать
  VNC best-effort, требующим проверки на месте; если критично — придётся
  вернуть `WhateverGreen` с минимальным виртуальным framebuffer-патчем,
  частично теряя простоту этого подхода.
- **SMBIOS `MacPro7,1` на Haswell-мобильном CPU — намеренное несоответствие
  поколений.** Ванильный OpenCore это разрешает (XNU проверяет набор
  инструкций, а не буквальное совпадение железа с SMBIOS — в этом суть
  hackintosh), но конкретно эта комбинация (Proxmox + QEMU + Haswell +
  MacPro7,1 + Tahoe) не была массово обкатана сообществом на момент
  написания — ожидать итераций по kext-списку/quirks.
- **`kvm_arguments` — стартовый набор, не гарантия.** Значение по
  умолчанию в `mod/vm-headless/variables.tf` взято из актуального (2025-
  2026) гайда Proxmox+Tahoe (archy.net, см. [Источники](#источники)), но
  не проверено на именно этой ноде/степпинге CPU. Первое, что стоит
  диагностировать при проблемах загрузки — csr-active-config, USB-квирки
  (`nec-usb-xhci.msi=off` и т.п.), и совместимость `vmxnet3` конкретно с
  Tahoe (при проблемах — откат на `e1000-82545em`, тоже нативный).
  Аудио-кексты (`AppleALC`/`VoodooHDA`) намеренно не добавлены — headless
  backend не воспроизводит звук; учитывайте, что в Tahoe `AppleHDA.kext`
  всё равно убран из системы (см. tahoe.html), так что аналоговый звук
  через AppleALC в любом случае сломан, если он вдруг понадобится.
- **`import_from` требует content-type `import` на storage** — новее, чем
  `iso`/`vztmpl`; на непроверенном `pve-rog` может потребоваться ручное
  включение (`pvesm set`), см. [Требования](#требования).
- **EFI/OpenCore не управляется Terraform.** `opencore_iso_file_id`
  указывает на файл, который вы собираете и обновляете на ноде вручную —
  итерация `config.plist` (добавить kext, поправить quirk) не требует
  `terraform apply`, только пересборку и повторную загрузку ISO.
- **Легальность non-Apple железа** — уже обсуждалась отдельно, здесь не
  повторяется.

## Источники

- [Dortania OpenCore Install Guide](https://dortania.github.io/OpenCore-Install-Guide/)
- [macOS Tahoe (26) — Dortania](https://dortania.github.io/OpenCore-Install-Guide/extras/tahoe.html)
- [Choosing the right SMBIOS — Dortania](https://dortania.github.io/OpenCore-Install-Guide/extras/smbios-support.html)
- [`LongQT-sea/OpenCore-ISO`](https://github.com/LongQT-sea/OpenCore-ISO)
- [`kholia/OSX-KVM`](https://github.com/kholia/OSX-KVM) (`macrecovery.py`)
- [`thenickdude/KVM-Opencore`](https://github.com/thenickdude/KVM-Opencore)
- [Installing macOS Tahoma as a Proxmox VM — archy.net](https://www.archy.net/installing-macos-tahoma-as-a-proxmox-vm-a-complete-guide/)
  (источник дефолтного `kvm_arguments` в `mod/vm-headless`)
- [bpg/proxmox provider — `proxmox_virtual_environment_vm`](https://registry.terraform.io/providers/bpg/proxmox/latest/docs/resources/virtual_environment_vm)
