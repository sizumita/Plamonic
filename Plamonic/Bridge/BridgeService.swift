import Foundation

/// Answers the browser extensions' requests (BridgeProtocol) with the translation coordinator's documents.
@MainActor
final class BridgeService {
    private let coordinator: TranslationCoordinator
    private let globalSettings: @MainActor () -> GlobalSettings
    private let isReady: @MainActor (EffectiveSettings) -> Bool
    private let appVersion: String

    init(
        coordinator: TranslationCoordinator,
        globalSettings: @escaping @MainActor () -> GlobalSettings,
        isReady: @escaping @MainActor (EffectiveSettings) -> Bool,
        appVersion: String
    ) {
        self.coordinator = coordinator
        self.globalSettings = globalSettings
        self.isReady = isReady
        self.appVersion = appVersion
    }

    /// For BridgeSocketServer: one request line in, one response line out.
    nonisolated func handle(line: Data) async -> Data {
        let response: BridgeResponse
        switch BridgeCoding.decodeRequest(line) {
        case .request(let request): response = await handle(request)
        case .failure(let failure): response = failure
        }
        return BridgeCoding.encode(response)
    }

    func handle(_ request: BridgeRequest) async -> BridgeResponse {
        let global = globalSettings()
        // Not tied to 翻訳を有効にする: that switch (⌃⌥T) turns the overlays off; the extensions have their own.
        let enabled = global.acceptBrowserExtensions
        switch request.type {
        case .hello:
            var response = BridgeResponse(id: request.id, ok: true)
            response.protocol = BridgeProtocol.version
            response.app = "Plamonic"
            response.version = appVersion
            response.enabled = enabled
            response.targetLanguage = global.targetLanguage
            response.ready = isReady(Self.documentSettings(global: global, kind: nil, context: "", sourceLanguage: nil))
            response.features = BridgeProtocol.features
            return response
        case .sync:
            guard enabled else { return .failure(request.id, "disabled", "Plamonic の翻訳がオフになっています") }
            return sync(request, global: global)
        case .close:
            guard let key = documentKey(request) else {
                return .failure(request.id, "badRequest", "document がありません")
            }
            coordinator.closeDocument(key)
            return BridgeResponse(id: request.id, ok: true)
        case .translate:
            guard enabled else { return .failure(request.id, "disabled", "Plamonic の翻訳がオフになっています") }
            return await translate(request, global: global)
        }
    }

    private func translate(_ request: BridgeRequest, global: GlobalSettings) async -> BridgeResponse {
        guard let texts = request.texts, !texts.isEmpty else {
            return .failure(request.id, "badRequest", "texts がありません")
        }
        guard texts.count <= BridgeProtocol.maxTranslateTexts else {
            return .failure(request.id, "tooLarge", "texts が多すぎます（\(texts.count) 件）")
        }
        let settings = Self.documentSettings(
            global: global, kind: "page", context: request.context ?? "", sourceLanguage: request.sourceLanguage)
        var translations: [String?] = []
        for text in texts {
            translations.append(await coordinator.translateOnce(text: text, settings: settings))
        }
        var response = BridgeResponse(id: request.id, ok: true)
        response.translations = translations
        return response
    }

    private func sync(_ request: BridgeRequest, global: GlobalSettings) -> BridgeResponse {
        guard let key = documentKey(request) else { return .failure(request.id, "badRequest", "document がありません") }
        if let items = request.items, items.count > BridgeProtocol.maxItems {
            return .failure(request.id, "tooLarge", "項目が多すぎます（\(items.count) 件）")
        }
        let settings = Self.documentSettings(
            global: global, kind: request.kind, context: request.context ?? "", sourceLanguage: request.sourceLanguage)
        let items = request.items.map { items in
            items.map {
                TranslationCoordinator.ExternalItem(id: $0.id, text: String($0.text.prefix(BridgeProtocol.maxItemCharacters)))
            }
        }
        let urgent = min(max(request.urgent ?? BridgeProtocol.defaultUrgentCount, 0), BridgeProtocol.maxUrgentCount)
        guard coordinator.updateDocument(key, items: items, focus: request.focus, urgentCount: urgent, settings: settings)
        else {
            return .failure(request.id, "unknownDocument", "文書が見つかりません。items を付けて送り直してください")
        }
        let results = coordinator.documentResults(key, ids: request.want) ?? []
        var response = BridgeResponse(id: request.id, ok: true)
        response.results = results.map {
            BridgeResponse.Result(
                id: $0.id, state: $0.state.rawValue, text: $0.translation.isEmpty ? nil : $0.translation)
        }
        response.progress = coordinator.documentProgress(key).map { .init(done: $0.done, total: $0.total) }
        return response
    }

    private func documentKey(_ request: BridgeRequest) -> TranslationCoordinator.ExternalDocumentKey? {
        guard let document = request.document?.trimmingCharacters(in: .whitespacesAndNewlines), !document.isEmpty,
            document.count <= 512
        else { return nil }
        return .init(client: request.client ?? "", id: document)
    }

    /// Settings for a document: the global ones, the page's context and the source language the page states.
    /// Captions are one continuous talk, so their earlier lines go along as history.
    nonisolated static func documentSettings(
        global: GlobalSettings, kind: String?, context: String, sourceLanguage: String?
    ) -> EffectiveSettings {
        var profile = AppProfile(bundleID: "", displayName: "ブラウザ拡張機能")
        profile.mode = .automatic
        profile.useConversationHistory = kind == "captions"
        profile.context = String(context.prefix(BridgeProtocol.maxContextCharacters))
        var global = global
        if let sourceLanguage, let code = LanguageCatalog.plamoCode(forLanguageIdentifier: sourceLanguage) {
            global.sourceLanguage = code
        }
        return EffectiveSettings(profile: profile, global: global)
    }
}
