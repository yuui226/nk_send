import Foundation
let expected = try Data(contentsOf: URL(fileURLWithPath: "/tmp/ztransfer-simple-case-oracle-17.bin"))
var failures = 0
var cache: [UInt16: UInt16] = [:]
for n in 0...65535 {
 guard let scalar = UnicodeScalar(n) else { continue }
 let actual = PresetTextOrder.folded(String(scalar), cache: &cache)[0]
 let reference = UInt16(expected[n * 2]) << 8 | UInt16(expected[n * 2 + 1])
 if actual != reference { print(String(format: "%04x: %04x != %04x", n, actual, reference)); failures += 1 }
}
print("Unicode 17 BMP mismatches:", failures)
exit(failures == 0 ? 0 : 1)
