import AVFoundation
import Foundation

public struct EffectSettings: Codable, Equatable, Sendable {
    public var speed: Float = 0.8
    public var pitch: Float = 0
    public var reverb: Float = 32
    public var volume: Float = 0.8
    public var preservePitch = false
    public var room: ReverbRoom = .hall

    public init() {}

    public var totalPitch: Float {
        pitch + (preservePitch ? 0 : 12 * log2(speed))
    }

    public var clamped: Self {
        var value = self
        value.speed = speed.isFinite ? min(1.25, max(0.5, speed)) : 0.8
        value.pitch = pitch.isFinite ? min(12, max(-12, pitch)) : 0
        value.reverb = reverb.isFinite ? min(80, max(0, reverb)) : 32
        value.volume = volume.isFinite ? min(1, max(0, volume)) : 0.8
        return value
    }

    public var original: Self {
        var value = self
        value.speed = 1
        value.pitch = 0
        value.reverb = 0
        value.preservePitch = false
        return value
    }

    public static let presets: [(name: String, settings: Self)] = {
        var soft = Self()
        soft.speed = 0.9
        soft.reverb = 18
        soft.room = .room
        let classic = Self()
        var deep = Self()
        deep.speed = 0.65
        deep.reverb = 48
        deep.room = .cathedral
        return [("Soft", soft), ("Classic", classic), ("Deep", deep)]
    }()
}

public enum ReverbRoom: String, Codable, CaseIterable, Sendable {
    case room = "Room"
    case hall = "Hall"
    case cathedral = "Cathedral"

    var preset: AVAudioUnitReverbPreset {
        switch self {
        case .room: .mediumRoom
        case .hall: .largeHall
        case .cathedral: .cathedral
        }
    }

    public var tailDuration: Double {
        switch self {
        case .room: 2
        case .hall: 4
        case .cathedral: 8
        }
    }
}
