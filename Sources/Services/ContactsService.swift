import Foundation
@preconcurrency import Contacts

// MARK: - Contacts service

/// SwiftMaestro integration with the macOS Contacts app via the public
/// `Contacts` framework. Store operations run on a private background actor so
/// they never block the UI thread; only plain `Sendable` structs cross back.
@Observable
@MainActor
final class ContactsService {

    enum AuthorizationStatus: Equatable, Sendable {
        case notDetermined
        case authorized
        case denied
        case restricted
    }

    enum ContactsError: LocalizedError {
        case accessDenied
        case notFound
        case saveFailed(String)
        case validation(String)

        var errorDescription: String? {
            switch self {
            case .accessDenied:
                return "Contacts access was denied. Grant it in System Settings → Privacy & Security → Contacts."
            case .notFound:
                return "Contact not found."
            case .saveFailed(let msg):
                return "Could not save contact: \(msg)"
            case .validation(let msg):
                return "Invalid contact: \(msg)"
            }
        }
    }

    private(set) var status: AuthorizationStatus = .notDetermined
    private let storeActor = ContactsStoreActor()

    // MARK: - Authorization

    func refreshStatus() {
        status = ContactsStoreActor.currentAuthorizationStatus()
    }

    func requestAccess() async {
        status = await storeActor.requestAccess()
    }

    // MARK: - Read

    /// Fetch all contacts, optionally filtered by a search string that matches
    /// name, organization, phone, email, or URL.
    func searchContacts(query: String? = nil, limit: Int = 100) async throws -> [Contact] {
        try await ensureAccess()
        return try await storeActor.searchContacts(query: query, limit: limit)
    }

    func contact(withIdentifier identifier: String) async throws -> Contact? {
        try await ensureAccess()
        return try await storeActor.contact(withIdentifier: identifier)
    }

    // MARK: - Write

    /// Create a new contact from the supplied model. The model's `id` is ignored.
    func createContact(_ contact: Contact) async throws -> String {
        try await ensureAccess()
        return try await storeActor.createContact(contact)
    }

    /// Update an existing contact. The model's `id` must match a stored contact.
    func updateContact(_ contact: Contact) async throws {
        try await ensureAccess()
        guard let id = contact.id, !id.isEmpty else {
            throw ContactsError.validation("contact id is required for updates")
        }
        try await storeActor.updateContact(contact, identifier: id)
    }

    func deleteContact(identifier: String) async throws {
        try await ensureAccess()
        try await storeActor.deleteContact(identifier: identifier)
    }

    // MARK: - Private

    private func ensureAccess() async throws {
        if status == .notDetermined {
            await requestAccess()
        }
        guard status == .authorized else {
            throw ContactsError.accessDenied
        }
    }
}

// MARK: - Background store actor

