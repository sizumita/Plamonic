import Foundation

/// The properties of an AX element that `ElementMatcher` looks at.
struct ElementTraits: Hashable, Sendable {
    var role: String
    var subrole: String?
    var roleDescription: String?
    var domClasses: [String]
    var identifier: String?

    init(
        role: String, subrole: String? = nil, roleDescription: String? = nil, domClasses: [String] = [],
        identifier: String? = nil
    ) {
        self.role = role
        self.subrole = subrole
        self.roleDescription = roleDescription
        self.domClasses = domClasses
        self.identifier = identifier
    }
}

extension AXNodeInfo {
    var traits: ElementTraits {
        ElementTraits(
            role: role, subrole: subrole, roleDescription: roleDescription, domClasses: domClasses,
            identifier: identifier)
    }
}

extension ElementDescriptor {
    var traits: ElementTraits {
        ElementTraits(
            role: role, subrole: subrole, roleDescription: roleDescription, domClasses: domClasses,
            identifier: identifier)
    }
}

extension ElementMatcher {
    /// Every non-empty field must match; within a field any value may match.
    /// Blank entries are ignored, and a matcher with no usable entries matches nothing.
    /// - roles / subroles: exact. roleDescriptions: case-insensitive, whole string.
    /// - domClassPrefixes: any DOM class starts with any prefix. identifierPrefixes: the identifier starts with any prefix.
    func matches(_ t: ElementTraits) -> Bool { CompiledMatcher(self).matches(t) }

    /// false when every field is empty or blank (such a matcher never matches).
    var isUsable: Bool { CompiledMatcher(self).isUsable }
    var usesRoleDescription: Bool { !CompiledMatcher(self).roleDescriptions.isEmpty }
    var usesIdentifier: Bool { !CompiledMatcher(self).identifierPrefixes.isEmpty }
    var usesDOMClasses: Bool { !CompiledMatcher(self).domClassPrefixes.isEmpty }
}

/// ElementMatcher with blank entries removed, for matching many elements quickly.
struct CompiledMatcher: Sendable {
    let roles: Set<String>
    let subroles: Set<String>
    let roleDescriptions: [String]
    let domClassPrefixes: [String]
    let identifierPrefixes: [String]

    init(_ m: ElementMatcher) {
        roles = Set(Self.clean(m.roles))
        subroles = Set(Self.clean(m.subroles))
        roleDescriptions = Self.clean(m.roleDescriptions)
        domClassPrefixes = Self.clean(m.domClassPrefixes)
        identifierPrefixes = Self.clean(m.identifierPrefixes)
    }

    var isUsable: Bool {
        !(roles.isEmpty && subroles.isEmpty && roleDescriptions.isEmpty && domClassPrefixes.isEmpty
            && identifierPrefixes.isEmpty)
    }

    func matches(_ t: ElementTraits) -> Bool {
        matches(
            role: t.role, subrole: t.subrole, roleDescription: t.roleDescription, domClasses: t.domClasses,
            identifier: t.identifier)
    }

    func matches(
        role: String, subrole: String?, roleDescription: String?, domClasses: [String], identifier: String?
    ) -> Bool {
        guard isUsable else { return false }
        if !roles.isEmpty, !roles.contains(role) { return false }
        if !subroles.isEmpty {
            guard let subrole, subroles.contains(subrole) else { return false }
        }
        if !roleDescriptions.isEmpty {
            guard let rd = roleDescription,
                roleDescriptions.contains(where: { $0.caseInsensitiveCompare(rd) == .orderedSame })
            else { return false }
        }
        if !domClassPrefixes.isEmpty {
            guard domClasses.contains(where: { cls in domClassPrefixes.contains(where: { cls.hasPrefix($0) }) })
            else { return false }
        }
        if !identifierPrefixes.isEmpty {
            guard let identifier, identifierPrefixes.contains(where: { identifier.hasPrefix($0) }) else {
                return false
            }
        }
        return true
    }

    func matches(_ info: AXNodeInfo) -> Bool {
        matches(
            role: info.role, subrole: info.subrole, roleDescription: info.roleDescription,
            domClasses: info.domClasses, identifier: info.identifier)
    }

    private static func clean(_ values: [String]) -> [String] {
        values.compactMap {
            let t = $0.trimmingCharacters(in: .whitespacesAndNewlines)
            return t.isEmpty ? nil : t
        }
    }
}

/// Compiled matchers of one ExtractionRules list.
struct CompiledMatcherSet: Sendable {
    let matchers: [CompiledMatcher]

    init(_ list: [ElementMatcher]) {
        matchers = list.map(CompiledMatcher.init).filter(\.isUsable)
    }

    var isEmpty: Bool { matchers.isEmpty }
    func matches(_ info: AXNodeInfo) -> Bool { matchers.contains { $0.matches(info) } }
    func matches(_ t: ElementTraits) -> Bool { matchers.contains { $0.matches(t) } }
}

extension Array where Element == ElementMatcher {
    func anyMatches(_ t: ElementTraits) -> Bool { contains { $0.matches(t) } }
}

extension ExtractionRules {
    var usesRoleDescription: Bool { (containers + items + excludes).contains { $0.usesRoleDescription } }
    var usesIdentifier: Bool { (containers + items + excludes).contains { $0.usesIdentifier } }
    var hasContainers: Bool { containers.contains { $0.isUsable } }
    var hasItems: Bool { items.contains { $0.isUsable } }
}
