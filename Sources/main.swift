// SesKopru — Ses seviyesi kontrolü olmayan çıkış aygıtlarına (DisplayPort/HDMI monitörler)
// Mac'in ses tuşlarıyla birebir çalışan yazılımsal ses kontrolü ekler.
//
// Yöntem: Core Audio Process Tap ile aygıta giden ses yakalanıp susturulur,
// kazanç uygulanarak özel bir aggregate aygıt üzerinden aynı çıkışa geri verilir.
// Uygulama kapanır/çökerse tap yok olur ve ses kendiliğinden normale döner.

import AppKit
import CoreAudio
import ApplicationServices
import ServiceManagement

// MARK: - Core Audio yardımcıları

let systemObject = AudioObjectID(kAudioObjectSystemObject)

func addr(_ sel: AudioObjectPropertySelector,
          _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
          _ el: AudioObjectPropertyElement = kAudioObjectPropertyElementMain) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: sel, mScope: scope, mElement: el)
}

func defaultOutputDevice() -> AudioDeviceID? {
    var a = addr(kAudioHardwarePropertyDefaultOutputDevice)
    var id = AudioDeviceID(0)
    var size = UInt32(MemoryLayout<AudioDeviceID>.size)
    guard AudioObjectGetPropertyData(systemObject, &a, 0, nil, &size, &id) == noErr, id != kAudioObjectUnknown else { return nil }
    return id
}

func stringProperty(_ id: AudioObjectID, _ sel: AudioObjectPropertySelector) -> String? {
    var a = addr(sel)
    var value: Unmanaged<CFString>?
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    guard AudioObjectGetPropertyData(id, &a, 0, nil, &size, &value) == noErr, let v = value else { return nil }
    return v.takeRetainedValue() as String
}

/// Aygıt macOS'un kendi ses/sessiz kontrolünü sunuyor mu?
func hasNativeVolume(_ id: AudioDeviceID) -> Bool {
    for el: UInt32 in [0, 1] {
        var a = addr(kAudioDevicePropertyVolumeScalar, kAudioDevicePropertyScopeOutput, el)
        var settable: DarwinBoolean = false
        if AudioObjectHasProperty(id, &a), AudioObjectIsPropertySettable(id, &a, &settable) == noErr, settable.boolValue {
            return true
        }
    }
    return false
}

func ownProcessObject() -> AudioObjectID? {
    var a = addr(kAudioHardwarePropertyTranslatePIDToProcessObject)
    var pid = getpid()
    var obj = AudioObjectID(0)
    var size = UInt32(MemoryLayout<AudioObjectID>.size)
    guard AudioObjectGetPropertyData(systemObject, &a, UInt32(MemoryLayout<pid_t>.size), &pid, &size, &obj) == noErr,
          obj != kAudioObjectUnknown else { return nil }
    return obj
}

// MARK: - Ses motoru

/// Gerçek zamanlı ses iş parçacığıyla paylaşılan kazanç durumu.
final class GainState {
    var target: Float = 1
    var current: Float = 1
    /// Her render çağrısında artar; bekçi akışın durup durmadığını buna bakarak anlar.
    var ticks: UInt64 = 0
}

final class AudioEngine {
    let deviceUID: String
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private let gain = GainState()
    private let queue = DispatchQueue(label: "seskopru.io", qos: .userInteractive)

    init(deviceUID: String) { self.deviceUID = deviceUID }

    func setGain(_ g: Float) { gain.target = g }
    var ticks: UInt64 { gain.ticks }

