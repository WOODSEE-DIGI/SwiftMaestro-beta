import Foundation

// MARK: - Locale Settings

/// User-configured locale for SwiftMaestro. Captured at install/first-run so
/// bookkeeping, tax labels, and blacklist verification are country-aware.
@Observable
final class LocaleSettings: @unchecked Sendable {
    static let shared = LocaleSettings()

    private let defaults = UserDefaults.standard

    var language: String {
        get { UserDefaults.standard.string(forKey: "sm_language") ?? "en" }
        set {
            UserDefaults.standard.set(newValue, forKey: "sm_language")
            updateLocale()
        }
    }

    var country: String {
        get { UserDefaults.standard.string(forKey: "sm_country") ?? "AU" }
        set {
            UserDefaults.standard.set(newValue, forKey: "sm_country")
            updateLocale()
        }
    }

    /// Whether the user has completed first-run locale selection.
    var hasCompletedLocaleSetup: Bool {
        get { UserDefaults.standard.bool(forKey: "sm_locale_setup_done") }
        set { UserDefaults.standard.set(newValue, forKey: "sm_locale_setup_done") }
    }

    /// Whether MaestroBooks has been set up (COA reviewed, first client, etc.).
    var hasCompletedBooksSetup: Bool {
        get { UserDefaults.standard.bool(forKey: "sm_books_setup_done") }
        set { UserDefaults.standard.set(newValue, forKey: "sm_books_setup_done") }
    }

    /// Master switch for p2p blacklist participation. When false, no reports
    /// are published, no network lookups occur, and reminders stop before the
    /// Blacklist Notice stage.
    var p2pBlacklistEnabled: Bool {
        get { UserDefaults.standard.object(forKey: "sm_p2p_blacklist_enabled") as? Bool ?? false }
        set { UserDefaults.standard.set(newValue, forKey: "sm_p2p_blacklist_enabled") }
    }

    private init() {
        updateLocale()
    }

    private func updateLocale() {
        let identifier = "\(language)_\(country)"
        UserDefaults.standard.set([identifier], forKey: "AppleLanguages")
    }
}

// MARK: - Country-aware tax identifiers

enum TaxIdentifierKind: String, CaseIterable, Sendable {
    case abn      // Australia — Australian Business Number
    case tfn      // Australia — Tax File Number (individuals)
    case acn      // Australia — Australian Company Number
    case gst      // Canada — Goods and Services Tax number
    case hst      // Canada — Harmonized Sales Tax number
    case bn       // Canada — Business Number
    case ein      // United States — Employer Identification Number
    case ssn      // United States — Social Security Number
    case vat      // EU/UK — Value Added Tax number
    case utr      // UK — Unique Taxpayer Reference
    case crn      // UK — Company Registration Number
    case ird       // New Zealand — Inland Revenue Department number
    case cnpj     // Brazil — Cadastro Nacional de Pessoas Jurídicas
    case cpf      // Brazil — Cadastro de Pessoas Físicas
    case custom   // Fallback

    var localizedLabel: String {
        switch self {
        case .abn:  return "ABN"
        case .tfn:  return "TFN"
        case .acn:  return "ACN"
        case .gst:  return "GST Number"
        case .hst:  return "HST Number"
        case .bn:   return "Business Number"
        case .ein:  return "EIN"
        case .ssn:  return "SSN"
        case .vat:  return "VAT Number"
        case .utr:  return "UTR"
        case .crn:  return "Company Number"
        case .ird:  return "IRD Number"
        case .cnpj: return "CNPJ"
        case .cpf:  return "CPF"
        case .custom: return "Tax Number"
        }
    }

    var placeholder: String {
        switch self {
        case .abn:  return "12 345 678 901"
        case .tfn:  return "123 456 789"
        case .acn:  return "123 456 789"
        case .gst:  return "123456789RT0001"
        case .hst:  return "123456789RT0001"
        case .bn:   return "123456789RC0001"
        case .ein:  return "12-3456789"
        case .ssn:  return "123-45-6789"
        case .vat:  return "GB123456789"
        case .utr:  return "1234567890"
        case .crn:  return "12345678"
        case .ird:  return "123-456-789"
        case .cnpj: return "12.345.678/0001-90"
        case .cpf:  return "123.456.789-09"
        case .custom: return "Tax identifier"
        }
    }
}

extension LocaleSettings {
    /// Primary business tax identifier for the selected country.
    var primaryBusinessTaxIdentifier: TaxIdentifierKind {
        switch country {
        case "AU": return .abn
        case "US": return .ein
        case "GB": return .vat
        case "CA": return .bn
        case "NZ": return .ird
        case "BR": return .cnpj
        default:
            if EUCountries.contains(country) { return .vat }
            return .custom
        }
    }

    /// Secondary identifier commonly collected for the selected country.
    var secondaryBusinessTaxIdentifier: TaxIdentifierKind? {
        switch country {
        case "AU": return .acn
        case "CA": return .gst
        case "US": return nil
        case "GB": return .crn
        default: return nil
        }
    }

    /// Default currency code for the country.
    var defaultCurrency: String {
        switch country {
        case "AU": return "AUD"
        case "US": return "USD"
        case "GB": return "GBP"
        case "CA": return "CAD"
        case "NZ": return "NZD"
        case "BR": return "BRL"
        case "JP": return "JPY"
        default:
            if EUCountries.contains(country) { return "EUR" }
            return "USD"
        }
    }

    /// Localised name for sales tax (used on invoices and accounts).
    var salesTaxLabel: String {
        switch country {
        case "AU", "NZ": return "GST"
        case "GB": return "VAT"
        case "CA": return "GST/HST"
        case "US": return "Sales Tax"
        case "JP": return "Consumption Tax"
        default:
            if EUCountries.contains(country) { return "VAT" }
            return "Tax"
        }
    }

    /// Countries currently supported by the built-in blacklist verifier.
    var supportsBlacklistVerification: Bool {
        ["AU"].contains(country)
    }
}

private let EUCountries: Set<String> = [
    "AT", "BE", "BG", "HR", "CY", "CZ", "DK", "EE", "FI", "FR", "DE",
    "GR", "HU", "IE", "IT", "LV", "LT", "LU", "MT", "NL", "PL", "PT",
    "RO", "SK", "SI", "ES", "SE"
]