/// Serializes all `CNContactStore` work on a dedicated background actor so the
/// main thread is never blocked by contact enumeration or save requests.
private actor ContactsStoreActor {

    private let store = CNContactStore()

    private static let fetchKeys: [CNKeyDescriptor] = [
        CNContactIdentifierKey as CNKeyDescriptor,
        CNContactGivenNameKey as CNKeyDescriptor,
        CNContactFamilyNameKey as CNKeyDescriptor,
        CNContactMiddleNameKey as CNKeyDescriptor,
        CNContactNicknameKey as CNKeyDescriptor,
        CNContactOrganizationNameKey as CNKeyDescriptor,
        CNContactJobTitleKey as CNKeyDescriptor,
        CNContactDepartmentNameKey as CNKeyDescriptor,
        CNContactPhoneNumbersKey as CNKeyDescriptor,
        CNContactEmailAddressesKey as CNKeyDescriptor,
        CNContactPostalAddressesKey as CNKeyDescriptor,
        CNContactUrlAddressesKey as CNKeyDescriptor,
        CNContactThumbnailImageDataKey as CNKeyDescriptor,
        CNContactImageDataAvailableKey as CNKeyDescriptor
    ]

    static func currentAuthorizationStatus() -> ContactsService.AuthorizationStatus {
        switch CNContactStore.authorizationStatus(for: .contacts) {
        case .authorized:
            return .authorized
        case .denied:
            return .denied
        case .restricted:
            return .restricted
        case .notDetermined:
            return .notDetermined
        @unknown default:
            return .notDetermined
        }
    }

    func requestAccess() async -> ContactsService.AuthorizationStatus {
        do {
            let granted = try await store.requestAccess(for: .contacts)
            return granted ? .authorized : .denied
        } catch {
            return .denied
        }
    }

    func searchContacts(query: String?, limit: Int) async throws -> [Contact] {
        let request = CNContactFetchRequest(keysToFetch: Self.fetchKeys)
        let lowerQuery = query?.trimmingCharacters(in: .whitespaces).lowercased()

        var contacts: [CNContact] = []
        try store.enumerateContacts(with: request) { contact, _ in
            if contacts.count >= limit { return }
            if let lowerQuery, !lowerQuery.isEmpty {
                if Self.matches(contact: contact, query: lowerQuery) {
                    contacts.append(contact)
                }
            } else {
                contacts.append(contact)
            }
        }
        return contacts.map(Contact.init)
    }

    func contact(withIdentifier identifier: String) async throws -> Contact {
        let cnContact = try store.unifiedContact(
            withIdentifier: identifier,
            keysToFetch: Self.fetchKeys
        )
        return Contact(cnContact)
    }

    func createContact(_ contact: Contact) async throws -> String {
        let cn = CNMutableContact()
        apply(contact: contact, to: cn)
        let saveRequest = CNSaveRequest()
        saveRequest.add(cn, toContainerWithIdentifier: nil)
        try store.execute(saveRequest)
        return cn.identifier
    }

    func updateContact(_ contact: Contact, identifier: String) async throws {
        let existing = try store.unifiedContact(
            withIdentifier: identifier,
            keysToFetch: Self.fetchKeys
        )
        let mutable = existing.mutableCopy() as! CNMutableContact
        apply(contact: contact, to: mutable)
        let saveRequest = CNSaveRequest()
        saveRequest.update(mutable)
        try store.execute(saveRequest)
    }

    func deleteContact(identifier: String) async throws {
        let existing = try store.unifiedContact(
            withIdentifier: identifier,
            keysToFetch: Self.fetchKeys
        )
        let mutable = existing.mutableCopy() as! CNMutableContact
        let saveRequest = CNSaveRequest()
        saveRequest.delete(mutable)
        try store.execute(saveRequest)
    }

    // MARK: - Private

    private func apply(contact: Contact, to cn: CNMutableContact) {
        cn.givenName = contact.givenName
        cn.familyName = contact.familyName
        cn.middleName = contact.middleName
        cn.nickname = contact.nickname
        cn.organizationName = contact.organizationName
        cn.jobTitle = contact.jobTitle
        cn.departmentName = contact.departmentName

        cn.phoneNumbers = contact.phoneNumbers.map { phone in
            CNLabeledValue(label: Self.label(for: phone.label, default: CNLabelPhoneNumberMobile),
                           value: CNPhoneNumber(stringValue: phone.value))
        }

        cn.emailAddresses = contact.emailAddresses.map { email in
            CNLabeledValue(label: Self.label(for: email.label, default: CNLabelEmailiCloud),
                           value: email.value as NSString)
        }

        cn.urlAddresses = contact.urls.map { url in
            CNLabeledValue(label: Self.label(for: url.label, default: CNLabelURLAddressHomePage),
                           value: url.value as NSString)
        }

        cn.postalAddresses = contact.addresses.map { address in
            let mutable = CNMutablePostalAddress()
            mutable.street = address.street
            mutable.city = address.city
            mutable.state = address.state
            mutable.postalCode = address.postalCode
            mutable.country = address.country
            mutable.isoCountryCode = address.isoCountryCode
            return CNLabeledValue(label: Self.label(for: address.label, default: CNLabelHome),
                                  value: mutable)
        }
    }

    private static func matches(contact: CNContact, query: String) -> Bool {
        let fullName = "\(contact.givenName) \(contact.middleName) \(contact.familyName)".lowercased()
        if fullName.contains(query) { return true }
        if contact.nickname.lowercased().contains(query) { return true }
        if contact.organizationName.lowercased().contains(query) { return true }
        if contact.departmentName.lowercased().contains(query) { return true }
        if contact.jobTitle.lowercased().contains(query) { return true }
        for phone in contact.phoneNumbers {
            if phone.value.stringValue.lowercased().contains(query) { return true }
        }
        for email in contact.emailAddresses {
            let emailValue = email.value as String
            if emailValue.lowercased().contains(query) { return true }
        }
        return false
    }

    private static func label(for value: String?, default defaultLabel: String) -> String {
        guard let value, !value.isEmpty else { return defaultLabel }
        return value
    }
}

