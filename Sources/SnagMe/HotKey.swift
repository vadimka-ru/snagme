import AppKit
import Carbon.HIToolbox

// Глобальный хоткей через Carbon (срабатывает в фоне и во время драга, без пермишнов).
@MainActor
final class HotKey {
    private var ref: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    var onPress: (() -> Void)?

    func register(keyCode: UInt32 = UInt32(kVK_Space), modifiers: UInt32 = UInt32(optionKey)) {
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                      eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetEventDispatcherTarget(), { _, _, userData -> OSStatus in
            guard let userData else { return OSStatus(eventNotHandledErr) }
            let me = Unmanaged<HotKey>.fromOpaque(userData).takeUnretainedValue()
            DispatchQueue.main.async { MainActor.assumeIsolated { me.onPress?() } }
            return noErr
        }, 1, &eventType, Unmanaged.passUnretained(self).toOpaque(), &handlerRef)

        let id = EventHotKeyID(signature: OSType(0x534E4147), id: 1) // 'SNAG'
        RegisterEventHotKey(keyCode, modifiers, id, GetEventDispatcherTarget(), 0, &ref)
    }
}

// Двойное нажатие Shift (через мониторы событий). Глобальный монитор требует Accessibility.
@MainActor
final class DoubleShift {
    var onTrigger: (() -> Void)?
    private var lastDown: CFTimeInterval = 0
    private var global: Any?
    private var local: Any?

    func start() {
        global = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { e in
            MainActor.assumeIsolated { DoubleShift.shared?.handle(e) }
        }
        local = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { e in
            MainActor.assumeIsolated { DoubleShift.shared?.handle(e) }
            return e
        }
        DoubleShift.shared = self
    }

    private static weak var shared: DoubleShift?

    private func handle(_ e: NSEvent) {
        // Только нажатие левого/правого Shift (не отпускание).
        guard (e.keyCode == 56 || e.keyCode == 60), e.modifierFlags.contains(.shift) else { return }
        let now = CACurrentMediaTime()
        if now - lastDown < 0.35 { lastDown = 0; onTrigger?() }
        else { lastDown = now }
    }
}
