import SwiftUI

enum Theme {
    static let background = Color(red: 11/255, green: 12/255, blue: 22/255)
    static let ink = Color(red: 221/255, green: 247/255, blue: 1)
    static let accent = Color(red: 130/255, green: 251/255, blue: 156/255)
    static let selection = Color(red: 31/255, green: 37/255, blue: 58/255)
    static let border = Color(red: 45/255, green: 52/255, blue: 80/255)
    static let muted = Color(red: 134/255, green: 167/255, blue: 223/255)
    static let panel = Color(red: 17/255, green: 20/255, blue: 34/255)
}

struct DotClock: View {
    let time: String
    var maxPitch: CGFloat = 3.5
    var color = Theme.ink
    var alignRight = false

    private static let glyphs: [Character: [String]] = [
        "0": ["01110", "11011", "10001", "10001", "10001", "11011", "01110"],
        "1": ["00100", "01100", "00100", "00100", "00100", "00100", "01110"],
        "2": ["01110", "10001", "00001", "00010", "00100", "01000", "11111"],
        "3": ["11110", "00001", "00001", "01110", "00001", "00001", "11110"],
        "4": ["00010", "00110", "01010", "10010", "11111", "00010", "00010"],
        "5": ["11111", "10000", "10000", "11110", "00001", "00001", "11110"],
        "6": ["01110", "10000", "10000", "11110", "10001", "10001", "01110"],
        "7": ["11111", "00001", "00010", "00100", "01000", "01000", "01000"],
        "8": ["01110", "10001", "10001", "01110", "10001", "10001", "01110"],
        "9": ["01110", "10001", "10001", "01111", "00001", "00001", "01110"],
        ":": ["0", "0", "1", "0", "1", "0", "0"],
        "A": ["01110", "10001", "10001", "11111", "10001", "10001", "10001"],
        "P": ["11110", "10001", "10001", "11110", "10000", "10000", "10000"],
        "M": ["10001", "11011", "10101", "10101", "10001", "10001", "10001"],
        " ": Array(repeating: "00", count: 7),
    ]

    var body: some View {
        let glyphs = time.compactMap { Self.glyphs[$0] }
        let columns = glyphs.reduce(0) { $0 + $1[0].count + 2 } - 2

        Canvas { context, size in
            guard columns > 0 else { return }
            let pitch = min(maxPitch, size.width / CGFloat(columns))
            let diameter = pitch * 0.76
            let top = (size.height - pitch * 7) / 2
            let leading = alignRight ? size.width - CGFloat(columns) * pitch : 0
            var offset = 0
            var dots = Path()
            for glyph in glyphs {
                for (row, line) in glyph.enumerated() {
                    for (column, value) in line.enumerated() where value == "1" {
                        dots.addEllipse(in: CGRect(
                            x: leading + CGFloat(offset + column) * pitch,
                            y: top + CGFloat(row) * pitch,
                            width: diameter, height: diameter
                        ))
                    }
                }
                offset += glyph[0].count + 2
            }
            context.fill(dots, with: .color(color))
        }
        .frame(height: ceil(maxPitch * 7))
        .accessibilityLabel("Local time")
        .accessibilityValue(time)
    }
}
