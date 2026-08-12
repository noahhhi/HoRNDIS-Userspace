import Foundation

@main
private enum AppLanguageProbe {
    static func main() {
        precondition(CommandLine.arguments.count == 2,
                     "usage: app-language-probe <app-bundle>")
        guard let bundle = Bundle(path: CommandLine.arguments[1]) else {
            fatalError("Cannot open app bundle")
        }
        print("localizations=\(bundle.localizations)")
        precondition(bundle.localizations.contains("en"))
        precondition(bundle.localizations.contains("zh-Hans"))
        precondition(bundle.path(forResource: "InfoPlist",
                                 ofType: "strings",
                                 inDirectory: nil,
                                 forLocalization: "en") != nil)
        precondition(bundle.path(forResource: "InfoPlist",
                                 ofType: "strings",
                                 inDirectory: nil,
                                 forLocalization: "zh-Hans") != nil)
    }
}
