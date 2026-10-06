import PitotCore
import Foundation

enum CatalogLoadFailure: Error, Equatable {
    /// The bundle has no file with this name.
    case missing(String)
    case unreadable(String)
    case invalid(CatalogError)
    case invalidQuestions(OnboardingError)
    case invalidKeybindings(KeybindingsCatalogError)
    /// The unverified keys file does not decode. The text names the field and the reason.
    case invalidUnverified(String)

    var message: String {
        switch self {
        case .missing(let name): "The app bundle has no \(name). Rebuild the app."
        case .unreadable(let reason): reason
        case .invalid(let error): ErrorText.describe(error)
        case .invalidQuestions(let error): ErrorText.describe(error)
        case .invalidKeybindings(let error): ErrorText.describe(error)
        case .invalidUnverified(let reason): "The unverified keys list is malformed: \(reason)"
        }
    }
}

/// The JSON files bundled from `Catalog/`, decoded and linted by Core.
enum CatalogResource {
    static func load(bundle: Bundle = .main) -> Result<Catalog, CatalogLoadFailure> {
        data(named: "tweaks", in: bundle).flatMap { data in
            Result { () throws(CatalogError) in try CatalogLoader.load(data: data) }.mapError(CatalogLoadFailure.invalid)
        }
    }

    /// The onboarding questions, linted against `catalog`.
    static func loadSetupQuestions(bundle: Bundle = .main, catalog: Catalog) -> Result<OnboardingFile, CatalogLoadFailure> {
        data(named: "onboarding", in: bundle).flatMap { data in
            Result { () throws(OnboardingError) in try OnboardingLoader.load(data: data, catalog: catalog) }.mapError(CatalogLoadFailure.invalidQuestions)
        }
    }

    static func loadKeybindings(bundle: Bundle = .main) -> Result<KeybindingsCatalog, CatalogLoadFailure> {
        data(named: "keybindings", in: bundle).flatMap { data in
            Result { () throws(KeybindingsCatalogError) in try KeybindingsCatalogLoader.load(data: data) }.mapError(CatalogLoadFailure.invalidKeybindings)
        }
    }

    static func loadUnverified(bundle: Bundle = .main) -> Result<UnverifiedCatalog, CatalogLoadFailure> {
        data(named: "unverified", in: bundle).flatMap { data in
            do {
                return .success(try JSONDecoder().decode(UnverifiedCatalog.self, from: data))
            } catch {
                return .failure(.invalidUnverified(String(describing: error)))
            }
        }
    }

    private static func data(named name: String, in bundle: Bundle) -> Result<Data, CatalogLoadFailure> {
        guard let url = bundle.url(forResource: name, withExtension: "json") else { return .failure(.missing("\(name).json")) }
        do {
            return .success(try Data(contentsOf: url))
        } catch {
            return .failure(.unreadable("Cannot read \(name).json: \(error.localizedDescription)"))
        }
    }
}
