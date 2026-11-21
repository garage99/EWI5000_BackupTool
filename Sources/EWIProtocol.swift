// EWI5000 の SysEx / MIDI 仕様（実機の通信を記録して確認したもの）
//
//  ヘッダ: F0 47 7F 20 ...（47 = Akai, 20 = EWI5000）
//  識別要求        F0 7E 7F 06 01 F7                → F0 7E 00 06 02 47 20 00 19 01 <fw 4> ... <シリアル> 00 F7
//  モード問い合わせ  F0 47 7F 20 00 00 05 F7          → F0 47 7F 20 00 00 05 <0=Control/1=Synth> F7
//  モード切替       F0 47 7F 20 00 00 06 <0/1> F7
//  サンプル一覧要求  F0 47 7F 20 02 00 00 F7          → 02 00 04 <dlssnds.map のテキスト>
//  バンク要求       F0 47 7F 20 02 00 03 F7          → 02 00 06 <今のバンク 266×128>（ユーザーバンクは 124 番目以降が壊れて届く）
//  今の音色要求     F0 47 7F 20 02 00 07 F7          → 02 00 08 <266 バイト> <バンク> <番号>
//  保存            F0 47 7F 20 02 00 0A <バンク> <番号> F7（本体内の「今の音色」をそのまま書き込む）
//  音色選択        B0 00 00 / B0 20 <バンク> / C0 <番号>（バンク 0 = Preset、1 = User）
//  パラメータ変更   NRPN: B0 63 00 / B0 62 <n> / B0 06 <上位> / B0 26 <下位> → 音色データの 10+2n, 11+2n バイト目
//
//  音色データ（266 バイト）: 0..7 サンプルのカテゴリ名（NUL 埋め）, 8 サンプルのセット, 9 サンプル番号,
//  10..265 パラメータ 128 個（7 ビット × 2）。SD カードの patchlib.ewi / USERLIB.EWI はこれを 128 個並べたもの。

import Foundation

enum EWI {
    static let recordSize = 266
    static let paramCount = 128
    static let userSlots = 100
    static let libSlots = 128
    static let libFileSize = recordSize * libSlots   // 34048
    static let presetBank: UInt8 = 0
    static let userBank: UInt8 = 1

    static let header: [UInt8] = [0xF0, 0x47, 0x7F, 0x20]

    static let identityRequest: [UInt8] = [0xF0, 0x7E, 0x7F, 0x06, 0x01, 0xF7]
    static let getMode: [UInt8] = header + [0x00, 0x00, 0x05, 0xF7]
    static func setMode(synth: Bool) -> [UInt8] { header + [0x00, 0x00, 0x06, synth ? 0x01 : 0x00, 0xF7] }
    static let requestCatalog: [UInt8] = header + [0x02, 0x00, 0x00, 0xF7]
    static let requestBank: [UInt8] = header + [0x02, 0x00, 0x03, 0xF7]
    static let requestEditBuffer: [UInt8] = header + [0x02, 0x00, 0x07, 0xF7]
    static func store(bank: UInt8, program: UInt8) -> [UInt8] { header + [0x02, 0x00, 0x0A, bank & 0x7F, program & 0x7F, 0xF7] }

    static func selectProgram(bank: UInt8, program: UInt8) -> [UInt8] {
        [0xB0, 0x00, 0x00, 0xB0, 0x20, bank & 0x7F, 0xC0, program & 0x7F]
    }

    static func nrpn(_ n: Int, msb: UInt8, lsb: UInt8) -> [UInt8] {
        [0xB0, 0x63, UInt8((n >> 7) & 0x7F), 0xB0, 0x62, UInt8(n & 0x7F), 0xB0, 0x06, msb & 0x7F, 0xB0, 0x26, lsb & 0x7F]
    }

    // 応答の判定
    static func isReply(_ m: [UInt8], cmd: UInt8) -> Bool {
        m.count >= 7 && m[0] == 0xF0 && m[1] == 0x47 && m[3] == 0x20 && m[4] == 0x02 && m[5] == 0x00 && m[6] == cmd
    }
    static func isModeReply(_ m: [UInt8]) -> Bool {
        m.count >= 9 && m[0] == 0xF0 && m[1] == 0x47 && m[3] == 0x20 && m[4] == 0x00 && m[5] == 0x00 && m[6] == 0x05
    }
    static func isIdentityReply(_ m: [UInt8]) -> Bool {
        m.count >= 10 && m[0] == 0xF0 && m[1] == 0x7E && m[3] == 0x06 && m[4] == 0x02 && m[5] == 0x47
    }

    /// F0 .. F7 を除いた中身（7 バイト目以降）
    static func payload(_ m: [UInt8]) -> [UInt8] {
        guard m.count > 7 else { return [] }
        let end = m.last == 0xF7 ? m.count - 1 : m.count
        return Array(m[7..<end])
    }
}

