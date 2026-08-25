import Foundation

@main
private enum AppLanguageProbe {
    static func main() {
        precondition(CommandLine.arguments.count == 3,
                     "usage: app-language-probe <app-bundle> <status-source>")
        guard let bundle = Bundle(path: CommandLine.arguments[1]) else {
            fatalError("Cannot open app bundle")
        }

        let expectedLocalizations = [
            "en", "zh-Hans", "zh-Hant", "ja", "ko", "fr", "de", "es", "pt-BR", "it", "ru",
        ]
        let referenceKeys = localizationKeys(in: bundle, localization: "en")

        print("localizations=\(bundle.localizations)")
        precondition(Set(bundle.localizations) == Set(expectedLocalizations),
                     "Unexpected app localization set")
        precondition(bundle.localizations.count == expectedLocalizations.count,
                     "Duplicate app localizations")
        for localization in expectedLocalizations {
            precondition(bundle.localizations.contains(localization),
                         "Missing bundle localization: \(localization)")
            precondition(bundle.path(forResource: "InfoPlist",
                                     ofType: "strings",
                                     inDirectory: nil,
                                     forLocalization: localization) != nil,
                         "Missing InfoPlist.strings for \(localization)")
            let keys = localizationKeys(in: bundle, localization: localization)
            precondition(keys == referenceKeys,
                         "Localizable.strings keys differ for \(localization)")
        }
        precondition(referenceKeys.count == 38,
                     "Unexpected localized string count: \(referenceKeys.count)")
        let sourceKeys = localizationKeys(inSource: CommandLine.arguments[2])
        precondition(sourceKeys == referenceKeys,
                     "Swift localization keys differ from Localizable.strings")
    }

    private static func localizationKeys(in bundle: Bundle,
                                         localization: String) -> Set<String> {
        guard let path = bundle.path(forResource: "Localizable",
                                     ofType: "strings",
                                     inDirectory: nil,
                                     forLocalization: localization),
              let dictionary = NSDictionary(contentsOfFile: path) as? [String: String]
        else {
            fatalError("Missing or invalid Localizable.strings for \(localization)")
        }
        precondition(dictionary.values.allSatisfy { !$0.isEmpty },
                     "Empty localization value in \(localization)")
        return Set(dictionary.keys)
    }

    private static func localizationKeys(inSource path: String) -> Set<String> {
        guard let source = try? String(contentsOfFile: path, encoding: .utf8),
              let expression = try? NSRegularExpression(
                pattern: #"localized\(\s*"([A-Za-z0-9.]+)""#
              )
        else {
            fatalError("Cannot read localization keys from status source")
        }
        let range = NSRange(source.startIndex..<source.endIndex, in: source)
        return Set(expression.matches(in: source, range: range).compactMap { match in
            guard let matchRange = Range(match.range(at: 1), in: source) else { return nil }
            return String(source[matchRange])
        })
    }
}
