import Foundation

/// Looks up an English string computed at runtime (enum titles, library and format names) in the app's string
/// catalog, so it follows the system language like SwiftUI literals do. Unknown strings come back unchanged.
func L(_ english: String) -> String {
    Bundle.main.localizedString(forKey: english, value: english, table: nil)
}
