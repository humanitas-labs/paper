import Foundation

// The Ambient Context Protocol's types, version 0.2.0, and the interface an
// app implements to answer its two questions. Nothing in this file or in
// `ContextServer.swift` knows about Paper, so both can be lifted into
// another app unchanged.

/// One block of an element's content, in MCP's `ContentBlock` form.
enum ContextContent: Equatable, Sendable, Encodable {
    case text(String)
    case image(data: Data, mimeType: String)
    case resourceLink(uri: String, name: String)

    private enum Key: String, CodingKey { case type, text, data, mimeType, uri, name }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: Key.self)
        switch self {
        case .text(let text):
            try values.encode("text", forKey: .type)
            try values.encode(text, forKey: .text)
        case .image(let data, let mimeType):
            try values.encode("image", forKey: .type)
            try values.encode(data.base64EncodedString(), forKey: .data)
            try values.encode(mimeType, forKey: .mimeType)
        case .resourceLink(let uri, let name):
            try values.encode("resource_link", forKey: .type)
            try values.encode(uri, forKey: .uri)
            try values.encode(name, forKey: .name)
        }
    }
}

/// A free-form value for an element's `attributes`.
enum ContextValue: Equatable, Sendable, Encodable {
    case string(String)
    case number(Double)
    case integer(Int)
    case bool(Bool)
    case array([ContextValue])
    case object([String: ContextValue])

    func encode(to encoder: Encoder) throws {
        var value = encoder.singleValueContainer()
        switch self {
        case .string(let string): try value.encode(string)
        case .number(let number): try value.encode(number)
        case .integer(let integer): try value.encode(integer)
        case .bool(let bool): try value.encode(bool)
        case .array(let array): try value.encode(array)
        case .object(let object): try value.encode(object)
        }
    }
}

// An attribute reads as the JSON it becomes: `["ref": "T-12", "done": false]`.
extension ContextValue: ExpressibleByStringLiteral, ExpressibleByBooleanLiteral, ExpressibleByIntegerLiteral,
    ExpressibleByFloatLiteral, ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral {
    init(stringLiteral value: String) { self = .string(value) }
    init(booleanLiteral value: Bool) { self = .bool(value) }
    init(integerLiteral value: Int) { self = .integer(value) }
    init(floatLiteral value: Double) { self = .number(value) }
    init(arrayLiteral elements: ContextValue...) { self = .array(elements) }
    init(dictionaryLiteral elements: (String, ContextValue)...) {
        self = .object(Dictionary(elements, uniquingKeysWith: { _, last in last }))
    }
}

/// How an element is shown: the protocol's thirteen roles.
enum ContextRole: String, Equatable, Sendable, Encodable {
    case application = "Application"
    case window = "Window"
    case group = "Group"
    case list = "List"
    case table = "Table"
    case row = "Row"
    case cell = "Cell"
    case text = "Text"
    case heading = "Heading"
    case link = "Link"
    case image = "Image"
    case page = "Page"
    case document = "Document"
}

/// One thing the app shows: the app, a window, a document, selected
/// text. The provider's answer to `current` is one of these, the app,
/// with the rest inside it.
struct ContextElement: Equatable, Sendable, Encodable {
    var id: String
    var role: ContextRole
    /// What the thing is, in the app's own word.
    var subrole: String?
    var title: String?
    var content: [ContextContent]?
    var url: String?
    var selected = false
    /// The keyboard is here or inside here. Set along the whole path
    /// from a window down to where the user is.
    var focused = false
    /// Drawn on screen now. Nil follows the parent.
    var visible: Bool?
    /// The pointer is over this now. At most one element in an answer.
    var hovered = false
    var children: [ContextElement] = []
    var attributes: [String: ContextValue]?

    private enum Key: String, CodingKey {
        case id, role, subrole, title, content, url, selected, focused, visible, hovered, children, attributes
    }

    /// The three states that default to false are sent only when true,
    /// and an empty list of children is not sent.
    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: Key.self)
        try values.encode(id, forKey: .id)
        try values.encode(role, forKey: .role)
        try values.encodeIfPresent(subrole, forKey: .subrole)
        try values.encodeIfPresent(title, forKey: .title)
        try values.encodeIfPresent(content, forKey: .content)
        try values.encodeIfPresent(url, forKey: .url)
        if selected { try values.encode(true, forKey: .selected) }
        if focused { try values.encode(true, forKey: .focused) }
        try values.encodeIfPresent(visible, forKey: .visible)
        if hovered { try values.encode(true, forKey: .hovered) }
        if !children.isEmpty { try values.encode(children, forKey: .children) }
        try values.encodeIfPresent(attributes, forKey: .attributes)
    }

    /// This element and everything inside it, parents first.
    var all: [ContextElement] { [self] + children.flatMap(\.all) }
}

/// A rectangle in global display coordinates: points, origin at the top
/// left of the primary display, y increasing downward.
struct ContextRect: Equatable, Sendable, Encodable {
    var x: Double
    var y: Double
    var w: Double
    var h: Double
}

/// Where an element is on screen, at one moment.
struct ContextLocation: Equatable, Sendable, Encodable {
    enum State: String, Sendable, Encodable { case visible, offscreen, gone }
    enum Edge: String, Sendable, Encodable { case left, right, top, bottom }

    var id: String
    var state: State
    var rects: [ContextRect]?
    var window: Int?
    var avoid: ContextRect?
    var edge: Edge?

    static func gone(_ id: String) -> ContextLocation {
        ContextLocation(id: id, state: .gone)
    }
}

/// What an app implements to be a provider.
@MainActor
protocol ContextProvider: AnyObject, Sendable {
    /// What the app shows, as one tree rooted at the app, from state
    /// already in memory.
    func current() -> ContextElement
    /// Where the element is, or nil for an id this run never issued. An
    /// element that was issued and no longer exists is a location whose
    /// state is `gone`.
    func locate(_ id: String) -> ContextLocation?
}