struct SampleKey: Hashable {
    let category: String
    let set: UInt8
    let index: UInt8
}

struct Patch: Equatable {
    var bytes: [UInt8]   // 266

    init?(_ b: [UInt8]) {
        guard b.count >= EWI.recordSize else { return nil }
        bytes = Array(b.prefix(EWI.recordSize))
        guard bytes.allSatisfy({ $0 < 0x80 }) else { return nil }
    }

    static let emptySlot: Patch = {
        var b = [UInt8](repeating: 0, count: EWI.recordSize)
        let name = Array("altosax".utf8)
        for (i, c) in name.enumerated() { b[i] = c }
        b[8] = 1; b[9] = 1
        return Patch(b)!
    }()

    var category: String { String(decoding: bytes[0..<8].prefix { $0 != 0 }, as: UTF8.self) }
    var sampleKey: SampleKey { SampleKey(category: category, set: bytes[8], index: bytes[9]) }
    var isEmptySlot: Bool { self == Patch.emptySlot }

    func param(_ n: Int) -> (msb: UInt8, lsb: UInt8) { (bytes[10 + 2 * n], bytes[11 + 2 * n]) }

    /// 違っているバイト位置
    func differences(from other: Patch) -> [Int] {
        (0..<EWI.recordSize).filter { bytes[$0] != other.bytes[$0] }
    }
}

/// dlssnds.map（サンプル一覧）
struct SampleCatalog {
    var names: [SampleKey: String] = [:]

    init() {}
    init(text: String) {
        for line in text.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
            let f = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard f.count >= 4, let s = UInt8(f[1]), let i = UInt8(f[2]) else { continue }
            names[SampleKey(category: String(f[0]), set: s, index: i)] = String(f[3])
        }
    }

    func name(for p: Patch) -> String {
        if p.isEmptySlot { return "（空き）" }
        return names[p.sampleKey] ?? "\(p.category) \(p.bytes[8])-\(p.bytes[9])"
    }
}

/// 今の音色（02 00 08 の応答）
struct EditBuffer {
    let patch: Patch
    let bank: UInt8
    let program: UInt8

    init?(reply m: [UInt8]) {
        let p = EWI.payload(m)
        guard p.count >= EWI.recordSize + 2, let patch = Patch(p) else { return nil }
        self.patch = patch
        bank = p[EWI.recordSize]
        program = p[EWI.recordSize + 1]
    }
}

/// バンク全体（02 00 06 の応答）から、壊れていない先頭 count 個を取り出す
func parseBank(reply m: [UInt8], count: Int) -> [Patch]? {
    let p = EWI.payload(m)
    guard p.count >= EWI.recordSize * count else { return nil }
    var out: [Patch] = []
    for i in 0..<count {
        guard let patch = Patch(Array(p[(i * EWI.recordSize)..<((i + 1) * EWI.recordSize)])) else { return nil }
        out.append(patch)
    }
    return out
}

/// 届いたバイト列を 1 メッセージずつに区切る（SysEx は複数パケットにまたがる）
final class MIDIStreamParser {
    private var sysex: [UInt8] = []
    private var inSysex = false
    private var running: UInt8 = 0
    private var pending: [UInt8] = []

    func feed(_ bytes: [UInt8], emit: ([UInt8]) -> Void) {
        for b in bytes {
            if b >= 0xF8 { continue }                 // リアルタイム（クロック等）は無視
            if b == 0xF0 { sysex = [0xF0]; inSysex = true; continue }
            if inSysex {
                if b == 0xF7 { sysex.append(b); emit(sysex); inSysex = false; sysex = []; continue }
                if b < 0x80 { sysex.append(b); continue }
                emit(sysex); inSysex = false; sysex = []  // 途中で切れた SysEx（ユーザーバンクの後半など）
            }
            if b >= 0x80 {
                if b == 0xF7 { continue }
                running = b; pending = [b]
                if dataLength(b) == 0 { emit(pending); pending = [] }
                continue
            }
            guard running != 0 else { continue }
            if pending.isEmpty { pending = [running] }
            pending.append(b)
            if pending.count - 1 >= dataLength(running) { emit(pending); pending = [] }
        }
    }

    private func dataLength(_ status: UInt8) -> Int {
        switch status & 0xF0 {
        case 0xC0, 0xD0: return 1
        case 0x80, 0x90, 0xA0, 0xB0, 0xE0: return 2
        default:
            switch status { case 0xF1, 0xF3: return 1; case 0xF2: return 2; default: return 0 }
        }
    }
}

// MARK: - ファイル

enum BackupFile {
    case bank([Patch])          // 一括（00〜99）
    case single(Patch, bank: UInt8?, program: UInt8?)

    /// 一括バックアップ .syx: F0 47 7F 20 02 00 06 <266×100> F7
    static func bankSysEx(_ patches: [Patch]) -> [UInt8] {
        EWI.header + [0x02, 0x00, 0x06] + patches.flatMap { $0.bytes } + [0xF7]
    }

