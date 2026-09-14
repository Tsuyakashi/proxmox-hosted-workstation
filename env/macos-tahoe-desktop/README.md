# macOS Tahoe desktop (env/macos-tahoe-desktop)

Третье, взаимоисключающее состояние `bare-pve`, рядом с `env/windows` и
`env/ubuntu`: реальный GPU passthrough (GTX 950 + USB-контроллеры +
onboard-audio, `vfio-pci`) в hackintosh-VM с OpenCore, macOS **Tahoe 26**.

В отличие от `env/macos-tahoe-headless` (нода `pve-rog`, без GPU вообще,
`mod/vm-headless`) — это `mod/vm`, тот же модуль, что и `env/windows`, с
`manage_mappings = false`: passthrough-устройства и `hardware_mapping_pci`
принадлежат `env/windows`, этот env их только потребляет. Три гостя никогда
не запускаются одновременно — переключение делает
`scripts/gpu-arbiter.sh`/`scripts/workstation.sh` (теперь 3-way:
windows/macos/ubuntu).

## Почему Tahoe, а не Monterey

Первоначальный план — macOS Monterey (12.x) с non-Metal-ускорением через
OpenCore-Legacy-Patcher (OCLP), т.к. официального NVIDIA-драйвера для
Monterey+ не существует, а Maxwell (GTX 950) не Metal-совместим "из коробки"
на новых macOS. Приоритет пользователя (в порядке важности):

1. Работающее GPU-ускорение в госте.
2. Максимально новая версия macOS из возможных.
3. Стабильность.

С этим приоритетом и явным разрешением "рискованно, но можно попробовать —
сначала попробуй, откатиться на более старую версию всегда успеешь" — выбор
пал на **Tahoe** (26), а не на более консервативный Sequoia или сам
Monterey: OCLP 2.5.0 (2026-09-08) уже содержит `tahoe = 25` как реальное
распознаваемое значение в `os_data.py`, а условие для non-Metal-патчинга в
`non_metal.py` (`_os_requires_patches()`) — это просто `xnu_major >=
mojave.value`, без верхней границы. То есть патчинг для Tahoe не
захардкожен-заблокирован в самом коде OCLP, хотя официально Dortania его
ещё не подтверждает как документированную конфигурацию. Если non-Metal на
Tahoe окажется фундаментально нерабочим (не просто нестабильным, а честным
дохлым концом без пути вперёд) — откат на Sequoia или Monterey остаётся
рабочим планом Б, инфраструктура (arbiter, VM, mod/vm) для этого менять не
придётся, только пересобрать OpenCore ISO/recovery под другую версию.

## Архитектура

- `mod/vm` (не отдельный модуль) — `cores = 4` (весь `bare-pve`, i5-4460,
  без SMT — уже степень двойки, `sockets` не нужен), `memory = 12288`
  (как у `env/windows` — гости взаимоисключающи).
- `manage_mappings = false`, `passthrough` — `gtx950` (`primary_gpu =
  var.gpu_primary`), `usb-xhci`, `usb-ehci1`, `usb-ehci2`,
  `onboard-audio` — те же имена, что `env/windows` уже завёл как
  `hardware_mapping_pci`.
- `cdrom_interface = "ide0"` — OpenCore ISO, подключён постоянно (не только
  на установку, в отличие от Windows-инсталлятора).
- `installer_interface = "sata1"` / `installer_image_file_id` — опциональный
  второй диск для recovery/BaseSystem-образа на время установки; `null`
  после того, как система установлена на основной `sata0`.
- `gpu_primary` — `false` на установку (`x-vga` не даёт GOP на этой карте,
  ставим через std VGA / noVNC), `true` после того, как WhateverGreen готов
  сам рулить картой — та же схема, что у `env/windows`.
