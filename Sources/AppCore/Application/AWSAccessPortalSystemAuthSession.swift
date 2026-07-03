#if os(macOS)
import AppKit
#elseif os(iOS) || os(visionOS)
import UIKit
#endif
@preconcurrency import AuthenticationServices
import Foundation

/// Esquema de URL que debe coincidir con **CFBundleURLTypes** de la app (Mac e iPad).
/// El IdP debe redirigir a `efbyrequestlabs://…` para que `ASWebAuthenticationSession` cierre con éxito.
public enum AWSAccessPortalAuthCallback {
    public static let urlScheme = "efbyrequestlabs"
}

private enum AWSAccessPortalAuthFailure: LocalizedError, Sendable {
    case sessionStartFailed
    case missingCallbackURL

    var errorDescription: String? {
        switch self {
        case .sessionStartFailed:
            return "No se pudo iniciar ASWebAuthenticationSession (p. ej. otra sesión en curso)."
        case .missingCallbackURL:
            return "La sesión terminó sin URL de callback."
        }
    }
}

/// Ancla de presentación para `ASWebAuthenticationSession` (clase: protocolo Objective‑C).
/// El completion del SDK puede llegar en colas de fondo; este tipo no está `@MainActor`.
final class AWSAccessPortalASWebAuthAnchor: NSObject, ASWebAuthenticationPresentationContextProviding {
    static let shared = AWSAccessPortalASWebAuthAnchor()

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        #if os(macOS)
        if let w = NSApp.keyWindow { return w }
        if let w = NSApp.mainWindow { return w }
        if let w = NSApp.windows.first(where: { $0.isVisible }) { return w }
        return NSApp.windows[0]
        #elseif os(iOS) || os(visionOS)
        if let w = Self.resolvePresentationWindow() { return w }
        preconditionFailure("AWSAccessPortalASWebAuthAnchor: no UIWindow (scene no conectada).")
        #else
        preconditionFailure("AWSAccessPortalASWebAuthAnchor: plataforma no soportada.")
        #endif
    }

    #if os(iOS) || os(visionOS)
    private static func resolvePresentationWindow() -> UIWindow? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        for scene in scenes where scene.activationState == .foregroundActive {
            if let key = scene.windows.first(where: \.isKeyWindow) { return key }
            if let w = scene.windows.first(where: { $0.windowLevel == .normal }) { return w }
            if let w = scene.windows.first { return w }
        }
        for scene in scenes {
            if let key = scene.windows.first(where: \.isKeyWindow) { return key }
            if let w = scene.windows.first { return w }
        }
        return nil
    }
    #endif
}

/// Inicia autenticación en la **sesión web del sistema** (Safari / ASWeb).
///
/// Llama a `begin` y a `start()` desde el **main**. El **completionHandler** puede invocarse en cola de fondo;
/// este tipo **no** está `@MainActor`.
public enum AWSAccessPortalSystemBrowserAuth {
    @discardableResult
    public static func begin(
        url: URL,
        prefersEphemeral: Bool,
        completion: @escaping @Sendable (Result<URL, Error>) -> Void
    ) -> ASWebAuthenticationSession? {
        precondition(Thread.isMainThread, "AWSAccessPortalSystemBrowserAuth.begin must run on the main thread.")
        let session = ASWebAuthenticationSession(
            url: url,
            callbackURLScheme: AWSAccessPortalAuthCallback.urlScheme
        ) { callbackURL, error in
            DispatchQueue.main.async {
                if let error {
                    completion(.failure(error))
                    return
                }
                guard let callbackURL else {
                    completion(.failure(AWSAccessPortalAuthFailure.missingCallbackURL))
                    return
                }
                completion(.success(callbackURL))
            }
        }
        MainActor.assumeIsolated {
            session.presentationContextProvider = AWSAccessPortalASWebAuthAnchor.shared
        }
        session.prefersEphemeralWebBrowserSession = prefersEphemeral

        guard session.start() else {
            DispatchQueue.main.async {
                completion(.failure(AWSAccessPortalAuthFailure.sessionStartFailed))
            }
            return nil
        }
        return session
    }
}

/// Plantilla del portal ya sin `{{}}`, lista para abrir en el sistema (http/https o host sin esquema).
public enum AWSAccessPortalResolvedURL {
    /// Construye `URL` para `ASWebAuthenticationSession`: `https://…` / `http://…`, o host+ruta sin esquema (se antepone `https://`).
    public static func openURL(fromResolvedTemplate resolved: String) -> URL? {
        let t = resolved.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return nil }
        if let u = URL(string: t), let scheme = u.scheme?.lowercased(), ["http", "https"].contains(scheme) {
            return u
        }
        if t.contains("{{") {
            return nil
        }
        if !t.contains("://") {
            let prefixed = t.hasPrefix("//") ? "https:\(t)" : "https://\(t)"
            if let u = URL(string: prefixed), u.host != nil {
                return u
            }
        }
        return nil
    }
}