// MARK: - Contact model

struct Contact: Identifiable, Codable, Hashable, Sendable {
    var id: String?
    var givenName: String
    var familyName: String
    var middleName: String
    var nickname: String
    var fullName: String
    var organizationName: String
    var jobTitle: String
    var departmentName: String
    var phoneNumbers: [LabeledValue]
    var emailAddresses: [LabeledValue]
    var urls: [LabeledValue]
    var addresses: [PostalAddress]
    var hasImage: Bool

    struct LabeledValue: Codable, Hashable, Sendable {
        var label: String?
        var value: String
    }

    struct PostalAddress: Codable, Hashable, Sendable {
        var label: String?
        var street: String
        var city: String
        var state: String
        var postalCode: String
        var country: String
        var isoCountryCode: String
    }

    init(id: String? = nil,
         givenName: String = "",
         familyName: String = "",
         middleName: String = "",
         nickname: String = "",
         organizationName: String = "",
         jobTitle: String = "",
         departmentName: String = "",
         phoneNumbers: [LabeledValue] = [],
         emailAddresses: [LabeledValue] = [],
         urls: [LabeledValue] = [],
         addresses: [PostalAddress] = [],
         hasImage: Bool = false) {
        self.id = id
        self.givenName = givenName
        self.familyName = familyName
        self.middleName = middleName
        self.nickname = nickname
        self.fullName = [givenName, middleName, familyName]
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        self.organizationName = organizationName
        self.jobTitle = jobTitle
        self.departmentName = departmentName
        self.phoneNumbers = phoneNumbers
        self.emailAddresses = emailAddresses
        self.urls = urls
        self.addresses = addresses
        self.hasImage = hasImage
    }

    init(_ contact: CNContact) {
        self.id = contact.identifier
        self.givenName = contact.givenName
        self.familyName = contact.familyName
        self.middleName = contact.middleName
        self.nickname = contact.nickname
        self.fullName = [contact.givenName, contact.middleName, contact.familyName]
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        self.organizationName = contact.organizationName
        self.jobTitle = contact.jobTitle
        self.departmentName = contact.departmentName
        self.phoneNumbers = contact.phoneNumbers.map { LabeledValue(label: $0.label, value: $0.value.stringValue) }
        self.emailAddresses = contact.emailAddresses.map { LabeledValue(label: $0.label, value: $0.value as String) }
        self.urls = contact.urlAddresses.map { LabeledValue(label: $0.label, value: $0.value as String) }
        self.addresses = contact.postalAddresses.map {
            PostalAddress(
                label: $0.label,
                street: $0.value.street,
                city: $0.value.city,
                state: $0.value.state,
                postalCode: $0.value.postalCode,
                country: $0.value.country,
                isoCountryCode: $0.value.isoCountryCode
            )
        }
        self.hasImage = contact.imageDataAvailable
    }

    var displayName: String {
        if !fullName.isEmpty { return fullName }
        if !organizationName.isEmpty { return organizationName }
        return emailAddresses.first?.value ?? phoneNumbers.first?.value ?? "(unnamed)"
    }

    var initials: String {
        let parts = [givenName, familyName].filter { !$0.isEmpty }
        if parts.isEmpty { return "?" }
        return parts.compactMap { $0.first?.uppercased() }.joined()
    }
}

// MARK: - Empty helpers

extension Contact {
    static var empty: Contact {
        Contact()
    }
}