- Без `kvm_arguments` — у `mod/vm` такой переменной вообще нет (Windows он
  никогда не был нужен), и эта сборка Tahoe грузилась и работала на голом
  `cpu.type = "host"` ещё до того, как в headless-проекте всплыл `isa-applesmc`
  (см. `env/macos-tahoe-headless/README.md`, SMCWDT reboot hang) — добавлять
  превентивно не стали.

## Установка с нуля

1. Собрать OpenCore ISO ([LongQT-sea/OpenCore-ISO](https://github.com/LongQT-sea/OpenCore-ISO),
   v0.7) с SMBIOS `MacPro7,1` (свежие серийники), сохранив WhateverGreen,
   `csr-active-config = 030A0000` (частично отключённый SIP — требование
   OCLP root-patcher'а). Загрузить на ноду как `local:iso/<...>.iso`.
2. Скачать recovery/BaseSystem образ через `fetch-macOS-v2.py` (OSX-KVM) —
   `-b Mac-CFF7D910A743CAAF -os latest` (board-id Tahoe; `-s`/`--shortname`
   для `--action download` не работает, это известный мёртвый параметр).
   Конвертировать `qemu-img convert -f dmg -O raw` (родная поддержка dmg,
   `dmg2img` не нужен). Загрузить как `local:import/<...>.raw`.
3. `terraform -chdir=env/macos-tahoe-desktop apply -var opencore_iso_file_id=... -var installer_image_file_id=...`
4. `workstation.sh switch macos && workstation.sh start macos` — арбитр
   перебиндит GTX 950/USB/audio на vfio-pci, поднимет VM.
5. Через консоль/VNC (`x-vga=false`, std VGA — доступен через Proxmox
   noVNC) пройти Recovery → Disk Utility (стереть целевой диск как APFS) →
   Reinstall macOS Tahoe → долгая установка (копирование + несколько
   автоматических перезагрузок).
6. Включить SSH (`sudo systemsetup -setremotelogin on` — сначала выдать
   `Terminal.app` Full Disk Access, иначе команда откажет) — всё
   дальнейшее удобнее по SSH, чем через VNC-клавиатуру.
7. Скачать `OpenCore-Patcher.pkg` (OCLP) внутри гостя (`scp` по SSH или
   `curl` прямо в госте), поставить (`installer -pkg ... -target /`).
8. **Перед `--patch_sys_vol`**: из настоящего Recovery (`macOS Base
   System` в OpenCore picker) выполнить `csrutil disable` и `csrutil
   authenticated-root disable` — NVRAM-патч `csr-active-config` в самом
   OpenCore ISO (шаг 1) на практике не сработал. После — `sudo nvram
   boot-args="... amfi=0x80"` и `touch ~/.dortania_developer` (см.
   "Найдено при реальном apply" — оба нужны для Tahoe на OCLP 2.5.0).
9. `sudo /Applications/OpenCore-Patcher.app/Contents/MacOS/OpenCore-Patcher
   --patch_sys_vol`, перезагрузка.
10. `terraform apply -var gpu_primary=true -var installer_image_file_id=null`
    (install-диск больше не нужен) — переключить вывод на физический
    монитор. **На этой конкретной карте (см. "Честный статус") этот шаг
    сейчас не даёт рабочего вывода** — карта пропадает из системы
    полностью (legacy-only VBIOS, нет UEFI GOP). Оставлено на
    `gpu_primary = false` до появления UEFI-GOP VBIOS через `rom_file`.

## Найдено при реальном apply

- `mod/vm`: `hook_script_file_id` и `started` дрейфовали против дефолтов
  схемы провайдера — реальный, ранее существовавший баг, найденный на живом
  состоянии `env/windows` (`terraform plan` показывал снятие hookscript и
  автозапуск VM). Фикс — `lifecycle { ignore_changes = [hook_script_file_id,
  started] }`; подтверждено `terraform plan` → "No changes" на `env/windows`
  без затрагивания самого env.
- `ignore_changes` на `started` не подменяет дефолт при **первом** create —
  первый `apply` новой VM попытался автостартовать её, пока хост ещё был в
  режиме ubuntu/nvidia: `"Cannot bind 0000:01:00.0 to vfio ... No such
  device"`. Фикс — явный `started = false` в теле ресурса. Ресурс остался
  `tainted` — почищено `terraform untaint`, а не пересоздание (иначе заново
  перезаливать 2.6 ГБ BaseSystem-диск).
- `vm_role()`/`other_guest_running()` в `gpu-arbiter.sh` — новая логика
  различает гостей по **имени**, а не просто "это VM = значит Windows"
  (латентный баг исходного 2-way скрипта: любая другая qemu-VM с
  hookscript'ом была бы ошибочно принята за Windows).
- Клавиатура в госте на время пропадала (мышь работала) во время установки
  — совпало с `PKDownloadError error 8` при загрузке payload. Добавление
  выделенного `usb-kbd` через `qm set --args` не помогло; при этом
  клавиатура явно работала раньше в той же сессии (стирание диска,
  лицензия, выбор диска, старт установки). Откатили `--args`, перезапустили
  VM — клавиатура снова заработала без каких-либо изменений конфигурации.
  Похоже на переходный сбой самой VNC-сессии, а не реальную проблему ввода;
  `PKDownloadError`, скорее всего, тоже был случайным сетевым сбоем
  (`curl -sS https://swscan.apple.com` после отката отработал за ~0.2s).
- Setup Assistant реально **зависал** на шаге "Update Mac Automatically"
  (~20+ минут, оба навигационных кнопки disabled, spinner крутится без
  дальнейшего прогресса) — похоже на зависший `softwareupdated`
  catalog-запрос на этой конкретной hackintosh-конфигурации. Progress
  Setup Assistant **переживает перезагрузку** — `qm stop`/`workstation.sh
  start macos` привели прямо к экрану логина, без повторного прохождения
  уже пройденных шагов (аккаунт и т.д. сохранились).
- SSH (`sudo systemsetup -setremotelogin on`) требует Full Disk Access у
  `Terminal.app` — тот же урок, что и в `env/macos-tahoe-headless`
  (System Settings → Privacy & Security → Full Disk Access → добавить
  Terminal → Quit & Reopen). Без этого команда молча падает с "Turning
  Remote Login on or off requires Full Disk Access privileges."
- **OCLP 2.5.0 CLI (`--patch_sys_vol`) против Tahoe** потребовал трёх
  отдельных фиксов сверх косметического `csr-active-config`-патча в самом
  OpenCore `config.plist` (тот патч, как оказалось, **не сработал** —
  забутленный SIP показывал `0x40`, не ожидаемые `0x0A03`/`0x803`, т.к.
  NVRAM-ключ `csr-active-config` изначально отсутствовал в `NVRAM->Add`
  шаблона LongQT-ISO, и условный патч в `patch_config.py` его не создавал,
  только модифицировал бы существующий):
  1. `csrutil disable` + `csrutil authenticated-root disable` **из
     настоящего Recovery** (`macOS Base System` в OpenCore picker, Utilities
     → Terminal) — это по факту единственный надёжный способ выставить
     верный SIP-битмаск, а не ручной NVRAM-патч в ISO.
  2. `sudo nvram boot-args="... amfi=0x80"` — иначе "AMFI is enabled"
     блокирует патчинг даже при верном SIP.
  3. `touch ~/.dortania_developer` — у OCLP 2.5.0 есть хардкод
     `_max_os = os_data.sequoia.value` в отдельном validation-гейте
     (`detect.py`, НЕ том же файле, что `non_metal.py`'s
     `_os_requires_patches()`, у которого верхней границы нет) — без этого
     файла патчер выдаёт "Unsupported Host OS" для Tahoe независимо от
     остального. Файл — официальный, в самом исходнике предусмотренный
     "Dortania Developer mode" бэкдор для тестирования против ещё не
     официально подтверждённых ОС, не эксплойт.
  После всех трёх фиксов `--patch_sys_vol` реально прошёл ("Patching
  complete") и поставил patchset "Legacy USB 1.1" (+ Extended + Webcam).
  Перезагрузка Recovery↔основной OS ловится через **OpenCore picker с
  Timeout=2 секунды** — через VNC поймать его вживую почти невозможно
  (round-trip дольше самого окна); рабочий приём: `reboot`, подождать ~13с
  (POST + OpenCore init), затем непрерывно слать `Down`/`Right` каждые
  0.15-0.25с несколько секунд — любое нажатие внутри 2-секундного окна
  **отменяет** автозагрузку и ждёт явного выбора.

## Честный статус

**Живая macOS Tahoe 26.6.2 (build 25G83) на bare-pve, стабильно** —
установлена с нуля, аккаунт создан, SSH-доступ настроен и работает
(`ssh workstation@<ip>`, ключ добавлен через `authorized_keys`), 3-way
`gpu-arbiter.sh`/`workstation.sh` переключение подтверждено на реальном
железе без затрагивания `env/windows`/`env/ubuntu`. Это состояние, которое
пользователь увидит утром: гость **включается и полностью
функционален по SSH**, но **не на `gpu_primary = true`** — см. ниже.

### Что реально сработало

- Установка с нуля через Recovery → "Reinstall macOS Tahoe" → создание
  диска → полный Setup Assistant (несмотря на зависание на update-check).
- SSH с Full Disk Access, passwordless auth через `authorized_keys`.
- `csrutil disable` + `authenticated-root disable` из настоящего Recovery.
- OCLP 2.5.0 `--patch_sys_vol` реально патчит корневой том Tahoe (не
  падает, не блокируется): SIP/AMFI/dev-mode гейты все обходятся описанным
  выше способом, `Legacy USB 1.1` patchset ставится и переживает
  перезагрузку.
- `gpu_primary = false` (std-VGA на установку, тот же приём, что и
  `env/windows`) — полностью рабочий, стабильный путь; носитель для этого
  README и вообще всей сессии диагностики.

### Что НЕ сработало (честно) — реальный физический вывод через GTX 950

`gpu_primary = true` (т.е. `x-vga = 1` на `hostpci0`, `-vga none
-nographic` в реальной QEMU-команде — подтверждено `qm showcmd`) **не
работает**: после переключения и ребута гость грузится и остаётся
SSH-доступен, но сама видеокарта **полностью пропадает** из системы —
`system_profiler SPPCIDataType` не показывает vendor `10de` вообще,
`ioreg -l` не находит ни одного упоминания NVIDIA/GeForce, `dmesg` молчит
про GM206. Т.е. это не "нет экрана", а "гостевая ОС не видит устройство на
шине вообще".

**Важное уточнение (после более глубокого расследования, см. ниже): это НЕ
тот же случай, что уже задокументирован в корневом `README.md` ("Монитор
тёмный на экране OVMF" — легитимный, рабочий для `env/windows`/`env/ubuntu`
сценарий, где карта видна ОС, просто без картинки до загрузки драйвера).
Здесь карта не видна гостевой ОС вообще, ни в каком виде — это отдельная,
более фундаментальная проблема.**

Корень (первая гипотеза, дамп VBIOS): дамп реального VBIOS прямо с карты
(хост, `/sys/bus/pci/devices/0000:01:00.0/rom`) — 58368 байт, единственный
legacy x86 (`codetype=0`) образ, никакого UEFI/EFI Byte Code образа нет.
Это совпадает с уже задокументированным в корневом README фактом про эту
же карту. Но проверка `rombar=0` (полностью отключить исполнение ROM
прошивкой) **не изменила результат** — карта всё равно не появляется.
Проверены все 4 комбинации `x-vga`×`rombar` (true/false каждая) — во всех
карта отсутствует одинаково. Значит, дело не в исполнении OPROM как
таковом.

Точный корень (подтверждено): через QEMU monitor (`info pci`) видно, что у
карты (`10de:1402`, `hostpci0.0`) **все BAR-регионы `(not mapped)`** — ни
16 МБ MMIO, ни 256 МБ prefetchable, ни 32 МБ prefetchable, ни I/O-порты не
получили адресов от прошивки, в отличие от эмулированной std-VGA (у той
всё замаплено штатно). Через `ioreg -p IODeviceTree -c IOPCIDevice -w0` в
госте видно ещё точнее: ACPI-мост `ich9-pcie-port-1` (шина 4, `pcidebug =
"0:28:0(4:4)"`) **присутствует** в дереве macOS корректно, но оба его
дочерних слота (`S00@0` — сама GPU, `S01@1` — её HDMI-аудио) остаются
голыми `IORegistryEntry`-заглушками, а не полноценными `IOPCIDevice` — то
есть macOS реально просканировала эту шину и не нашла там устройство,
хотя QEMU видит его прекрасно.

Рабочая теория: прошивка (OVMF) не смогла корректно выделить (map) BAR'ы
для карты при загрузке — из-за чего её config space нечитаем для
последующего OS-level сканирования шины. **Windows и Linux сами
переназначают/чинят PCI-ресурсы, которые прошивка не выделила** (штатное
поведение их PCI-подсистем) — поэтому та же карта, тот же
`hostpci`/`x-vga`-конфиг (`qm showcmd` подтверждает идентичность с
`env/windows`) у них работает. **XNU/`IOPCIFamily` этого не делает** —
использует строго то, что уже выделила прошивка, и если BAR'ы не
назначены, считает устройство отсутствующим. Это ограничение
прошивки/топологии, не версии macOS — откат на Sequoia или Monterey эту
проблему никак не решит.

**UPDATE — рабочий VBIOS найден, проблема реально сложнее (не только GPU):**

Прежде чем решать про VBIOS, обнаружилось, что дело не только в GTX 950:
через `info pci` выяснилось, что **вообще все** passthrough-устройства
(`hostpci0`-`hostpci4` — GPU, её HDMI-аудио, оба USB-контроллера,
onboard-audio) одинаково стоят с `(not mapped)` BAR'ами, не только карта.
Проверены все 4 комбинации `x-vga`×`rombar` — везде одинаково. В `ioreg`
эти PCIe-мосты помечены `IOPCIHotPlug = Yes` — рабочая гипотеза: прошивка
трактует их как hotplug-слоты и не назначает ресурсы заранее, ожидая, что
это сделает ОС в рантайме (как для настоящего hotplug); Windows/Linux это
делают сами, XNU — нет. Пробовал `-global
ICH9-LPC.acpi-pci-hotplug-with-bridge-support=off` и boot-arg `npci=0x2000`
(известные community-фиксы для похожих случаев) — не помогли, `qm.conf` не
даёт управлять hotplug-флагом PCIe root-port напрямую.

**Найденный и подтверждённый рабочий VBIOS**: NVIDIA reference, точное
совпадение Device ID (`10DE:1402`), UEFI Supported: Yes, 202 КБ
(techpowerup.com/vgabios/227961/227961). Автоматически скачать не вышло
(JS-антибот-чекер сайта, а вытащить бинарник через Chrome-автоматизацию
заблокировала политика безопасности инструментов — защита от
эксфильтрации, намеренно не обходил); **пользователь прислал файл
напрямую**. Файл оказался обёрнут в контейнер `NVGI` (первые 0x800 байт) —
после обрезки (`data[0x800:]`) внутри ровно два штатных PCI Option ROM
образа: `codetype=0` (legacy, 0xf400 байт) + `codetype=3` (EFI/GOP, 0x12800
байт, last-image флаг корректный). Залит на ноду как
`/usr/share/kvm/gtx950.rom`, подключён через `gpu_rom_file = "gtx950.rom"`
(терраформ-план — ровно один добавленный атрибут `rom_file`).

**Результат — реально работает, но нестабильно:**
На **холодном** старте QEMU-процесса (`qm stop` + `qm start`, не просто
ребут гостя) с этим `rom_file` карта получает все BAR'ы штатно (`BAR0`,
`BAR1` 256 МБ prefetchable, `BAR3` 32 МБ prefetchable, `BAR5` I/O — все
замаплены, `IRQ 10` назначен), причём и её HDMI-аудио функция тоже.
Подтверждено **дважды подряд**, каждый раз сразу после `qm start`. Но
дальше нестабильно: через несколько секунд после старта (по `dmesg`,
прямо во время начальной раскачки PCIe-линка — судя по всему гонка между
исполнением ROM и повторными сбросами линка на этой стадии) состояние
иногда откатывается обратно в `(not mapped)` (`IRQ` тоже сбрасывается в
`0`) ещё до того, как гость успевает подняться по сети.

**Проверено дополнительно (после первой записи этого раздела): загрузка
с `rom_file` стабильно не поднимает сеть.** Три холодных старта подряд с
`rom_file` — ни один не дал SSH за разумное время (один ждал 5.5+ минут
при устойчиво высокой загрузке CPU QEMU-процесса, два других — 2 минуты
каждый, без каких-либо признаков прогресса). Похоже, что дело не только в
гонке BAR-маппинга — реальный EFI GOP-драйвер из чужого дампа VBIOS,
выполняясь в OVMF при DXE-проходе, судя по всему сам подвисает/зацикливается
(это реальный, задокументированный в community риск: сторонний VBIOS
дамп с другой физической платы того же чипа не гарантированно корректно
работает под виртуализацией, даже при точном совпадении Device ID).

**Решение**: `gpu_primary` и `gpu_rom_file` **откачены обратно**
(`terraform apply -var gpu_primary=false` без `gpu_rom_file` — подтверждено
применённым, `qm showcmd`/`info pci` для сравнения не нужны, план был
ровно 2 атрибута назад). VM 103 **оставлена в этом, проверенно стабильном
состоянии** — SSH поднимается за ~20 секунд, как и на протяжении всей
предыдущей части сессии. Файл `/usr/share/kvm/gtx950.rom` **оставлен на
ноде** (не удалён) и `gpu_rom_file`-переменная в `variables.tf` остаётся
готовой к использованию — сам факт, что этот VBIOS корректно маппит
BAR'ы на холодном старте, подтверждён дважды и остаётся ценным результатом,
просто boot-стабильность с ним пока не решена.

Путь вперёд (не сделано в этой сессии):
1. **Более вероятная причина нестабильности теперь** — сам EFI-драйвер в
   стороннем VBIOS, не гонка с PCIe-сбросами. Проверить: дать OVMF
   debug-консоль (нет debug-сборки прошивки на ноде — нужно собрать
   отдельно или найти) либо попробовать другой дамп VBIOS (ближе к
   ревизии платы, если её можно определить точнее, чем просто
   `10DE:1402`).
2. Альтернатива — не тратить время на подбор стороннего VBIOS: снять
   собственный чистый дамп самой карты (`/sys/bus/pci/devices/0000:01:00.0/rom`,
   уже делалось для диагностики) и попробовать **допатчить именно его**
   готовым UEFI GOP-модулем (например через NVIDIA GOP Update Tool) —
   такой модифицированный, а не чужой, дамп с большей вероятностью
   корректно инициализируется именно на этом физическом железе.
3. Если стабилизируется — прогнать OCLP `--patch_sys_vol` заново (теперь
   карта реально видна железу) для настоящего non-Metal patchset (не
   только Legacy USB), и уже тогда оценивать non-Metal-ускорение как
   таковое.

Механизм (`gpu_rom_file` → `mod/vm`'s `rom_file` → живой `qm showcmd`)
подтверждён рабочим и переиспользуемым — когда появится стабильно
загружающийся VBIOS-файл, включение сведётся к одной команде
(`terraform apply -var gpu_primary=true -var gpu_rom_file=<файл>`) без
дальнейших правок кода.
