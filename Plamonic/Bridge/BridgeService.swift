import Foundation

/// Answers the browser extensions' requests (BridgeProtocol) with the translation coordinator's documents.
@MainActor
final class BridgeService {
    private let coordinator: TranslationCoordinator
    private let settings: @MainActor () -> SettingsSnapshot
    private let isReady: @MainActor (EffectiveSettings) -> Bool
    /// Writes a site's mode to the settings (the extension's menu).
    private let setSiteMode: @MainActor (TranslationMode, URL) -> Void
    private let appVersion: String

    init(
        coordinator: TranslationCoordinator,
        settings: @escaping @MainActor () -> SettingsSnapshot,
        isReady: @escaping @MainActor (EffectiveSettings) -> Bool,
        setSiteMode: @escaping @MainActor (TranslationMode, URL) -> Void = { _, _ in },
        appVersion: String
    ) {
        self.setSiteMode = setSiteMode
        self.coordinator = coordinator
        self.settings = settings
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
        let snapshot = settings()
        let global = snapshot.global
        // Not tied to 翻訳を有効にする: that switch (⌃⌥T) turns the overlays off; the extensions have their own.
        let enabled = global.acceptBrowserExtensions
        switch request.type {
        case .hello:
            var response = BridgeResponse(id: request.id, ok: true)
            response.protocol = BridgeProtocol.version
            response.app = "Plamonic"
            response.version = appVersion
            response.enabled = enabled
            // With a page: the language its site translates into (the site may override the global one).
            response.targetLanguage = site(of: request)?.targetLanguageOverride ?? global.targetLanguage
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
        case .site:
            guard let url = request.url.flatMap(URL.init(string:)) else {
                return .failure(request.id, "badRequest", "url がありません")
            }
            let (profile, source) = snapshot.siteProfile(for: url)
            var response = BridgeResponse(id: request.id, ok: true)
            response.site = Self.site(profile, source: source)
            return response
        case .setSite:
            guard let url = request.url.flatMap(URL.init(string:)), url.host() != nil,
                let mode = request.mode.flatMap(TranslationMode.init(rawValue:))
            else {
                return .failure(request.id, "badRequest", "url と mode（off / automatic / manual）が要ります")
            }
            setSiteMode(mode, url)
            let (profile, source) = settings().siteProfile(for: url)
            var response = BridgeResponse(id: request.id, ok: true)
            response.site = Self.site(profile, source: source)
            return response
        case .sites:
            var response = BridgeResponse(id: request.id, ok: true)
            response.sites = snapshot.siteProfiles.filter { $0.mode == .automatic }.map {
                Self.site($0, source: snapshot.siteSource($0.pattern))
            }
            return response
        }
    }

    private static func site(_ profile: SiteProfile, source: ProfileSource) -> BridgeResponse.Site {
        BridgeResponse.Site(
            pattern: profile.pattern, name: profile.displayName, mode: profile.mode.rawValue,
            include: profile.includeSelectors, exclude: profile.excludeSelectors, source: source.rawValue)
    }

    /// The site profile for the request's page, when it names one.
    private func site(of request: BridgeRequest) -> SiteProfile? {
        guard let url = request.url.flatMap(URL.init(string:)) else { return nil }
        return settings().siteProfile(for: url).profile
    }

    private func translate(_ request: BridgeRequest, global: GlobalSettings) async -> BridgeResponse {
        guard let texts = request.texts, !texts.isEmpty else {
            return .failure(request.id, "badRequest", "texts がありません")
        }
        guard texts.count <= BridgeProtocol.maxTranslateTexts else {
            return .failure(request.id, "tooLarge", "texts が多すぎます（\(texts.count) 件）")
        }
        let settings = Self.documentSettings(
            global: global, kind: "page", context: request.context ?? "", sourceLanguage: request.sourceLanguage,
            site: site(of: request))
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
            global: global, kind: request.kind, context: request.context ?? "", sourceLanguage: request.sourceLanguage,
            site: site(of: request))
        // A text over the limit is skipped (left as it is), not cut: the page would show the translation of its
        // beginning in place of all of it.
        // The marked input is longer than the text by its markers; past twice the limit it goes unmarked.
        let items = request.items.map { items in
            items.map {
                $0.text.count > BridgeProtocol.maxItemCharacters
                    ? TranslationCoordinator.ExternalItem(id: $0.id, text: "")
                    : TranslationCoordinator.ExternalItem(
                        id: $0.id, text: $0.text,
                        input: $0.input.flatMap { $0.count > 2 * BridgeProtocol.maxItemCharacters ? nil : $0 })
            }
        }
        let urgent = min(max(request.urgent ?? BridgeProtocol.defaultUrgentCount, 0), BridgeProtocol.maxUrgentCount)
        let visible = request.visible.map { Array($0.prefix(BridgeProtocol.maxVisible)) }
        guard
            coordinator.updateDocument(
                key, items: items, focus: request.focus, urgentCount: urgent, visible: visible,
                readsAll: request.kind != "captions", settings: settings)
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

    /// Settings for a document: the global ones, the site's overrides (target language, form, its context before
    /// the page's), and the source language the page states. Captions are one continuous talk, so their earlier
    /// lines go along as history.
    nonisolated static func documentSettings(
        global: GlobalSettings, kind: String?, context: String, sourceLanguage: String?, site: SiteProfile? = nil
    ) -> EffectiveSettings {
        var profile = AppProfile(bundleID: "", displayName: "ブラウザ拡張機能")
        profile.mode = .automatic
        profile.useConversationHistory = kind == "captions"
        profile.targetLanguageOverride = site?.targetLanguageOverride
        profile.formOverride = site?.formOverride
        let contexts = [site?.context ?? "", context].map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        profile.context = String(contexts.filter { !$0.isEmpty }.joined(separator: " / ").prefix(BridgeProtocol.maxContextCharacters))
        var global = global
        if let sourceLanguage, let code = LanguageCatalog.plamoCode(forLanguageIdentifier: sourceLanguage) {
            global.sourceLanguage = code
        }
        return EffectiveSettings(profile: profile, global: global)
    }
}
