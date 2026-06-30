import Foundation

// MARK: - Dynamic JSON Value Tree

/// Recursive JSON value that preserves the full structure for form-based editing.
indirect enum JSONValue: Equatable, Hashable {
  case string(String)
  case number(String)  // stored as string to preserve formatting (int vs double)
  case bool(Bool)
  case null
  case object([JSONField])
  case array([JSONValue])

  /// Initialize by parsing a JSON string.
  static func parse(_ jsonString: String) -> JSONValue? {
    guard let data = jsonString.data(using: .utf8),
      let obj = try? JSONSerialization.jsonObject(with: data)
    else { return nil }
    return convert(obj)
  }

  /// Convert Foundation JSON types to our JSONValue tree.
  private static func convert(_ value: Any) -> JSONValue {
    switch value {
    case let s as String: return .string(s)
    case let n as NSNumber:
      // Distinguish bools from numbers
      if CFGetTypeID(n) == CFBooleanGetTypeID() {
        return .bool(n.boolValue)
      }
      return .number(n.stringValue)
    case let b as Bool: return .bool(b)
    case is NSNull: return .null
    case let d as [String: Any]:
      let fields = d.sorted(by: { $0.key < $1.key }).map { k, v in
        JSONField(key: k, value: convert(v))
      }
      return .object(fields)
    case let a as [Any]:
      return .array(a.map { convert($0) })
    default:
      return .string("\(value)")
    }
  }

  /// Serialize back to JSON string.
  func toJSON(pretty: Bool = true) -> String {
    let obj = toFoundation()
    guard JSONSerialization.isValidJSONObject(obj) else { return "{}" }
    let opts: JSONSerialization.WritingOptions =
      pretty ? [.prettyPrinted, .sortedKeys] : [.sortedKeys]
    guard let data = try? JSONSerialization.data(withJSONObject: obj, options: opts),
      let str = String(data: data, encoding: .utf8)
    else { return "{}" }
    return str
  }

  /// Convert back to Foundation types for serialization.
  func toFoundation() -> Any {
    switch self {
    case .string(let s): return s
    case .number(let s): return Double(s) ?? Int(s) ?? s
    case .bool(let b): return b
    case .null: return NSNull()
    case .object(let fields):
      var dict = [String: Any]()
      for f in fields { dict[f.key] = f.value.toFoundation() }
      return dict
    case .array(let items):
      return items.map { $0.toFoundation() }
    }
  }

  // MARK: - Type helpers

  var typeName: String {
    switch self {
    case .string: "String"
    case .number: "Number"
    case .bool: "Bool"
    case .null: "Null"
    case .object: "Object"
    case .array: "Array"
    }
  }

  var displayPreview: String {
    switch self {
    case .string(let s): return "\"\(s.prefix(30))\(s.count > 30 ? "…" : "")\""
    case .number(let s): return s
    case .bool(let b): return b ? "true" : "false"
    case .null: return "null"
    case .object(let f): return "{ \(f.count) field\(f.count == 1 ? "" : "s") }"
    case .array(let a): return "[ \(a.count) item\(a.count == 1 ? "" : "s") ]"
    }
  }
}

// MARK: - JSON Field

struct JSONField: Identifiable, Equatable, Hashable {
  let id = UUID()
  var key: String
  var value: JSONValue
  var isNew: Bool = false

  func hash(into hasher: inout Hasher) { hasher.combine(id) }
  static func == (lhs: JSONField, rhs: JSONField) -> Bool { lhs.id == rhs.id }
}

// MARK: - JSON Form Section (for nested navigation)

/// Represents a section of the JSON tree that can be navigated into.
struct JSONFormSection: Identifiable, Hashable {
  let id = UUID()
  let title: String
  let value: JSONValue
  let path: String  // breadcrumb path like "root > metadata > tags"
}
