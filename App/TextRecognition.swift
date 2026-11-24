import Foundation
import Vision

/// 用 Vision 识别图片里的文字，供搜索索引使用。语言在通用设置中选择。
enum TextRecognition {
    static func recognize(_ data: Data, preferences: AppPreferences = .shared) async throws -> String {
        var request = RecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.recognitionLanguages = preferences.recognitionLanguages.map { Locale.Language(identifier: $0) }
        request.automaticallyDetectsLanguage = preferences.recognitionAutoDetect
        let observations = try await request.perform(on: data)
        return observations.compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
    }

    /// 系统支持的识别语言，按当前界面语言的名称排序。名称只在需要区分时才带上文字或地区（“繁体中文”而不是“繁体中文（台湾）”）。
    static var supportedLanguages: [(id: String, name: String)] {
        let languages = RecognizeTextRequest().supportedRecognitionLanguages
        let byCode = Dictionary(grouping: languages) { $0.languageCode?.identifier ?? $0.maximalIdentifier }
        return languages.map { language -> (id: String, name: String) in
            let code = language.languageCode?.identifier ?? language.maximalIdentifier
            let siblings = byCode[code] ?? []
            var identifier = code
            if Set(siblings.compactMap(\.script)).count > 1, let script = language.script { identifier += "-\(script.identifier)" }
            let sameScript = siblings.filter { $0.script == language.script }
            if sameScript.count > 1, let region = language.region { identifier += "-\(region.identifier)" }
            return (language.maximalIdentifier, Locale.current.localizedString(forIdentifier: identifier) ?? language.maximalIdentifier)
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}
