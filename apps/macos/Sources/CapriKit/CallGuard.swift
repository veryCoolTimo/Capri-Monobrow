import Foundation

/// Идёт ли звонок — без разрешений: переднее приложение из списка звонков, камера или микрофон заняты кем-то
/// (свойство устройства «работает где-то», не захват). Свой голосовой ввод Capri звонком не считается.
public enum CallGuard {
    public static var bundles: Set<String> { AppCatalog.calls }

    public static func inCall(front: String?, camera: Bool, mic: Bool, ownVoice: Bool) -> Bool {
        if let f = front, bundles.contains(f) { return true }
        if camera { return true }
        if mic, !ownVoice { return true }
        return false
    }
}
