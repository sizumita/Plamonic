import ApplicationServices
import CoreGraphics
import Foundation

/// Attribute names used across the app (standard ones plus Chromium / WebKit extensions).
enum AXAttr {
    static let role = "AXRole"
    static let subrole = "AXSubrole"
    static let roleDescription = "AXRoleDescription"
    static let children = "AXChildren"
    static let parent = "AXParent"
    static let position = "AXPosition"
    static let size = "AXSize"
    static let value = "AXValue"
    static let title = "AXTitle"
    static let description = "AXDescription"
    static let help = "AXHelp"
    static let identifier = "AXIdentifier"
    static let domClassList = "AXDOMClassList"
    static let domIdentifier = "AXDOMIdentifier"
    static let enabled = "AXEnabled"
    static let focused = "AXFocused"
    static let window = "AXWindow"
    static let windows = "AXWindows"
    static let focusedWindow = "AXFocusedWindow"
    static let mainWindow = "AXMainWindow"
    static let focusedUIElement = "AXFocusedUIElement"
    static let minimized = "AXMinimized"
    static let visibleCharacterRange = "AXVisibleCharacterRange"
    static let numberOfCharacters = "AXNumberOfCharacters"
    static let selectedText = "AXSelectedText"
    static let selectedTextRange = "AXSelectedTextRange"
    static let selectedTextMarkerRange = "AXSelectedTextMarkerRange"
    /// Where a link leads (CFURL).
    static let url = "AXURL"
    static let manualAccessibility = "AXManualAccessibility"
    static let enhancedUserInterface = "AXEnhancedUserInterface"
}

/// Parameterized attribute names.
enum AXParamAttr {
    static let boundsForRange = "AXBoundsForRange"
    static let stringForRange = "AXStringForRange"
    static let lineForIndex = "AXLineForIndex"
    static let rangeForLine = "AXRangeForLine"
    static let stringForTextMarkerRange = "AXStringForTextMarkerRange"
    static let boundsForTextMarkerRange = "AXBoundsForTextMarkerRange"
    static let attributedStringForRange = "AXAttributedStringForRange"
    /// Chromium / WebKit: the text marker range covering one element's text (parameter: the element itself).
    static let textMarkerRangeForUIElement = "AXTextMarkerRangeForUIElement"
    static let attributedStringForTextMarkerRange = "AXAttributedStringForTextMarkerRange"
}

/// Keys of the attributed strings returned by the AXAttributedString* attributes.
enum AXTextAttr {
    static let font = "AXFont"
    static let foregroundColor = "AXForegroundColor"
    /// NSNumber, non-zero when the run is underlined.
    static let underline = "AXUnderline"
    /// Native text views mark link runs with the link's element.
    static let link = "AXLink"
    /// Keys inside the AXFont dictionary.
    static let fontSize = "AXFontSize"
    static let fontName = "AXFontName"
    static let fontFamily = "AXFontFamily"
}

/// Messaging timeout applied process-wide the first time an AXElement is created.
enum AXElementDefaults {
    static let messagingTimeout: Float = 0.25

    private static let configured: Void = {
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), messagingTimeout)
    }()

    static func configureOnce() { _ = configured }

    /// Overrides the process-wide timeout (seconds). 0 restores the system default.
    static func setGlobalMessagingTimeout(_ seconds: Float) {
        configureOnce()
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), seconds)
    }
}

/// Thin value wrapper around AXUIElement. Equality is CFEqual (same underlying UI element).
/// AXUIElement calls are thread-safe; each call is one IPC to the target process.
struct AXElement: Hashable, @unchecked Sendable {
    let ref: AXUIElement

    init(_ ref: AXUIElement) {
        self.ref = ref
    }

    static func application(pid: pid_t) -> AXElement {
        AXElementDefaults.configureOnce()
        return AXElement(AXUIElementCreateApplication(pid))
    }

    static var systemWide: AXElement {
        AXElementDefaults.configureOnce()
        return AXElement(AXUIElementCreateSystemWide())
    }

    var pid: pid_t? {
        var p: pid_t = 0
        return AXUIElementGetPid(ref, &p) == .success ? p : nil
    }

    /// Per-element override of the messaging timeout.
    func setMessagingTimeout(_ seconds: Float) {
        AXUIElementSetMessagingTimeout(ref, seconds)
    }

    // MARK: Single attributes

