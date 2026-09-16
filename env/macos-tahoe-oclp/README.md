# macOS Tahoe 26 + OCLP (env/macos-tahoe-oclp)

Экспериментальный трек: macOS **Tahoe 26** с попыткой вернуть ускорение
GTX 950 через **OpenCore Legacy Patcher** (root-patch), на том же
физическом железе и той же `vfio-pci`-связке, что и стабильный трек.

Отдельный env и отдельная VM (**104**) специально, чтобы не трогать
`env/macos-tahoe-desktop` (VM 103, High Sierra + NVIDIA Web Driver) —
она оставлена как воспроизводимое состояние с разобранной паникой.

## Чем отличается от env/macos-tahoe-desktop

- Своя VM (104), свой terraform-state, свой диск.
- `vm_name = "macos-tahoe-oclp"` — **намеренно не** `MACOS_NAME` арбитра,
  поэтому `gpu-arbiter.sh` не управляет этой VM автоматически
  (`hook_prestart` логирует "not an arbiter-managed guest" и ничего не
  делает). GPU/USB/audio всё равно переключаются тем же арбитром, просто
  вручную:

  ```
  bash /var/lib/vz/snippets/gpu-arbiter.sh switch macos   # все гости должны быть выключены
  qm start 104
  ```

- Переиспользует всё, что уже доказано на стабильном треке: ACPI-hotplug
  фикс в `args`, сеть `vmxnet3`, `manage_mappings = false`.

## Важно: чем OCLP патчит Maxwell — это тот же самый закрытый драйвер

Ключевой факт, найденный до начала работ (официальная документация OCLP,
`PATCHEXPLAIN.html`, раздел non-Metal Graphics Acceleration Patches 11.0+):

> NVIDIA Web Drivers Binaries: `GeForceWeb.kext`, `NVDAGF100HalWeb.kext`,
> `NVDAGK100HalWeb.kext`, **`NVDAGM100HalWeb.kext`**, `NVDAGP100HalWeb.kext`,
> **`NVDAResmanWeb.kext`**, `NVDAStartupWeb.kext`, …
> — "Allows for non-Metal Acceleration for NVIDIA Maxwell and Pascal GPUs"

То есть для Maxwell/Pascal OCLP **не восстанавливает родные драйверы
Apple** (их для Maxwell никогда не существовало), а инжектит в новую
macOS **те же самые кексты NVIDIA Web Driver из High Sierra**. А именно
`NVDAResmanWeb` — это тот бинарник, в котором на стабильном треке
воспроизводимо падает NULL-паника (`CR2=0x1bc2`) в момент, когда
WindowServer впервые открывает фреймбуфер (полный разбор — в
`env/macos-tahoe-desktop/README.md`).

**Вывод, который надо держать в голове**: экспериментальный трек с
высокой вероятностью упирается в ту же самую панику, потому что это
буквально тот же код. Разница только в окружении (другая версия
IOGraphics/IONDRVSupport и userspace-патчи OCLP), что оставляет
ненулевой, но не гарантированный шанс.

Для Kepler (GTX 6xx/7xx) ситуация принципиально другая — там OCLP
возвращает **родные Metal-драйверы Apple**, и это официально
задокументированный, подтверждённый путь. Если задача "рабочее
ускорение любой ценой", смена карты на Kepler честно выглядит надёжнее
любых патчей вокруг Maxwell.

## Порядок работ

1. Установка Tahoe с нуля: Recovery (BaseSystem-диск на `sata1`) →
   Disk Utility → стереть целевой диск как **APFS** → Reinstall macOS
   Tahoe. Установка идёт с `x-vga=0` (эмулированная VGA + VNC), иначе
   консоли для кликов не будет.
2. Setup Assistant, создание пользователя, включение Remote Login (SSH).
3. **Гарантированный результат в первую очередь** — проверить рабочий
   стол на физическом мониторе **без каких-либо NVIDIA-драйверов**:

   ```
   qm set 104 --hostpci0 mapping=gtx950,pcie=1,rombar=1,romfile=gtx950.rom,x-vga=1
   ```

   Связка `x-vga=1` + GOP-VBIOS доказанно даёт живую картинку с карты на
   мониторе (проверено на VM 103: picker и verbose-лог ядра). Без
   драйвера macOS рисует рабочий стол на EFI-фреймбуфере — без
   ускорения и в низком разрешении, но это **рабочая система с выводом
   на монитор**.
4. Только потом — попытка ускорения через OCLP:
   - из настоящего Recovery: `csrutil disable` и
     `csrutil authenticated-root disable` (NVRAM-патч
     `csr-active-config` в самом ISO на практике не срабатывает);
   - `sudo nvram boot-args="... amfi=0x80"` — иначе патчер упирается в
     "AMFI is enabled";
   - `touch ~/.dortania_developer` — обход хардкода
     `_max_os = os_data.sequoia.value` в `detect.py` OCLP 2.5.0, иначе
     "Unsupported Host OS" для Tahoe;
   - `sudo /Applications/OpenCore-Patcher.app/Contents/MacOS/OpenCore-Patcher
     --patch_sys_vol`, ребут.
   Всё три пункта — находки прошлого захода, см.
   `env/macos-tahoe-desktop/README.md`, раздел "Найдено при реальном apply".
5. Если ловим ту же панику — откатить root-патч (OCLP умеет revert) и
   оставить рабочее состояние из п.3.

## Отличие от прошлого захода на OCLP

В прошлый раз OCLP на этой же машине накатил только `Legacy USB 1.1`
patchset и **не предложил графический патчсет вообще** — потому что
тогда ещё не был найден ACPI-hotplug баг и карта не была видна macOS как
`IOPCIDevice` в принципе. Сейчас карта видна (`compatible =
"pci10de,1402"`, `IONDRVFramebuffer`, AGPM в control-path), так что
патчер должен её распознать и предложить non-Metal patchset для Maxwell.
Ради этой проверки трек и существует.
