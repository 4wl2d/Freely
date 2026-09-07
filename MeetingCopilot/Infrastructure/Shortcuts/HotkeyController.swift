import Carbon
import Foundation
import Observation

/// Carbon's application event target delivers the registered hotkey on the main event loop.
/// No keyboard event tap, Accessibility permission, or raw key monitoring is installed.
@MainActor @Observable
public final class HotkeyController {
    public private(set) var statuses: [HotkeyAction: HotkeyRegistrationStatus] = [:]
    private var registrations: [HotkeyAction: EventHotKeyRef] = [:]
    private var handler: EventHandlerRef?
    private var callbackContext: UnsafeMutableRawPointer?
    private let signature = UInt32.random(in: 1...UInt32.max)
    private var actionsByID: [UInt32: HotkeyAction] = [:]
    private let onAction: @MainActor (HotkeyAction) -> Void

    public init(onAction: @escaping @MainActor (HotkeyAction) -> Void) { self.onAction = onAction }

    @discardableResult
    public func configure(_ bindings: [ShortcutBinding]) -> [HotkeyAction: HotkeyRegistrationStatus] {
        unregisterAll()
        let cleanupStatuses = statuses
        let validation = Self.validate(bindings)
        statuses = validation
        for action in registrations.keys { statuses[action] = cleanupStatuses[action] ?? .failed(status: OSStatus(eventInternalErr)) }
        var symbolicKeys: Unmanaged<CFArray>?
        let symbolicStatus = CopySymbolicHotKeys(&symbolicKeys)
        let reserved: [[String: Any]] = symbolicKeys?.takeRetainedValue() as? [[String: Any]] ?? []
        if handler == nil {
            var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            let context = Unmanaged.passRetained(HotkeyCallbackContext(controller: self)).toOpaque()
            let status = InstallEventHandler(GetApplicationEventTarget(), meetingCopilotHotkeyHandler, 1, &eventType,
                                            context, &handler)
            guard status == noErr else {
                Unmanaged<HotkeyCallbackContext>.fromOpaque(context).release()
                for binding in bindings where validation[binding.action] == .registered { statuses[binding.action] = .failed(status: status) }
                return statuses
            }
            callbackContext = context
        }
        for (index, binding) in bindings.enumerated() {
            guard validation[binding.action] == .registered, let chord = binding.chord else { continue }
            // A failed unregister keeps ownership of that reference; avoid adding another registration for its action.
            guard registrations[binding.action] == nil else { continue }
            guard symbolicStatus == noErr else { statuses[binding.action] = .failed(status: symbolicStatus); continue }
            let carbonModifiers = Self.carbonModifiers(chord.modifiers)
            if reserved.contains(where: {
                ($0[kHISymbolicHotKeyEnabled] as? Bool) == true &&
                ($0[kHISymbolicHotKeyCode] as? NSNumber)?.uint32Value == chord.keyCode &&
                ($0[kHISymbolicHotKeyModifiers] as? NSNumber)?.uint32Value == carbonModifiers
            }) { statuses[binding.action] = .systemReserved; continue }
            let hotkeyID = UInt32(index + 1)
            var reference: EventHotKeyRef?
            let status = RegisterEventHotKey(chord.keyCode, carbonModifiers,
                                            EventHotKeyID(signature: signature, id: hotkeyID), GetApplicationEventTarget(),
                                            OptionBits(kEventHotKeyExclusive), &reference)
            if status == noErr, let reference {
                registrations[binding.action] = reference
                actionsByID[hotkeyID] = binding.action
                statuses[binding.action] = .registered
            } else { statuses[binding.action] = .failed(status: status == noErr ? OSStatus(eventInternalErr) : status) }
        }
        return statuses
    }

    /// Explicitly called before termination and before changing bindings. Repeated calls are safe.
    public func unregisterAll() {
        actionsByID.removeAll()
        for (action, reference) in registrations {
            let status = UnregisterEventHotKey(reference)
            if status == noErr { registrations[action] = nil; statuses[action] = .disabled }
            else { statuses[action] = .failed(status: status) }
        }
        if let handler {
            let status = RemoveEventHandler(handler)
            if status == noErr {
                self.handler = nil
                if let callbackContext { Unmanaged<HotkeyCallbackContext>.fromOpaque(callbackContext).release(); self.callbackContext = nil }
            }
            else { for action in HotkeyAction.allCases { statuses[action] = .failed(status: status) } }
        }
    }

    isolated deinit {
        for reference in registrations.values { _ = UnregisterEventHotKey(reference) }
        if let handler, RemoveEventHandler(handler) == noErr, let callbackContext {
            Unmanaged<HotkeyCallbackContext>.fromOpaque(callbackContext).release()
        }
        // On an OS removal failure, the native handler retains its tiny weak context until process exit.
        // Releasing that context early would leave a dangling C callback pointer.
    }

    nonisolated public static func validate(_ bindings: [ShortcutBinding]) -> [HotkeyAction: HotkeyRegistrationStatus] {
        var result = Dictionary(uniqueKeysWithValues: HotkeyAction.allCases.map { ($0, HotkeyRegistrationStatus.disabled) })
        let actions = Dictionary(grouping: bindings, by: \.action)
        let chords = Dictionary(grouping: bindings.compactMap { binding in binding.chord.map { (binding.action, $0) } }, by: { $0.1 })
        for binding in bindings {
            if actions[binding.action, default: []].count > 1 { result[binding.action] = .duplicate }
            else if let chord = binding.chord {
                if !chord.isValid { result[binding.action] = .invalidChord }
                else if chords[chord, default: []].count > 1 { result[binding.action] = .duplicate }
                else { result[binding.action] = .registered }
            }
        }
        return result
    }

    fileprivate func received(_ identifier: EventHotKeyID) -> OSStatus {
        guard identifier.signature == signature, let action = actionsByID[identifier.id], statuses[action] == .registered else {
            return OSStatus(eventNotHandledErr)
        }
        onAction(action)
        return noErr
    }

    private static func carbonModifiers(_ modifiers: ShortcutModifiers) -> UInt32 {
        var result: UInt32 = 0
        if modifiers.contains(.command) { result |= UInt32(cmdKey) }
        if modifiers.contains(.control) { result |= UInt32(controlKey) }
        if modifiers.contains(.option) { result |= UInt32(optionKey) }
        if modifiers.contains(.shift) { result |= UInt32(shiftKey) }
        return result
    }
}

@MainActor private final class HotkeyCallbackContext {
    weak var controller: HotkeyController?
    init(controller: HotkeyController) { self.controller = controller }
}

private let meetingCopilotHotkeyHandler: EventHandlerUPP = { _, event, userData in
    guard Thread.isMainThread, let event, let userData else { return OSStatus(eventNotHandledErr) }
    var identifier = EventHotKeyID()
    let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                   nil, MemoryLayout<EventHotKeyID>.size, nil, &identifier)
    guard status == noErr else { return status }
    let context = Unmanaged<HotkeyCallbackContext>.fromOpaque(userData).takeUnretainedValue()
    return MainActor.assumeIsolated {
        context.controller?.received(identifier) ?? OSStatus(eventNotHandledErr)
    }
}
