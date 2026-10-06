import Foundation

func isValidProviderID(_ name: String) -> Bool {
    guard !name.isEmpty, name != ".", name != ".." else { return false }
    let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._-")
    return name.unicodeScalars.allSatisfy { allowed.contains($0) }
}