    func start(initialGain: Float) throws {
        gain.target = initialGain
        gain.current = initialGain
        guard let me = ownProcessObject() else { throw err("Süreç ses nesnesi alınamadı") }

        let desc = CATapDescription(excludingProcesses: [me], deviceUID: deviceUID, stream: 0)
        desc.name = "SesKopru Tap"
        desc.isPrivate = true
        desc.muteBehavior = .muted
        var status = AudioHardwareCreateProcessTap(desc, &tapID)
        guard status == noErr else { throw err("Process tap oluşturulamadı (\(status))") }

        let dict: [String: Any] = [
            kAudioAggregateDeviceNameKey: "SesKopru",
            kAudioAggregateDeviceUIDKey: "SesKopru-\(UUID().uuidString)",
            kAudioAggregateDeviceMainSubDeviceKey: deviceUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: deviceUID]],
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapUIDKey: desc.uuid.uuidString,
                kAudioSubTapDriftCompensationKey: true,
            ]],
        ]
        status = AudioHardwareCreateAggregateDevice(dict as CFDictionary, &aggregateID)
        guard status == noErr else { stop(); throw err("Aggregate aygıt oluşturulamadı (\(status))") }

        var frames: UInt32 = 256
        var fa = addr(kAudioDevicePropertyBufferFrameSize)
        AudioObjectSetPropertyData(aggregateID, &fa, 0, nil, UInt32(MemoryLayout<UInt32>.size), &frames)

        let gain = self.gain
        status = AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, queue) { _, inData, _, outData, _ in
            AudioEngine.render(UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inData)),
                               UnsafeMutableAudioBufferListPointer(outData), gain)
        }
        guard status == noErr else { stop(); throw err("IOProc oluşturulamadı (\(status))") }
        status = AudioDeviceStart(aggregateID, procID)
        guard status == noErr else { stop(); throw err("Aygıt başlatılamadı (\(status))") }
    }

    func stop() {
        if aggregateID != kAudioObjectUnknown {
            if let p = procID {
                AudioDeviceStop(aggregateID, p)
                AudioDeviceDestroyIOProcID(aggregateID, p)
            }
            AudioHardwareDestroyAggregateDevice(aggregateID)
        }
        if tapID != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tapID) }
        procID = nil
        aggregateID = AudioObjectID(kAudioObjectUnknown)
        tapID = AudioObjectID(kAudioObjectUnknown)
    }

    deinit { stop() }

    /// Gerçek zamanlı: bellek ayırma yok. Float32 tamponları, interleaved ya da değil, kanal kanal kopyalar.
    private static func render(_ input: UnsafeMutableAudioBufferListPointer,
                               _ output: UnsafeMutableAudioBufferListPointer,
                               _ g: GainState) {
        g.ticks &+= 1
        var inChannels = 0
        for b in input { inChannels += Int(b.mNumberChannels) }
        let target = g.target
        var cur = g.current

        guard inChannels > 0, let first = output.first, first.mNumberChannels > 0 else {
            for b in output { if let d = b.mData { memset(d, 0, Int(b.mDataByteSize)) } }
            return
        }
        let outFrames = Int(first.mDataByteSize) / (Int(first.mNumberChannels) * 4)
        let inFirst = input[0]
        let inFrames = inFirst.mNumberChannels > 0 ? Int(inFirst.mDataByteSize) / (Int(inFirst.mNumberChannels) * 4) : 0
        let frames = min(outFrames, inFrames)
        // ~2 ms'de hedefe yaklaşan yumuşak geçiş (tıklama/cızırtı önler)
        let step: Float = 0.01

        var outChBase = 0
        for ob in output {
            guard let od = ob.mData?.assumingMemoryBound(to: Float.self) else { continue }
            let ostride = Int(ob.mNumberChannels)
            memset(od, 0, Int(ob.mDataByteSize))
            for oc in 0..<ostride {
                let ic = (outChBase + oc) % inChannels
                // ic numaralı giriş kanalını bul
                var base = 0
                var src: UnsafeMutablePointer<Float>?
                var istride = 1
                var ioff = 0
                for ib in input {
                    let n = Int(ib.mNumberChannels)
                    if ic < base + n {
                        src = ib.mData?.assumingMemoryBound(to: Float.self)
                        istride = n
                        ioff = ic - base
                        break
                    }
                    base += n
                }
                guard let s = src else { continue }
                var c = g.current
                for f in 0..<frames {
                    c += (target - c) * step
                    od[f * ostride + oc] = s[f * istride + ioff] * c
                }
                cur = c
            }
            outChBase += ostride
        }
        g.current = abs(cur - target) < 1e-5 ? target : cur
    }

    private func err(_ m: String) -> NSError {
        NSError(domain: "SesKopru", code: 1, userInfo: [NSLocalizedDescriptionKey: m])
    }
}