    /// 個別バックアップ .syx: F0 47 7F 20 02 00 08 <266> <バンク> <番号> F7（本体の「今の音色」と同じ形）
    static func singleSysEx(_ p: Patch, bank: UInt8, program: UInt8) -> [UInt8] {
        EWI.header + [0x02, 0x00, 0x08] + p.bytes + [bank & 0x7F, program & 0x7F, 0xF7]
    }

    /// SD カード用 USERLIB.EWI（100〜127 番は空き）
    static func userLib(_ patches: [Patch]) -> [UInt8] {
        var all = Array(patches.prefix(EWI.userSlots))
        while all.count < EWI.libSlots { all.append(Patch.emptySlot) }
        return all.flatMap { $0.bytes }
    }

    static func load(_ data: [UInt8]) -> BackupFile? {
        // SD カードのファイル（patchlib.ewi / USERLIB.EWI）
        if data.first != 0xF0 {
            guard data.count >= EWI.recordSize * EWI.userSlots else { return nil }
            var out: [Patch] = []
            for i in 0..<EWI.userSlots {
                guard let p = Patch(Array(data[(i * EWI.recordSize)..<((i + 1) * EWI.recordSize)])) else { return nil }
                out.append(p)
            }
            return .bank(out)
        }
        var msgs: [[UInt8]] = []
        MIDIStreamParser().feed(data) { msgs.append($0) }
        for m in msgs {
            if EWI.isReply(m, cmd: 0x06), let bank = parseBank(reply: m, count: EWI.userSlots) { return .bank(bank) }
            if EWI.isReply(m, cmd: 0x08) {
                let p = EWI.payload(m)
                guard let patch = Patch(p) else { continue }
                let hasPos = p.count >= EWI.recordSize + 2
                return .single(patch, bank: hasPos ? p[EWI.recordSize] : nil, program: hasPos ? p[EWI.recordSize + 1] : nil)
            }
        }
        return nil
    }
}

func hex(_ b: [UInt8], limit: Int = 48) -> String {
    let s = b.prefix(limit).map { String(format: "%02X", $0) }.joined(separator: " ")
    return b.count > limit ? s + " …(\(b.count)B)" : s
}

// MARK: - 本体設定（Controlモードの設定値 約330項目）
//  Controlモードに切り替え（00 00 06 00）てから 01 00 05 / 01 01 05 01 を送ると、
//  F0 47 00 20 01 41 04 <値5> <最小5> <最大5> <初期値5> <名前> 00 F7 が項目の数だけ届く。
//  数値は 7 ビット × 5（下位から）。35 ビットの 2 の補数で負の値もある。

extension EWI {
    static let settingsRequest: [[UInt8]] = [header + [0x01, 0x00, 0x05, 0xF7], header + [0x01, 0x01, 0x05, 0x01, 0xF7]]

    static func isSettingReply(_ m: [UInt8]) -> Bool {
        m.count > 28 && m[0] == 0xF0 && m[1] == 0x47 && m[3] == 0x20 && m[4] == 0x01 && m[5] == 0x41 && m[6] == 0x04
    }

    static func decode35(_ b: ArraySlice<UInt8>) -> Int64 {
        var v: Int64 = 0
        for (k, x) in b.enumerated() { v |= Int64(x & 0x7F) << (7 * k) }
        if v >= (1 << 34) { v -= (1 << 35) }
        return v
    }
}

struct DeviceSetting {
    let name: String
    let value: Int64
    let min: Int64
    let max: Int64
    let defaultValue: Int64
    let raw: [UInt8]          // 届いたメッセージそのまま（将来の書き戻し用）

    init?(reply m: [UInt8]) {
        guard EWI.isSettingReply(m) else { return nil }
        let nameBytes = m[27...].prefix { $0 != 0 && $0 != 0xF7 }
        guard !nameBytes.isEmpty else { return nil }
        name = String(decoding: nameBytes, as: UTF8.self)
        value = EWI.decode35(m[7..<12]); min = EWI.decode35(m[12..<17])
        max = EWI.decode35(m[17..<22]); defaultValue = EWI.decode35(m[22..<27])
        raw = m
    }
}

enum SettingsFile {
    /// 届いた設定メッセージを並べた .syx
    static func sysEx(_ s: [DeviceSetting]) -> [UInt8] { s.flatMap { $0.raw } }

    /// 読みやすい一覧（CSV）
    static func csv(_ s: [DeviceSetting]) -> String {
        "name,value,min,max,default\n" + s.map { "\($0.name),\($0.value),\($0.min),\($0.max),\($0.defaultValue)" }.joined(separator: "\n") + "\n"
    }

    static func load(_ data: [UInt8]) -> [DeviceSetting] {
        var out: [DeviceSetting] = []
        MIDIStreamParser().feed(data) { if let s = DeviceSetting(reply: $0) { out.append(s) } }
        return out
    }
}
