import Foundation

extension Int {
    var nonZero: Int? { self == 0 ? nil : self }
}