    func copyAttribute(_ name: String) -> Result<AnyObject, AXCallError> {
        var value: AnyObject?
        let err = AXUIElementCopyAttributeValue(ref, name as CFString, &value)
        if err == .success, let value { return .success(value) }
        return .failure(AXCallError(code: err == .success ? .noValue : err))
    }

    func attribute(_ name: String) -> AnyObject? {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(ref, name as CFString, &value) == .success else { return nil }
        return value
    }

    func string(_ name: String) -> String? { AXDecode.string(attribute(name)) }
    func bool(_ name: String) -> Bool? { AXDecode.bool(attribute(name)) }
    func element(_ name: String) -> AXElement? { AXDecode.element(attribute(name)) }
    func elements(_ name: String) -> [AXElement] { AXDecode.elements(attribute(name)) }
    func range(_ name: String) -> CFRange? { AXDecode.range(attribute(name)) }

    var role: String? { string(AXAttr.role) }
    var subrole: String? { string(AXAttr.subrole) }
    var children: [AXElement] { elements(AXAttr.children) }
    var parent: AXElement? { element(AXAttr.parent) }

    /// Position + size in AX coordinates (two IPCs; use `fetch` when reading several attributes).
    var frame: CGRect? {
        guard let p = AXDecode.point(attribute(AXAttr.position)), let s = AXDecode.size(attribute(AXAttr.size))
        else { return nil }
        return CGRect(origin: p, size: s)
    }

    func attributeNames() -> [String] {
        var names: CFArray?
        guard AXUIElementCopyAttributeNames(ref, &names) == .success else { return [] }
        return (names as? [String]) ?? []
    }

    func parameterizedAttributeNames() -> [String] {
        var names: CFArray?
        guard AXUIElementCopyParameterizedAttributeNames(ref, &names) == .success else { return [] }
        return (names as? [String]) ?? []
    }

    func isSettable(_ name: String) -> Bool {
        var settable = DarwinBoolean(false)
        guard AXUIElementIsAttributeSettable(ref, name as CFString, &settable) == .success else { return false }
        return settable.boolValue
    }

    @discardableResult
    func setAttribute(_ name: String, _ value: AnyObject) -> AXError {
        AXUIElementSetAttributeValue(ref, name as CFString, value)
    }

    @discardableResult
    func setAttribute(_ name: String, bool: Bool) -> AXError {
        AXUIElementSetAttributeValue(ref, name as CFString, (bool ? kCFBooleanTrue : kCFBooleanFalse) as CFTypeRef)
    }

    // MARK: Parameterized attributes

    func parameterized(_ name: String, _ parameter: AnyObject) -> AnyObject? {
        var value: AnyObject?
        guard AXUIElementCopyParameterizedAttributeValue(ref, name as CFString, parameter, &value) == .success
        else { return nil }
        return value
    }

    /// Like `parameterized`, keeping the error (callers tell "unsupported" from a timeout).
    func parameterizedResult(_ name: String, _ parameter: AnyObject) -> Result<AnyObject, AXCallError> {
        var value: AnyObject?
        let err = AXUIElementCopyParameterizedAttributeValue(ref, name as CFString, parameter, &value)
        if err == .success, let value { return .success(value) }
        return .failure(AXCallError(code: err == .success ? .noValue : err))
    }

    /// AXBoundsForRange; `range` is in UTF-16 units of the element's value.
    func bounds(forRange range: CFRange) -> CGRect? {
        guard let param = AXDecode.makeValue(range) else { return nil }
        return AXDecode.rect(parameterized(AXParamAttr.boundsForRange, param))
    }

    /// AXStringForRange; `range` is in UTF-16 units.
    func string(forRange range: CFRange) -> String? {
        guard let param = AXDecode.makeValue(range) else { return nil }
        return AXDecode.string(parameterized(AXParamAttr.stringForRange, param))
    }

    // MARK: Hit testing

    /// Element at an AX point. On an application element only that app's windows are considered.
    func element(atAX point: CGPoint) -> AXElement? {
        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(ref, Float(point.x), Float(point.y), &hit) == .success, let hit
        else { return nil }
        return AXElement(hit)
    }

    // MARK: Batched fetch

    /// One IPC for all attributes of `plan`. nil when the element is gone or the app did not answer.
    func fetch(_ plan: AXFetchPlan) -> AXNodeInfo? {
        switch fetchResult(plan) {
        case .success(let info): return info
        case .failure: return nil
        }
    }

