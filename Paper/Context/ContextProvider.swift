import Foundation

// The Ambient Context Protocol's types, draft 0.1, and the interface an
// app implements to answer its two questions. Nothing in this file or in
// `ContextServer.swift` knows about Paper, so both can be lifted into
// another app unchanged.

/// One block of an item's content, in MCP's `ContentBlock` form.
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

/// A free-form value for an item's `payload`.
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

/// One thing the user has open or selected.
struct ContextItem: Equatable, Sendable, Encodable {
    var id: String
    var type: String
    var title: String
    var content: [ContextContent]?
    var url: String?
    var parent: String?
    var locatable: Bool?
    var payload: [String: ContextValue]?
}

/// The provider's answer to `current`, before the server adds the app
/// and the instance.
struct ContextCurrent: Equatable, Sendable {
    var focus: [String] = []
    var items: [ContextItem] = []
}

/// A rectangle in global display coordinates: points, origin at the top
/// left of the primary display, y increasing downward.
struct ContextRect: Equatable, Sendable, Encodable {
    var x: Double
    var y: Double
    var w: Double
    var h: Double
}

/// Where an item is on screen, at one moment.
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
    /// What the user has open and in focus, from state already in memory.
    func current() -> ContextCurrent
    /// Where the item is, or nil for an id this run never issued. An item
    /// that was issued and no longer exists is a location whose state is
    /// `gone`.
    func locate(_ id: String) -> ContextLocation?
}