// MARK: - Ses göstergesi (HUD)

final class VolumeHUD {
    private let panel: NSPanel
    private let icon = NSImageView()
    private let bar = ChicletBar()
    private var hideWork: DispatchWorkItem?

    init() {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 220, height: 56),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .popUpMenu
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]

        // Cam efekti + yarı saydam siyah zemin
        let content = NSView(frame: panel.contentView!.bounds)
        content.autoresizingMask = [.width, .height]
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView(frame: content.bounds)
            glass.cornerRadius = 16
            glass.tintColor = NSColor.black.withAlphaComponent(0.7)
            glass.appearance = NSAppearance(named: .darkAqua)
            content.wantsLayer = true
            content.layer?.cornerRadius = 16
            content.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.45).cgColor
            glass.contentView = content
            panel.contentView = glass
        } else {
            let fx = NSVisualEffectView(frame: content.bounds)
            fx.material = .hudWindow
            fx.appearance = NSAppearance(named: .darkAqua)
            fx.state = .active
            fx.wantsLayer = true
            fx.layer?.cornerRadius = 16
            fx.layer?.masksToBounds = true
            content.wantsLayer = true
            content.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.6).cgColor
            fx.addSubview(content)
            panel.contentView = fx
        }
        let fx = content

        icon.frame = NSRect(x: 14, y: 16, width: 24, height: 24)
        icon.symbolConfiguration = .init(pointSize: 17, weight: .medium)
        icon.contentTintColor = .white
        bar.frame = NSRect(x: 48, y: 22, width: 156, height: 12)
        fx.addSubview(icon)
        fx.addSubview(bar)
    }

    func show(volume: Float, muted: Bool) {
        icon.image = NSImage(systemSymbolName: speakerSymbol(volume: volume, muted: muted), accessibilityDescription: nil)
        bar.value = muted ? 0 : CGFloat(volume)
        bar.needsDisplay = true

        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main
        if let vf = screen?.visibleFrame {
            panel.setFrameOrigin(NSPoint(x: vf.maxX - panel.frame.width - 12, y: vf.maxY - panel.frame.height - 10))
        }
        panel.alphaValue = 1
        panel.orderFrontRegardless()

        hideWork?.cancel()
        let w = DispatchWorkItem { [weak self] in
            NSAnimationContext.runAnimationGroup({ $0.duration = 0.35; self?.panel.animator().alphaValue = 0 },
                                                 completionHandler: { self?.panel.orderOut(nil) })
        }
        hideWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: w)
    }
}

final class ChicletBar: NSView {
    var value: CGFloat = 0
    override func draw(_ dirtyRect: NSRect) {
        let r = bounds.insetBy(dx: 0, dy: 3)
        let track = NSBezierPath(roundedRect: r, xRadius: r.height / 2, yRadius: r.height / 2)
        NSColor.white.withAlphaComponent(0.2).setFill()
        track.fill()
        guard value > 0 else { return }
        let fill = NSRect(x: r.minX, y: r.minY, width: max(r.height, r.width * value), height: r.height)
        NSColor.white.setFill()
        NSBezierPath(roundedRect: fill, xRadius: r.height / 2, yRadius: r.height / 2).fill()
    }
}

func speakerSymbol(volume: Float, muted: Bool) -> String {
    if muted || volume == 0 { return "speaker.slash.fill" }
    if volume < 0.34 { return "speaker.wave.1.fill" }
    if volume < 0.67 { return "speaker.wave.2.fill" }
    return "speaker.wave.3.fill"
}

func debugLog(_ m: String) {
    let line = "\(Date()) \(m)\n"
    let url = URL(fileURLWithPath: NSHomeDirectory() + "/Library/Logs/SesKopru.log")
    // 1 MB'ı geçince sıfırla
    if let size = try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int, size > 1_000_000 {
        try? FileManager.default.removeItem(at: url)
    }
    if let h = try? FileHandle(forWritingTo: url) { h.seekToEndOfFile(); h.write(line.data(using: .utf8)!); try? h.close() }
    else { try? line.write(to: url, atomically: true, encoding: .utf8) }
}