    func fetchResult(_ plan: AXFetchPlan) -> Result<AXNodeInfo, AXCallError> {
        var values: CFArray?
        let err = AXUIElementCopyMultipleAttributeValues(
            ref, plan.cfNames, AXCopyMultipleAttributeOptions(rawValue: 0), &values)
        guard err == .success, let array = values as? [AnyObject] else {
            return .failure(AXCallError(code: err == .success ? .failure : err))
        }
        return .success(plan.decode(element: self, values: array))
    }
}

/// An AXError as a Swift error. `isGone` means the element (or its process) no longer exists.
struct AXCallError: Error, Sendable {
    var code: AXError
    var isGone: Bool { code == .invalidUIElement || code == .invalidUIElementObserver }
    var isTimeout: Bool { code == .cannotComplete }
}

/// Which attributes a batched fetch reads.
struct AXFetchSet: OptionSet, Hashable, Sendable {
    let rawValue: UInt32
    init(rawValue: UInt32) { self.rawValue = rawValue }

    static let role = AXFetchSet(rawValue: 1 << 0)
    static let subrole = AXFetchSet(rawValue: 1 << 1)
    static let roleDescription = AXFetchSet(rawValue: 1 << 2)
    static let children = AXFetchSet(rawValue: 1 << 3)
    static let frame = AXFetchSet(rawValue: 1 << 4)  // position + size
    static let value = AXFetchSet(rawValue: 1 << 5)
    static let title = AXFetchSet(rawValue: 1 << 6)
    static let description = AXFetchSet(rawValue: 1 << 7)
    static let domClassList = AXFetchSet(rawValue: 1 << 8)
    static let identifier = AXFetchSet(rawValue: 1 << 9)
    static let enabled = AXFetchSet(rawValue: 1 << 10)
    static let focused = AXFetchSet(rawValue: 1 << 11)
    static let visibleCharacterRange = AXFetchSet(rawValue: 1 << 12)
    static let parent = AXFetchSet(rawValue: 1 << 13)

    static let structure: AXFetchSet = [.role, .subrole, .children, .frame, .domClassList]
    static let all: AXFetchSet = [
        .role, .subrole, .roleDescription, .children, .frame, .value, .title, .description, .domClassList,
        .identifier, .enabled, .focused, .visibleCharacterRange, .parent,
    ]
}

/// Precomputed attribute list for `AXElement.fetch`. Build once and reuse across many elements.
struct AXFetchPlan: @unchecked Sendable {
    let set: AXFetchSet
    let names: [String]
    let cfNames: CFArray
    private let index: [Int]  // index[field] = position in `names`, or -1

    private enum Field: Int, CaseIterable {
        case role, subrole, roleDescription, children, position, size, value, title, description, domClassList,
            identifier, enabled, focused, visibleCharacterRange, parent
    }

    init(_ set: AXFetchSet) {
        self.set = set
        var names: [String] = []
        var index = [Int](repeating: -1, count: Field.allCases.count)
        func add(_ field: Field, _ name: String, _ flag: AXFetchSet) {
            guard set.contains(flag) else { return }
            index[field.rawValue] = names.count
            names.append(name)
        }
        add(.role, AXAttr.role, .role)
        add(.subrole, AXAttr.subrole, .subrole)
        add(.roleDescription, AXAttr.roleDescription, .roleDescription)
        add(.children, AXAttr.children, .children)
        add(.position, AXAttr.position, .frame)
        add(.size, AXAttr.size, .frame)
        add(.value, AXAttr.value, .value)
        add(.title, AXAttr.title, .title)
        add(.description, AXAttr.description, .description)
        add(.domClassList, AXAttr.domClassList, .domClassList)
        add(.identifier, AXAttr.identifier, .identifier)
        add(.enabled, AXAttr.enabled, .enabled)
        add(.focused, AXAttr.focused, .focused)
        add(.visibleCharacterRange, AXAttr.visibleCharacterRange, .visibleCharacterRange)
        add(.parent, AXAttr.parent, .parent)
        self.names = names
        self.cfNames = names as CFArray
        self.index = index
    }

