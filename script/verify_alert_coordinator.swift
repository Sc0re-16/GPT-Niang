import AppKit
import GPTNiangCore

@MainActor final class TestNotifications: AlertNotifications {
    var allowed = false
    var requests = 0
    var deliveries: [String] = []
    func authorize(request: Bool, completion: @escaping @MainActor (Bool) -> Void) {
        if request { requests += 1 }; completion(allowed)
    }
    func send(title: String, body: String, completion: @escaping @MainActor (Bool) -> Void) {
        deliveries.append(body); completion(true)
    }
}
@main struct VerifyAlertCoordinator {
    @MainActor static func main() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("niang-native-check-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("preferences.json")
        try Data(#"{"futurePreference":"keep","followCodex":false}"#.utf8).write(to: file)
        let model = WidgetModel(dataDirectory: directory, resources: directory)
        var checks = 0
        func check(_ condition: @autoclosure () -> Bool, _ message: String) {
            precondition(condition(), message); checks += 1
        }
        check(!model.alertPreferences.quotaEnabled && !model.alertPreferences.completionEnabled && !model.alertPreferences.soundEnabled, "upgrade defaults off")
        check(!model.hostLinkPreferences.enabled, "old preferences do not opt in to background activity")
        model.hostLinkPreferences.enabled = true
        check(model.savePreferences(), "host preference saved atomically")
        let savedModel = WidgetModel(dataDirectory: directory, resources: directory)
        check(savedModel.hostLinkPreferences.enabled && !savedModel.followCodex, "host link round trip preserves display mode")
        check(!savedModel.alertPreferences.soundEnabled && savedModel.volume == model.volume, "host link does not change audio")
        model.alertPreferences.shortEnabled = true
        model.snapshot = UsageSnapshot(ok: true, queryOk: true, observedAt: Date().timeIntervalSince1970 * 1000,
            windows: [QuotaWindow(minutes: 300, remaining: 10)], accountKey: "anonymous")
        let denied = TestNotifications()
        let coordinator = AlertCoordinator(model: model, notifications: denied)
        coordinator.windowVisible = true; coordinator.configure()
        check(model.alertPermissionDenied && denied.requests == 1, "permission denied reported")
        check(denied.deliveries.isEmpty && model.bubble && model.message != nil, "denied permission still delivers pet bubble")
        model.hideBubble()
        let restarted = AlertCoordinator(model: model, notifications: denied)
        restarted.windowVisible = true; restarted.configure()
        check(!model.bubble && denied.deliveries.isEmpty, "persisted notification deduplication")
        model.alertPreferences.weekEnabled = true; model.alertPreferences.weekThreshold = 12
        model.savePreferences()
        let prefs = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as! [String: Any]
        check(prefs["futurePreference"] as? String == "keep", "unknown settings preserved")
        let reloaded = WidgetModel(dataDirectory: directory, resources: directory)
        check(reloaded.alertPreferences.weekEnabled && reloaded.alertPreferences.weekThreshold == 12, "settings round trip")
        check(!reloaded.alertPreferences.soundEnabled, "sound remains opt-in")
        let authorized = TestNotifications(); authorized.allowed = true
        let allowed = AlertCoordinator(model: model, notifications: authorized)
        model.snapshot = UsageSnapshot(ok: true, queryOk: true, observedAt: Date().timeIntervalSince1970 * 1000,
            windows: [QuotaWindow(minutes: 10080, remaining: 12)], accountKey: "anonymous")
        allowed.windowVisible = true; allowed.windowBusy = true; allowed.configure()
        check(!model.alertPermissionDenied && authorized.deliveries.count == 1, "authorized system notification")
        check(!model.bubble, "menu or drag defers bubble")
        allowed.windowBusy = false; allowed.tick()
        check(model.bubble && model.message != nil && authorized.deliveries.count == 1, "bubble delivered once after interaction")
        model.hideBubble(); model.alertPreferences.shortEnabled = false; model.alertPreferences.weekEnabled = false
        allowed.configure(); allowed.tick()
        check(!model.bubble && authorized.deliveries.count == 1, "disabled alert stops")
        model.alertPreferences.completionEnabled = true; model.alertPreferences.soundEnabled = true; model.alertPreferences.completionSoundEnabled = true
        model.volume = 0.9
        var tones = 0
        let hidden = AlertCoordinator(model: model, notifications: authorized, playSound: { _ in tones += 1 })
        let event = try JSONSerialization.data(withJSONObject: ["events": [["threadId": "thread", "eventId": "completed-once", "at": Date().timeIntervalSince1970 * 1000]]]) + Data([10])
        hidden.windowVisible = false; hidden.windowBusy = true
        hidden.consume(event)
        check(tones == 1 && !model.bubble, "completion sound is immediate while hidden and busy")
        hidden.consume(event)
        check(tones == 1, "duplicate completion does not repeat sound")
        hidden.windowVisible = true; hidden.windowBusy = false; hidden.tick()
        check(model.bubble && tones == 1, "revealing queued bubble does not replay sound")
        hidden.stop(); model.hideBubble()
        model.alertPreferences.soundEnabled = false; model.alertPreferences.completionSoundEnabled = false
        let muted = AlertCoordinator(model: model, notifications: authorized, playSound: { _ in tones += 1 })
        muted.consume(event)
        check(tones == 1, "sound toggle suppresses hidden completion tone")
        model.alertPreferences.soundEnabled = true; model.alertPreferences.completionSoundEnabled = true; model.volume = 0
        let zeroVolume = AlertCoordinator(model: model, notifications: authorized, playSound: { _ in tones += 1 })
        zeroVolume.consume(event)
        check(tones == 1, "zero volume suppresses hidden completion tone")
        model.volume = 0.9; model.followCodex = true
        for sound in [false, true] {
            for popup in [false, true] {
                model.hideBubble()
                model.alertPreferences.soundEnabled = sound; model.alertPreferences.completionSoundEnabled = sound; model.alertPreferences.completionPopupEnabled = popup
                var audio = 0, presentations = 0
                let routing = AlertCoordinator(model: model, notifications: authorized, playSound: { _ in audio += 1 })
                routing.windowVisible = false; routing.hostFrontmost = false; routing.windowBusy = true
                routing.presentCompletionPopup = { count in presentations += count.values.reduce(0, +); return true }
                routing.consume(event)
                check(audio == (sound ? 1 : 0) && presentations == (popup ? 1 : 0), "four independent audio/popup combinations")
                routing.consume(event)
                check(audio == (sound ? 1 : 0) && presentations == (popup ? 1 : 0), "duplicate event does not repeat either output")
                routing.windowVisible = true; routing.hostFrontmost = true; routing.windowBusy = false; routing.tick()
                check(model.bubble == !popup && audio == (sound ? 1 : 0), "popup-presented event never replays as main bubble or sound")
                routing.stop()
            }
        }
        model.hideBubble(); model.alertPreferences.completionPopupEnabled = true; model.alertPreferences.soundEnabled = false; model.alertPreferences.completionSoundEnabled = false
        var presentations = 0
        let desktop = AlertCoordinator(model: model, notifications: authorized, playSound: { _ in })
        desktop.presentCompletionPopup = { _ in presentations += 1; return true }
        desktop.windowVisible = true; desktop.hostFrontmost = false; model.followCodex = false
        desktop.consume(event); desktop.tick()
        check(presentations == 0 && model.bubble, "desktop free-drag behavior unchanged")
        desktop.stop(); model.hideBubble()
        let foreground = AlertCoordinator(model: model, notifications: authorized, playSound: { _ in })
        foreground.presentCompletionPopup = { _ in presentations += 1; return true }
        model.followCodex = true; foreground.windowVisible = true; foreground.hostFrontmost = true
        foreground.consume(event); foreground.tick()
        check(presentations == 0 && model.bubble, "foreground main pet handles completion without duplicate pet")
        foreground.stop(); model.hideBubble()
        let fallback = AlertCoordinator(model: model, notifications: authorized, playSound: { _ in })
        fallback.presentCompletionPopup = { _ in false }
        fallback.consume(event); fallback.windowVisible = true; fallback.tick()
        check(model.bubble, "unavailable popup screen falls back to queued main bubble")
        fallback.stop()
        // Classified requests must have independent output policy, including
        // when completion monitoring is disabled or quota sound is off.
        model.hideBubble(); model.alertPreferences = AlertPreferences()
        model.alertPreferences.commandEnabled = true
        model.alertPreferences.commandSoundEnabled = true
        model.alertPreferences.commandPopupEnabled = false
        model.alertPreferences.questionEnabled = true
        model.alertPreferences.questionSoundEnabled = false
        model.alertPreferences.questionPopupEnabled = true
        model.followCodex = true; model.volume = 0.9
        var requestTones = 0
        var kinds: [TaskAlertKind] = []
        let classified = AlertCoordinator(model: model, notifications: authorized, playSound: { _ in requestTones += 1 })
        classified.presentCompletionPopup = { counts in kinds += counts.keys; return true }
        func request(_ kind: String, _ id: String) throws -> Data {
            try JSONSerialization.data(withJSONObject: ["events": [["threadId":"desktop", "eventId":id, "kind":kind, "at":Date().timeIntervalSince1970 * 1000]]]) + Data([10])
        }
        classified.consume(try request("command", "command-once"))
        check(requestTones == 1 && kinds.isEmpty, "command sound independent from quota and completion switches")
        classified.consume(try request("question", "question-once"))
        check(requestTones == 1 && kinds == [.question], "question popup can be silent")
        classified.consume(try request("question", "question-once"))
        check(kinds.count == 1, "request replay is deduplicated")
        classified.consume(try request("unknown", "unknown"))
        check(kinds.count == 1, "unknown kind is ignored rather than mislabelled completion")
        classified.stop()
        for kind in [TaskAlertKind.command, .question, .completion] {
            for sound in [false, true] {
                for popup in [false, true] {
                    model.alertPreferences = AlertPreferences()
                    switch kind {
                    case .command, .permission:
                        model.alertPreferences.commandEnabled = true
                        model.alertPreferences.commandSoundEnabled = sound
                        model.alertPreferences.commandPopupEnabled = popup
                    case .question:
                        model.alertPreferences.questionEnabled = true
                        model.alertPreferences.questionSoundEnabled = sound
                        model.alertPreferences.questionPopupEnabled = popup
                    case .completion, .generic:
                        model.alertPreferences.completionEnabled = true
                        model.alertPreferences.completionSoundEnabled = sound
                        model.alertPreferences.completionPopupEnabled = popup
                    }
                    var audio = 0, shown = 0
                    let policy = AlertCoordinator(model: model, notifications: authorized, playSound: { _ in audio += 1 })
                    policy.presentCompletionPopup = { batch in shown += batch[kind] ?? 0; return true }
                    let frame = try request(kind.rawValue, UUID().uuidString)
                    policy.consume(frame); policy.consume(frame)
                    check(audio == (sound ? 1 : 0) && shown == (popup ? 1 : 0), "each category supports all four independent output combinations")
                    policy.stop()
                }
            }
        }
        let legacy = try JSONDecoder().decode(AlertPreferences.self, from: Data(#"{"completionEnabled":true,"soundEnabled":true,"completionPopupEnabled":true}"#.utf8))
        check(legacy.sound(for: .completion) && legacy.popup(for: .completion), "legacy completion choices preserved")
        check(legacy.commandEnabled && legacy.questionEnabled, "existing reminder opt-in carries to request categories")
        var independent = legacy
        independent.completionSoundEnabled = false
        check(!independent.sound(for: .completion) && independent.soundEnabled, "completion mute leaves quota audio intact")
        let oldSoundPrefs = try JSONDecoder().decode(AlertPreferences.self, from: Data(#"{"completionEnabled":true,"soundEnabled":true}"#.utf8))
        check(oldSoundPrefs.completionTone == .original && oldSoundPrefs.commandTone == .original, "old settings retain original sound")
        let invalidSoundPrefs = try JSONDecoder().decode(AlertPreferences.self, from: Data(#"{"completionTone":"removed","questionTone":42,"weekThreshold":37}"#.utf8))
        check(invalidSoundPrefs.completionTone == .original && invalidSoundPrefs.questionTone == .original && invalidSoundPrefs.weekThreshold == 37, "invalid sound does not reset unrelated preferences")
        model.alertPreferences = AlertPreferences()
        model.alertPreferences.completionEnabled = true; model.alertPreferences.completionSoundEnabled = true
        model.alertPreferences.commandEnabled = true; model.alertPreferences.commandSoundEnabled = true
        model.alertPreferences.completionTone = .glass; model.alertPreferences.commandTone = .ping
        var selected: [AlertSound] = []
        let tonesCoordinator = AlertCoordinator(model: model, notifications: authorized, playSound: { selected.append($0) })
        let batch = try JSONSerialization.data(withJSONObject: ["events": [
            ["threadId":"t", "eventId":"c", "kind":"completion", "at":Date().timeIntervalSince1970 * 1000],
            ["threadId":"t", "eventId":"p", "kind":"command", "at":Date().timeIntervalSince1970 * 1000]
        ]]) + Data([10])
        tonesCoordinator.consume(batch)
        check(selected == [.ping], "simultaneous command and completion use command sound once")
        tonesCoordinator.consume(batch)
        check(selected == [.ping], "dedup does not replay selected tone")
        tonesCoordinator.stop()
        let soundReloaded = try JSONDecoder().decode(AlertPreferences.self, from: JSONEncoder().encode(model.alertPreferences))
        check(soundReloaded.completionTone == .glass, "sound choice persists")
        check(model.taskAlertText([.generic: 1]) == model.text("ChatGPT 有新提醒，请查看"), "generic reminder never claims completion")
        check(model.alertPreferences.tone(for: .generic) == model.alertPreferences.completionTone, "generic uses completion output policy")
        print("Native alert coordinator checks: \(checks) passed (injected notification permissions, no OS notification sent)")
    }
}