// MARK: - Uygulama

// IOKit/hidsystem sabitleri (ev_keymap.h)
let NX_KEYTYPE_SOUND_UP = 0
let NX_KEYTYPE_SOUND_DOWN = 1
let NX_KEYTYPE_MUTE = 7

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private let hud = VolumeHUD()
    private var engine: AudioEngine? { didSet { tapActive = engine != nil } }
    /// Tap iş parçacığının okuduğu kopya (ana iş parçacığını beklememek için).
    private var tapActive = false
    private var deviceName = ""
    private var eventTap: CFMachPort?
    private var reconcileWork: DispatchWorkItem?
    private var lastError: String?

    private let slider = NSSlider(value: 0.5, minValue: 0, maxValue: 1, target: nil, action: nil)
    private let defaults = UserDefaults.standard

    private var volume: Float = 0.5
    private var muted = false

    var active: Bool { engine != nil }

    func applicationDidFinishLaunching(_ n: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        slider.target = self
        slider.action = #selector(sliderChanged)
        slider.isContinuous = true

        if !defaults.bool(forKey: "loginConfigured") {
            try? SMAppService.mainApp.register()
            defaults.set(true, forKey: "loginConfigured")
        }

        installEventTap()
        listenForAudioChanges()
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            debugLog("uyanma")
            self?.engine?.stop(); self?.engine = nil
            self?.scheduleReconcile(delay: 1.5)
        }
        reconcile()
        startWatchdog()
    }

    private var lastTicks: UInt64 = 0
    private var stalls = 0

    /// Uyku/uyanma ya da aygıt değişiminden sonra akış durursa motoru yeniden kurar.
    private func startWatchdog() {
        Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            guard let self, let e = self.engine else { self?.lastTicks = 0; return }
            if e.ticks == self.lastTicks {
                self.stalls += 1
                // İlk 3 seferde hemen, sonra ~30 sn'de bir dene (ekran uykudayken döngüye girmesin)
                guard self.stalls <= 3 || self.stalls % 10 == 0 else { return }
                debugLog("bekçi: akış durmuş (\(self.stalls)), motor yeniden kuruluyor")
                self.stopEngine()
                self.lastTicks = 0
                self.reconcile()
            } else {
                self.stalls = 0
                self.lastTicks = e.ticks
            }
        }
    }

    func applicationWillTerminate(_ n: Notification) { engine?.stop() }

    // MARK: Aygıt takibi

    private func listenForAudioChanges() {
        for sel in [kAudioHardwarePropertyDefaultOutputDevice, kAudioHardwarePropertyDevices] {
            var a = addr(sel)
            AudioObjectAddPropertyListenerBlock(systemObject, &a, .main) { [weak self] _, _ in
                self?.scheduleReconcile(delay: 0.3)
            }
        }
    }

    private func scheduleReconcile(delay: Double) {
        reconcileWork?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.reconcile() }
        reconcileWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: w)
    }

    /// Varsayılan çıkışın ses kontrolü yoksa motoru o aygıt için çalıştırır, varsa durdurur.
    private func reconcile() {
        guard let dev = defaultOutputDevice(), let uid = stringProperty(dev, kAudioDevicePropertyDeviceUID) else {
            stopEngine(); updateIcon(); return
        }
        if hasNativeVolume(dev) || uid.hasPrefix("SesKopru-") {
            stopEngine(); updateIcon(); return
        }
        if engine?.deviceUID == uid { return }

        stopEngine()
        deviceName = stringProperty(dev, kAudioObjectPropertyName) ?? "Çıkış"
        volume = defaults.object(forKey: "vol.\(uid)") as? Float ?? 0.5
        muted = defaults.bool(forKey: "mute.\(uid)")

        let e = AudioEngine(deviceUID: uid)
        do {
            try e.start(initialGain: effectiveGain())
            engine = e
            debugLog("motor başladı → \(deviceName)")
            lastError = nil
        } catch {
            lastError = error.localizedDescription
            debugLog("motor hatası: \(error.localizedDescription)")
        }
        updateIcon()
    }

    private func stopEngine() {
        engine?.stop()
        engine = nil
    }

    // MARK: Ses durumu

    /// 0…1 ölçeğini algısal eğriye çevirir (genlik = v²): 0 = sessiz, 1 = 0 dB, üst kademeler yumuşak.
    private func effectiveGain() -> Float {
        if muted || volume <= 0 { return 0 }
        return volume * volume
    }

    private func apply(showHUD: Bool) {
        engine?.setGain(effectiveGain())
        if let uid = engine?.deviceUID {
            defaults.set(volume, forKey: "vol.\(uid)")
            defaults.set(muted, forKey: "mute.\(uid)")
        }
        updateIcon()
        if showHUD { hud.show(volume: volume, muted: muted) }
    }

    private func step(_ delta: Float) {
        muted = false
        // macOS gibi: 16 adıma yapış
        let q: Float = abs(delta) < 1.0 / 16 ? 64 : 16
        volume = min(1, max(0, ((volume + delta) * q).rounded() / q))
        apply(showHUD: true)
    }

    private func updateIcon() {
        let name = active ? speakerSymbol(volume: volume, muted: muted) : "speaker.fill"
        let img = NSImage(systemSymbolName: name, accessibilityDescription: "Ses")
        img?.isTemplate = true
        statusItem.button?.image = img
        statusItem.button?.appearsDisabled = !active
    }

    @objc private func sliderChanged() {
        volume = Float(slider.doubleValue)
        muted = false
        apply(showHUD: false)
    }

    // MARK: Menü

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        if active {
            menu.addItem(withTitle: deviceName, action: nil, keyEquivalent: "").isEnabled = false
            slider.doubleValue = Double(muted ? 0 : volume)
            let holder = NSView(frame: NSRect(x: 0, y: 0, width: 240, height: 30))
            slider.frame = NSRect(x: 18, y: 4, width: 204, height: 22)
            holder.addSubview(slider)
            let item = NSMenuItem()
            item.view = holder
            menu.addItem(item)
            let m = menu.addItem(withTitle: "Sessiz", action: #selector(toggleMute), keyEquivalent: "")
            m.target = self
            m.state = muted ? .on : .off
        } else {
            let text = lastError.map { "Hata: \($0)" } ?? "Bu çıkışta macOS kendi ses kontrolünü kullanıyor"
            menu.addItem(withTitle: text, action: nil, keyEquivalent: "").isEnabled = false
        }
        if !AXIsProcessTrusted() {
            let a = menu.addItem(withTitle: "⚠︎ Ses tuşları için Erişilebilirlik izni ver…", action: #selector(openAccessibility), keyEquivalent: "")
            a.target = self
        }
        menu.addItem(.separator())
        let login = menu.addItem(withTitle: "Girişte Başlat", action: #selector(toggleLogin), keyEquivalent: "")
        login.target = self
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        let snd = menu.addItem(withTitle: "Ses Ayarları…", action: #selector(openSoundSettings), keyEquivalent: "")
        snd.target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Çıkış", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    }

    @objc private func toggleMute() { muted.toggle(); apply(showHUD: true) }

    @objc private func toggleLogin() {
        if SMAppService.mainApp.status == .enabled { try? SMAppService.mainApp.unregister() }
        else { try? SMAppService.mainApp.register() }
    }

    @objc private func openSoundSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Sound-Settings.extension")!)
    }

    @objc private func openAccessibility() {
        AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary)
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    // MARK: Ses tuşları

    private var axPrompted = false
    /// Basma olayı görülen tuşlar; görülmeyenler bırakma anında işlenir.
    private var downSeen = Set<Int>()
    /// Basılı tutulan ses tuşu için kendi tekrar zamanlayıcımız (HID seviyesinde tekrar olayı gelmiyor).
    private var repeatTimer: Timer?

    private func installEventTap() {
        if !AXIsProcessTrusted() {
            // Yalnızca bir kez sor; sonra sessizce izni bekle
            if !axPrompted {
                axPrompted = true
                AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary)
            }
            // İzin verilene kadar bekle, sonra tap'i kur
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.installEventTap() }
            return
        }
        let mask = CGEventMask(1 << 14) // NX_SYSDEFINED
        let ptr = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(tap: .cghidEventTap, place: .headInsertEventTap, options: .defaultTap,
                                          eventsOfInterest: mask, callback: eventTapCallback, userInfo: ptr) else {
            debugLog("tapCreate başarısız")
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.installEventTap() }
            return
        }
        eventTap = tap
        debugLog("tap kuruldu")
        // Tap kendi iş parçacığında: ana iş parçacığı meşgulken (motor kurulumu vb.) tuşlar gecikmesin
        let src = CFMachPortCreateRunLoopSource(nil, tap, 0)
        let t = Thread {
            CFRunLoopAddSource(CFRunLoopGetCurrent(), src, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
            CFRunLoopRun()
        }
        t.name = "SesKopru.tap"
        t.qualityOfService = .userInteractive
        t.start()
        tapThread = t
    }

    private var tapThread: Thread?

    private func startRepeat(_ delta: Float) {
        repeatTimer?.invalidate()
        // macOS'taki gibi: kısa bekleme, sonra hızlı tekrar
        repeatTimer = Timer.scheduledTimer(withTimeInterval: 0.35, repeats: false) { [weak self] _ in
            self?.repeatTimer = Timer.scheduledTimer(withTimeInterval: 0.07, repeats: true) { _ in self?.step(delta) }
        }
    }

    /// Tap iş parçacığında çalışır: yalnızca karar verir, işi ana iş parçacığına bırakır.
    fileprivate func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            debugLog("tap devre dışı kaldı (\(type.rawValue)), yeniden açılıyor")
            if let t = eventTap { CGEvent.tapEnable(tap: t, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        guard tapActive, let ns = NSEvent(cgEvent: event), ns.type == .systemDefined, ns.subtype.rawValue == 8 else {
            return Unmanaged.passUnretained(event)
        }
        let key = (ns.data1 & 0xFFFF0000) >> 16
        guard key == NX_KEYTYPE_SOUND_UP || key == NX_KEYTYPE_SOUND_DOWN || key == NX_KEYTYPE_MUTE else {
            return Unmanaged.passUnretained(event)
        }
        let data1 = ns.data1
        let flags = ns.modifierFlags
        DispatchQueue.main.async { self.processKey(key, data1: data1, flags: flags) }
        return nil // olayı yut: macOS'un "desteklenmiyor" göstergesi çıkmasın
    }

    private func processKey(_ key: Int, data1: Int, flags rawFlags: NSEvent.ModifierFlags) {
        let ns = (data1: data1, modifierFlags: rawFlags)
        let isDown = ((ns.data1 & 0xFF00) >> 8) == 0xA
        // Bazı sistemlerde basma olayı gelmiyor; o durumda bırakmada işle
        let isRepeat = (ns.data1 & 0x1) != 0
        debugLog(String(format: "TANI %.3f key=%d data1=%x", ProcessInfo.processInfo.systemUptime, key, ns.data1))
        if isRepeat { return } // sistem tekrarı gelirse yok say; tekrarı biz üretiyoruz
        if isDown { downSeen.insert(key) }
        let fire = isDown || !downSeen.contains(key)
        if !isDown { downSeen.remove(key); repeatTimer?.invalidate(); repeatTimer = nil }
        if fire {
            let flags = ns.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if flags.contains(.option) && !flags.contains(.shift) {
                openSoundSettings() // macOS davranışı: ⌥ + ses tuşu → Ses ayarları
            } else {
                let fine = flags.contains(.option) && flags.contains(.shift) // ⌥⇧ → ¼ adım
                let d: Float = fine ? 1.0 / 64 : 1.0 / 16
                switch key {
                case NX_KEYTYPE_SOUND_UP, NX_KEYTYPE_SOUND_DOWN:
                    let delta = key == NX_KEYTYPE_SOUND_UP ? d : -d
                    step(delta)
                    if isDown { startRepeat(delta) }
                default: muted.toggle(); apply(showHUD: true)
                }
            }
        }
    }
}

private func eventTapCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent, refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    guard let refcon else { return Unmanaged.passUnretained(event) }
    return Unmanaged<AppDelegate>.fromOpaque(refcon).takeUnretainedValue().handle(type: type, event: event)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()