    fileprivate func decode(element: AXElement, values: [AnyObject]) -> AXNodeInfo {
        func raw(_ field: Field) -> AnyObject? {
            let i = index[field.rawValue]
            guard i >= 0, i < values.count else { return nil }
            let v = values[i]
            return AXDecode.isErrorOrNull(v) ? nil : v
        }
        var info = AXNodeInfo(element: element)
        info.role = AXDecode.string(raw(.role)) ?? ""
        info.subrole = AXDecode.string(raw(.subrole))
        info.roleDescription = AXDecode.string(raw(.roleDescription))
        info.children = AXDecode.elements(raw(.children))
        if let p = AXDecode.point(raw(.position)), let s = AXDecode.size(raw(.size)) {
            info.frame = CGRect(origin: p, size: s)
        }
        info.rawValue = raw(.value)
        info.title = AXDecode.string(raw(.title))
        info.descriptionText = AXDecode.string(raw(.description))
        info.domClasses = (raw(.domClassList) as? [String]) ?? []
        info.identifier = AXDecode.string(raw(.identifier))
        info.enabled = AXDecode.bool(raw(.enabled))
        info.focused = AXDecode.bool(raw(.focused))
        info.visibleCharacterRange = AXDecode.range(raw(.visibleCharacterRange))
        info.parent = AXDecode.element(raw(.parent))
        return info
    }
}

/// Typed result of a batched fetch. Fields not in the plan stay nil / empty.
struct AXNodeInfo: @unchecked Sendable {
    var element: AXElement
    var role: String = ""
    var subrole: String?
    var roleDescription: String?
    var children: [AXElement] = []
    var frame: CGRect?
    /// AXValue as returned (String, NSNumber, AXValue, ...). Use `stringValue` for text.
    var rawValue: AnyObject?
    var title: String?
    var descriptionText: String?
    var domClasses: [String] = []
    var identifier: String?
    var enabled: Bool?
    var focused: Bool?
    var visibleCharacterRange: CFRange?
    var parent: AXElement?

    init(element: AXElement) {
        self.element = element
    }

    var stringValue: String? { AXDecode.string(rawValue) }
}

/// Decoding helpers for CF values returned by the AX API.
enum AXDecode {
    static func isErrorOrNull(_ v: AnyObject) -> Bool {
        if v is NSNull { return true }
        if CFGetTypeID(v) == AXValueGetTypeID() {
            return AXValueGetType(unsafeBitCast(v, to: AXValue.self)) == .axError
        }
        return false
    }

    static func axValue(_ v: AnyObject?, _ type: AXValueType) -> AXValue? {
        guard let v, CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
        let value = unsafeBitCast(v, to: AXValue.self)
        return AXValueGetType(value) == type ? value : nil
    }

    static func point(_ v: AnyObject?) -> CGPoint? {
        guard let value = axValue(v, .cgPoint) else { return nil }
        var p = CGPoint.zero
        return AXValueGetValue(value, .cgPoint, &p) ? p : nil
    }

    static func size(_ v: AnyObject?) -> CGSize? {
        guard let value = axValue(v, .cgSize) else { return nil }
        var s = CGSize.zero
        return AXValueGetValue(value, .cgSize, &s) ? s : nil
    }

    static func rect(_ v: AnyObject?) -> CGRect? {
        guard let value = axValue(v, .cgRect) else { return nil }
        var r = CGRect.zero
        return AXValueGetValue(value, .cgRect, &r) ? r : nil
    }

    static func range(_ v: AnyObject?) -> CFRange? {
        guard let value = axValue(v, .cfRange) else { return nil }
        var r = CFRange()
        return AXValueGetValue(value, .cfRange, &r) ? r : nil
    }

    static func string(_ v: AnyObject?) -> String? {
        guard let v else { return nil }
        if let s = v as? String { return s }
        if let a = v as? NSAttributedString { return a.string }
        return nil
    }

    static func bool(_ v: AnyObject?) -> Bool? {
        guard let v else { return nil }
        if let b = v as? Bool { return b }
        if let n = v as? NSNumber { return n.boolValue }
        return nil
    }

    static func element(_ v: AnyObject?) -> AXElement? {
        guard let v, CFGetTypeID(v) == AXUIElementGetTypeID() else { return nil }
        return AXElement(unsafeBitCast(v, to: AXUIElement.self))
    }

    static func elements(_ v: AnyObject?) -> [AXElement] {
        guard let array = v as? [AnyObject] else { return [] }
        var out: [AXElement] = []
        out.reserveCapacity(array.count)
        for item in array where CFGetTypeID(item) == AXUIElementGetTypeID() {
            out.append(AXElement(unsafeBitCast(item, to: AXUIElement.self)))
        }
        return out
    }

    static func makeValue(_ range: CFRange) -> AXValue? {
        var r = range
        return AXValueCreate(.cfRange, &r)
    }

    static func makeValue(_ point: CGPoint) -> AXValue? {
        var p = point
        return AXValueCreate(.cgPoint, &p)
    }
}
