import Foundation
import JavaScriptCore

/// What one shell statement evaluated to, before it is rendered as a result grid.
enum MongoScriptOutcome {
    /// A cursor nobody iterated yet: the driver runs it natively so documents keep their exact BSON types.
    case cursor(database: String, command: BSONDocument)
    case documents([BSONDocument], truncated: Bool)
    case document(BSONDocument)
    case values([BSONValue], truncated: Bool)
    case value(BSONValue)
    case message(String)
    case none
}

/// A mongosh-like JavaScript session. One per connection, so variables and `use` persist between runs.
///
/// Values cross the bridge as canonical Extended JSON strings; the prelude maps them to wrapper
/// objects (`ObjectId`, `NumberLong`, `Decimal128`, …) so every BSON type survives a round trip.
final class MongoScriptRuntime {
    private let context: JSContext
    private weak var connection: MongoConnection?
    private var output: [String] = []
    private var pendingException: JSValue?
    /// Swift errors raised inside native functions, so an uncaught one is rethrown as itself (for example `.cancelled`).
    private var nativeErrors: [Int: Error] = [:]
    private var nextErrorID = 1

    init(connection: MongoConnection) throws {
        guard let context = JSContext() else { throw DatabaseError.unsupported("JavaScriptCore is not available") }
        self.context = context
        self.connection = connection
        context.name = "Foxlume Query MQL"
        context.exceptionHandler = { [weak self] _, exception in
            self?.pendingException = exception
        }
        installNatives()
        pendingException = nil
        context.evaluateScript(Self.prelude)
        if let exception = pendingException {
            throw DatabaseError.protocolViolation("The MQL prelude failed to load: \(exception.toString() ?? "unknown error")")
        }
    }

    func setDatabase(_ name: String) {
        context.objectForKeyedSubscript("__eqSetDB")?.call(withArguments: [name])
    }

    // MARK: Running

    func run(_ statement: String, rowLimit: Int?) throws -> StatementResult {
        output = []
        nativeErrors = [:]
        guard let connection else { throw DatabaseError.notConnected }
        var code = statement.trimmingCharacters(in: .whitespacesAndNewlines)
        if code.hasSuffix(";") { code = String(code.dropLast()) }

        // `use x` and `show x` are shell commands, not JavaScript. The splitter only breaks before lines that start
        // with db./use/show, so such a line can also open a statement whose remaining lines are JavaScript.
        var last: StatementResult?
        while true {
            let lines = code.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
            let firstLine = lines.first.map { String($0).trimmingCharacters(in: CharacterSet(charactersIn: " \t;")) } ?? ""
            let rest = lines.count > 1 ? String(lines[1]).trimmingCharacters(in: .whitespacesAndNewlines) : ""
            if let name = Self.match(firstLine, #"^use\s+([^\s;]+)$"#) {
                try connection.useDatabase(name)
                last = StatementResult(message: "switched to db \(name)")
            } else if let target = Self.match(firstLine, #"^show\s+(\w+)$"#) {
                last = try connection.renderOutcome(try show(target.lowercased(), connection: connection), rowLimit: rowLimit, output: [])
            } else {
                break
            }
            code = rest
            if code.isEmpty, let last { return last }
        }

        let outcome = try evaluate(Self.prepare(code), rowLimit: rowLimit)
        return try connection.renderOutcome(outcome, rowLimit: rowLimit, output: output)
    }

    /// Evaluates one JavaScript expression, such as a filter document that uses `new Date(...)`.
    func evaluateExpression(_ expression: String) throws -> MongoScriptOutcome {
        output = []
        nativeErrors = [:]
        return try evaluate("(" + expression + "\n)", rowLimit: nil)
    }

    private func evaluate(_ code: String, rowLimit: Int?) throws -> MongoScriptOutcome {
        pendingException = nil
        let value = context.evaluateScript(code)
        try rethrowPending()
        guard let value, let describe = context.objectForKeyedSubscript("__eqDescribe") else { return .none }
        let described = describe.call(withArguments: [value, rowLimit ?? -1])
        try rethrowPending()
        guard let text = described?.toString() else { return .none }
        return try Self.outcome(fromDescription: text)
    }

    private func rethrowPending() throws {
        guard let exception = pendingException else { return }
        pendingException = nil
        if let id = exception.objectForKeyedSubscript("__eqErrorId"), id.isNumber, let error = nativeErrors[Int(id.toInt32())] {
            throw error
        }
        var message = exception.toString() ?? "JavaScript error"
        if let line = exception.objectForKeyedSubscript("line"), line.isNumber, line.toInt32() > 1 {
            message += " (line \(line.toInt32()))"
        }
        throw DatabaseError.server(message: message, code: nil)
    }

    static func outcome(fromDescription text: String) throws -> MongoScriptOutcome {
        guard case .object(let members) = try MongoLiteralParser.parse(text) else { return .none }
        let map = Dictionary(members.map { ($0.key, $0.value) }, uniquingKeysWith: { first, _ in first })
        guard case .string(let kind)? = map["kind"] else { return .none }
        let truncated = map["truncated"] == .bool(true)
        switch kind {
        case "cursor":
            guard case .string(let database)? = map["db"], case .document(let command)? = try map["command"]?.bson() else { return .none }
            return .cursor(database: database, command: command)
        case "documents":
            guard case .array(let items)? = try map["items"]?.bson() else { return .none }
            return .documents(items.compactMap(\.documentValue), truncated: truncated)
        case "values":
            guard case .array(let items)? = try map["items"]?.bson() else { return .none }
            return .values(items, truncated: truncated)
        case "document":
            guard case .document(let document)? = try map["doc"]?.bson() else { return .none }
            return .document(document)
        case "value":
            return .value(try map["value"]?.bson() ?? .null)
        case "message":
            guard case .string(let message)? = map["text"] else { return .none }
            return .message(message)
        default:
            return .none
        }
    }

    private func show(_ target: String, connection: MongoConnection) throws -> MongoScriptOutcome {
        let database = connection.databaseName
        switch target {
        case "dbs", "databases":
            let reply = try connection.runCommand(["listDatabases": .int32(1), "authorizedDatabases": .bool(true)], database: "admin")
            let documents = (reply["databases"]?.arrayValue ?? []).compactMap(\.documentValue).map { item -> BSONDocument in
                var row: BSONDocument = ["name": item["name"] ?? .null]
                if let size = item["sizeOnDisk"] { row["sizeOnDisk"] = size }
                if let empty = item["empty"] { row["empty"] = empty }
                return row
            }
            return .documents(documents.sorted { ($0["name"]?.stringValue ?? "") < ($1["name"]?.stringValue ?? "") }, truncated: false)
        case "collections", "tables":
            let (items, _) = try connection.cursorDocuments(
                ["listCollections": .int32(1), "nameOnly": .bool(true), "authorizedCollections": .bool(true), "cursor": .document([:])],
                database: database, limit: nil
            )
            let names = items.compactMap { $0["name"]?.stringValue }.sorted()
            return .values(names.map { .string($0) }, truncated: false)
        case "users":
            let reply = try connection.runCommand(["usersInfo": .int32(1)], database: database)
            return .documents((reply["users"]?.arrayValue ?? []).compactMap(\.documentValue), truncated: false)
        case "roles":
            let reply = try connection.runCommand(["rolesInfo": .int32(1), "showBuiltinRoles": .bool(true)], database: database)
            return .documents((reply["roles"]?.arrayValue ?? []).compactMap(\.documentValue), truncated: false)
        case "profile":
            return .cursor(database: database, command: ["find": .string("system.profile"), "filter": .document([:]), "sort": .document(["ts": .int32(-1)]), "limit": .int32(5)])
        default:
            throw DatabaseError.unsupported("\"show \(target)\" is not supported. Use show dbs, show collections, show users, show roles or show profile.")
        }
    }

    private static func match(_ text: String, _ pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let found = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(found.range(at: 1), in: text)
        else { return nil }
        return String(text[range])
    }

    /// REPL conveniences: top-level `let`/`const` become `var` so a statement can run twice, and `await` is dropped
    /// because every shell function here is synchronous.
    static func prepare(_ code: String) -> String {
        var text = code
        // Leading comments do not count: `// totals\nconst x = …` is still a top-level declaration.
        if let range = text.range(of: #"^(?:\s+|//[^\n]*(?:\n|$)|/\*[\s\S]*?\*/)*(let|const)\s+"#, options: .regularExpression),
           let keyword = text.range(of: #"(let|const)\s+$"#, options: .regularExpression, range: range)
        {
            text.replaceSubrange(keyword, with: "var ")
        }
        guard text.contains("await") else { return text }
        var result = ""
        var quote: Character?
        var escaped = false
        var index = text.startIndex
        while index < text.endIndex {
            let c = text[index]
            if let open = quote {
                result.append(c)
                if escaped {
                    escaped = false
                } else if c == "\\" {
                    escaped = true
                } else if c == open {
                    quote = nil
                }
                index = text.index(after: index)
                continue
            }
            if c == "\"" || c == "'" || c == "`" {
                quote = c
                result.append(c)
                index = text.index(after: index)
                continue
            }
            if text[index...].hasPrefix("await"), index == text.startIndex || !(text[text.index(before: index)].isLetter || text[text.index(before: index)].isNumber || text[text.index(before: index)] == "_" || text[text.index(before: index)] == "$" || text[text.index(before: index)] == ".") {
                let after = text.index(index, offsetBy: 5)
                if after < text.endIndex, text[after].isWhitespace {
                    index = after
                    while index < text.endIndex, text[index].isWhitespace { index = text.index(after: index) }
                    continue
                }
            }
            result.append(c)
            index = text.index(after: index)
        }
        return result
    }

    // MARK: Natives

    private func raise(_ error: Error) {
        guard let context = JSContext.current() else { return }
        let id = nextErrorID
        nextErrorID += 1
        nativeErrors[id] = error
        let message: String
        var code: Int?
        var codeName: String?
        switch error {
        case let server as MongoServerError:
            message = server.message
            code = server.code
            codeName = server.codeName
        case DatabaseError.server(let text, let serverCode, _):
            message = text
            codeName = serverCode
        default:
            message = (error as? LocalizedError)?.errorDescription ?? "\(error)"
        }
        guard let jsError = JSValue(newErrorFromMessage: message, in: context) else { return }
        jsError.setValue(id, forProperty: "__eqErrorId")
        if let code { jsError.setValue(code, forProperty: "code") }
        if let codeName { jsError.setValue(codeName, forProperty: "codeName") }
        context.exception = jsError
    }

    private func installNatives() {
        guard let native = JSValue(newObjectIn: context) else { return }

        let command: @convention(block) (String, String) -> String = { [weak self] database, text in
            guard let self, let connection = self.connection else { return "" }
            do {
                let document = try ExtendedJSON.parseDocument(text)
                let reply = try connection.runCommand(document, database: database)
                return ExtendedJSON.string(reply, mode: .canonical)
            } catch {
                self.raise(error)
                return ""
            }
        }
        native.setObject(command, forKeyedSubscript: "command" as NSString)

        let printLine: @convention(block) (String) -> Void = { [weak self] text in
            self?.output.append(contentsOf: text.components(separatedBy: "\n"))
        }
        native.setObject(printLine, forKeyedSubscript: "print" as NSString)

        let newObjectId: @convention(block) () -> String = { BSONObjectId.generate().hex }
        native.setObject(newObjectId, forKeyedSubscript: "newObjectId" as NSString)

        let format: @convention(block) (String, Bool) -> String = { [weak self] text, pretty in
            do {
                return MongoShellFormatter.format(try ExtendedJSON.parseValue(text), pretty: pretty)
            } catch {
                self?.raise(error)
                return ""
            }
        }
        native.setObject(format, forKeyedSubscript: "format" as NSString)

        let ejson: @convention(block) (String, Bool) -> String = { [weak self] text, relaxed in
            do {
                return ExtendedJSON.string(try ExtendedJSON.parseValue(text), mode: relaxed ? .relaxed : .canonical)
            } catch {
                self?.raise(error)
                return ""
            }
        }
        native.setObject(ejson, forKeyedSubscript: "ejson" as NSString)

        let parseDate: @convention(block) (String) -> Double = { text in
            ExtendedJSON.parseISODate(text).map { Double($0) } ?? .nan
        }
        native.setObject(parseDate, forKeyedSubscript: "parseDate" as NSString)

        let hexToBase64: @convention(block) (String) -> String = { [weak self] hex in
            guard let data = Data(hexString: hex.replacingOccurrences(of: "-", with: "")) else {
                self?.raise(DatabaseError.server(message: "Invalid hex string \"\(hex)\"", code: nil))
                return ""
            }
            return data.base64EncodedString()
        }
        native.setObject(hexToBase64, forKeyedSubscript: "hexToBase64" as NSString)

        let base64ToHex: @convention(block) (String) -> String = { base64 in
            Data(base64Encoded: base64)?.hexString ?? ""
        }
        native.setObject(base64ToHex, forKeyedSubscript: "base64ToHex" as NSString)

        let use: @convention(block) (String) -> String = { [weak self] name in
            do {
                try self?.connection?.useDatabase(name)
            } catch {
                self?.raise(error)
            }
            return "switched to db \(name)"
        }
        native.setObject(use, forKeyedSubscript: "use" as NSString)

        let sleep: @convention(block) (Double) -> Void = { [weak self] milliseconds in
            let deadline = Date().addingTimeInterval(max(0, milliseconds) / 1000)
            while Date() < deadline {
                if self?.connection?.isCancelRequested == true {
                    self?.raise(DatabaseError.cancelled)
                    return
                }
                usleep(UInt32(min(50_000, max(1, deadline.timeIntervalSinceNow * 1_000_000))))
            }
        }
        native.setObject(sleep, forKeyedSubscript: "sleep" as NSString)

        let version: @convention(block) () -> String = { [weak self] in self?.connection?.serverVersion ?? "" }
        native.setObject(version, forKeyedSubscript: "serverVersion" as NSString)

        let auth: @convention(block) (String, String, String, String) -> Bool = { [weak self] database, user, password, mechanism in
            guard let self, let connection = self.connection else { return false }
            do {
                let parsed = mechanism.isEmpty ? nil : MongoAuthMechanism(userText: mechanism)
                try connection.authenticate(user: user, password: password, source: database, mechanism: parsed)
                return true
            } catch {
                self.raise(error)
                return false
            }
        }
        native.setObject(auth, forKeyedSubscript: "auth" as NSString)

        context.setObject(native, forKeyedSubscript: "__eqNative" as NSString)
    }

    // MARK: Prelude

    // swiftlint:disable line_length
    static let prelude = #"""
    (function (global) {
      'use strict';
      const N = global.__eqNative;
      const INT32_MIN = -2147483648, INT32_MAX = 2147483647;
      const LONG_MIN = -(2n ** 63n), LONG_MAX = 2n ** 63n - 1n;

      function hidden(target, name, value) {
        Object.defineProperty(target, name, { value: value, enumerable: false, writable: true, configurable: true });
      }
      function hex2(n) { return (n < 16 ? '0' : '') + n.toString(16); }
      function numText(n) {
        if (Number.isNaN(n)) return 'NaN';
        if (n === Infinity) return 'Infinity';
        if (n === -Infinity) return '-Infinity';
        if (Object.is(n, -0)) return '-0.0';
        const s = String(n);
        return /[.eE]/.test(s) ? s : s + '.0';
      }

      // ---------- BSON wrapper types ----------
      function ObjectId(id) {
        if (!(this instanceof ObjectId)) return new ObjectId(id);
        let hex;
        if (id === undefined || id === null) hex = N.newObjectId();
        else if (id instanceof ObjectId) hex = id.$oid;
        else if (typeof id === 'number') hex = Math.floor(id).toString(16).padStart(8, '0') + '0000000000000000';
        else hex = String(id);
        if (!/^[0-9a-fA-F]{24}$/.test(hex)) throw new TypeError('ObjectId must be a 24 character hex string, got "' + hex + '"');
        hidden(this, '$oid', hex.toLowerCase());
      }
      hidden(ObjectId.prototype, '_bsontype', 'ObjectId');
      ObjectId.prototype.toHexString = function () { return this.$oid; };
      ObjectId.prototype.toString = function () { return this.$oid; };
      ObjectId.prototype.equals = function (other) { return other != null && String(other.$oid || other) === this.$oid; };
      ObjectId.prototype.getTimestamp = function () { return new Date(parseInt(this.$oid.slice(0, 8), 16) * 1000); };
      ObjectId.prototype.toJSON = function () { return { $oid: this.$oid }; };
      Object.defineProperty(ObjectId.prototype, 'str', { get: function () { return this.$oid; } });
      ObjectId.isValid = function (v) { try { new ObjectId(v); return true; } catch (e) { return false; } };
      ObjectId.createFromHexString = function (h) { return new ObjectId(h); };
      ObjectId.createFromTime = function (t) { return new ObjectId(Math.floor(t)); };

      function Long(v, high) {
        if (!(this instanceof Long)) return new Long(v, high);
        let big;
        if (v === undefined) big = 0n;
        else if (v instanceof Long) big = BigInt(v.value);
        else if (typeof v === 'bigint') big = v;
        else if (typeof v === 'number') {
          if (!Number.isFinite(v)) throw new TypeError('NumberLong needs a finite number');
          if (typeof high === 'number') big = (BigInt(high | 0) << 32n) + BigInt(v >>> 0);
          else big = BigInt(Math.trunc(v));
        } else {
          const text = String(v).trim();
          if (!/^[+-]?\d+$/.test(text)) throw new TypeError('Invalid NumberLong value "' + text + '"');
          big = BigInt(text);
        }
        if (big < LONG_MIN || big > LONG_MAX) throw new RangeError('NumberLong value out of range: ' + big);
        hidden(this, 'value', big.toString());
      }
      hidden(Long.prototype, '_bsontype', 'Long');
      Long.prototype.toString = function () { return this.value; };
      Long.prototype.valueOf = function () { return Number(this.value); };
      Long.prototype.toNumber = function () { return Number(this.value); };
      Long.prototype.toInt = function () { return Number(this.value) | 0; };
      Long.prototype.toBigInt = function () { return BigInt(this.value); };
      Long.prototype.toJSON = function () { return { $numberLong: this.value }; };
      Long.prototype.equals = function (o) { return o != null && String(o.value !== undefined ? o.value : o) === this.value; };
      Long.fromNumber = function (n) { return new Long(n); };
      Long.fromString = function (s) { return new Long(s); };
      Long.fromBigInt = function (b) { return new Long(b); };

      function Int32(v) {
        if (!(this instanceof Int32)) return new Int32(v);
        const n = Number(v === undefined ? 0 : (v && v.value !== undefined ? v.value : v));
        if (!Number.isFinite(n)) throw new TypeError('Int32 needs a finite number');
        const t = Math.trunc(n);
        if (t < INT32_MIN || t > INT32_MAX) throw new RangeError('Int32 value out of range: ' + v);
        hidden(this, 'value', t);
      }
      hidden(Int32.prototype, '_bsontype', 'Int32');
      Int32.prototype.valueOf = function () { return this.value; };
      Int32.prototype.toString = function () { return String(this.value); };
      Int32.prototype.toJSON = function () { return { $numberInt: String(this.value) }; };

      function Double(v) {
        if (!(this instanceof Double)) return new Double(v);
        hidden(this, 'value', Number(v === undefined ? 0 : (v && v.value !== undefined ? v.value : v)));
      }
      hidden(Double.prototype, '_bsontype', 'Double');
      Double.prototype.valueOf = function () { return this.value; };
      Double.prototype.toString = function () { return String(this.value); };
      Double.prototype.toJSON = function () { return { $numberDouble: numText(this.value) }; };

      function Decimal128(v) {
        if (!(this instanceof Decimal128)) return new Decimal128(v);
        const text = v === undefined ? '0' : String(v && v.value !== undefined ? v.value : v).trim();
        if (!/^[+-]?((\d+\.?\d*|\.\d+)([eE][+-]?\d+)?|Inf(inity)?|NaN)$/i.test(text)) throw new TypeError('Invalid Decimal128 value "' + text + '"');
        hidden(this, 'value', text);
      }
      hidden(Decimal128.prototype, '_bsontype', 'Decimal128');
      Decimal128.prototype.toString = function () { return this.value; };
      Decimal128.prototype.valueOf = function () { return Number(this.value); };
      Decimal128.prototype.toJSON = function () { return { $numberDecimal: this.value }; };
      Decimal128.fromString = function (s) { return new Decimal128(s); };

      function Binary(base64, subtype) {
        if (!(this instanceof Binary)) return new Binary(base64, subtype);
        hidden(this, 'base64', String(base64 || ''));
        hidden(this, 'sub_type', Number(subtype || 0));
      }
      hidden(Binary.prototype, '_bsontype', 'Binary');
      Binary.prototype.toString = function (encoding) { return encoding === 'hex' ? N.base64ToHex(this.base64) : this.base64; };
      Binary.prototype.hex = function () { return N.base64ToHex(this.base64); };
      Binary.prototype.subtype = function () { return this.sub_type; };
      Binary.prototype.length = function () { return N.base64ToHex(this.base64).length / 2; };
      Binary.prototype.toUUID = function () { return this; };
      Binary.prototype.toJSON = function () { return { $binary: { base64: this.base64, subType: hex2(this.sub_type) } }; };
      function BinData(subtype, base64) { return new Binary(base64, subtype); }
      function HexData(subtype, hex) { return new Binary(N.hexToBase64(String(hex)), subtype); }
      function MD5(hex) { return new Binary(N.hexToBase64(String(hex)), 5); }
      function UUID(text) {
        let hex;
        if (text === undefined) {
          const b = [];
          for (let i = 0; i < 16; i++) b.push(Math.floor(Math.random() * 256));
          b[6] = (b[6] & 0x0f) | 0x40; b[8] = (b[8] & 0x3f) | 0x80;
          hex = b.map(hex2).join('');
        } else {
          hex = String(text).replace(/-/g, '');
          if (!/^[0-9a-fA-F]{32}$/.test(hex)) throw new TypeError('UUID must be 32 hex digits, got "' + text + '"');
        }
        return new Binary(N.hexToBase64(hex), 4);
      }

      function Timestamp(t, i) {
        if (!(this instanceof Timestamp)) return new Timestamp(t, i);
        if (t && typeof t === 'object') { i = t.i; t = t.t; }
        hidden(this, 't', Number(t || 0) >>> 0);
        hidden(this, 'i', Number(i || 0) >>> 0);
      }
      hidden(Timestamp.prototype, '_bsontype', 'Timestamp');
      Timestamp.prototype.getTime = function () { return this.t; };
      Timestamp.prototype.getInc = function () { return this.i; };
      Timestamp.prototype.toString = function () { return 'Timestamp(' + this.t + ', ' + this.i + ')'; };
      Timestamp.prototype.toJSON = function () { return { $timestamp: { t: this.t, i: this.i } }; };

      function Code(code, scope) {
        if (!(this instanceof Code)) return new Code(code, scope);
        hidden(this, 'code', typeof code === 'function' ? String(code) : String(code));
        hidden(this, 'scope', scope || null);
      }
      hidden(Code.prototype, '_bsontype', 'Code');
      Code.prototype.toString = function () { return this.code; };

      function DBRef(collection, oid, db) {
        if (!(this instanceof DBRef)) return new DBRef(collection, oid, db);
        hidden(this, 'collection', String(collection));
        hidden(this, 'oid', oid);
        hidden(this, 'db', db === undefined ? null : db);
      }
      hidden(DBRef.prototype, '_bsontype', 'DBRef');
      Object.defineProperty(DBRef.prototype, '$ref', { get: function () { return this.collection; } });
      Object.defineProperty(DBRef.prototype, '$id', { get: function () { return this.oid; } });
      Object.defineProperty(DBRef.prototype, '$db', { get: function () { return this.db; } });

      function DBPointer(namespace, oid) {
        if (!(this instanceof DBPointer)) return new DBPointer(namespace, oid);
        hidden(this, 'namespace', String(namespace));
        hidden(this, 'oid', oid);
      }
      hidden(DBPointer.prototype, '_bsontype', 'DBPointer');

      function BSONRegExp(pattern, options) {
        if (!(this instanceof BSONRegExp)) return new BSONRegExp(pattern, options);
        hidden(this, 'pattern', String(pattern));
        hidden(this, 'options', String(options || '').split('').filter(function (c) { return 'ilmsux'.indexOf(c) >= 0; }).sort().join(''));
      }
      hidden(BSONRegExp.prototype, '_bsontype', 'BSONRegExp');
      BSONRegExp.prototype.toString = function () { return '/' + this.pattern + '/' + this.options; };

      function BSONSymbol(value) {
        if (!(this instanceof BSONSymbol)) return new BSONSymbol(value);
        hidden(this, 'value', String(value));
      }
      hidden(BSONSymbol.prototype, '_bsontype', 'Symbol');
      BSONSymbol.prototype.toString = function () { return this.value; };

      function MinKey() { if (!(this instanceof MinKey)) return new MinKey(); }
      hidden(MinKey.prototype, '_bsontype', 'MinKey');
      function MaxKey() { if (!(this instanceof MaxKey)) return new MaxKey(); }
      hidden(MaxKey.prototype, '_bsontype', 'MaxKey');

      function ISODate(value) {
        if (value === undefined) return new Date();
        if (value instanceof Date) return new Date(value.getTime());
        if (typeof value === 'number') return new Date(value);
        const ms = N.parseDate(String(value));
        if (Number.isNaN(ms)) throw new TypeError('Invalid ISODate "' + value + '"');
        return new Date(ms);
      }

      function makeRegex(pattern, options) {
        if (/^[imsu]*$/.test(options)) {
          try {
            const re = new RegExp(pattern, options);
            hidden(re, '__bsonPattern', pattern);
            return re;
          } catch (e) { /* not valid JavaScript syntax: keep it as a BSON regular expression */ }
        }
        return new BSONRegExp(pattern, options);
      }

      // ---------- Extended JSON bridge ----------
      function toEJ(v) {
        if (v === null) return null;
        switch (typeof v) {
          case 'undefined': return undefined;
          case 'boolean': return v;
          case 'string': return v;
          case 'number':
            if (Number.isInteger(v) && v >= INT32_MIN && v <= INT32_MAX && !Object.is(v, -0)) return { $numberInt: String(v) };
            return { $numberDouble: numText(v) };
          case 'bigint': return { $numberLong: v.toString() };
          case 'function': return { $code: String(v) };
          case 'symbol': return undefined;
        }
        if (v instanceof DB || v instanceof Collection) throw new TypeError(String(v) + ' cannot be used as a value');
        if (v instanceof Cursor) throw new TypeError('A cursor cannot be used as a value; call toArray() first');
        if (v instanceof Date) {
          const t = v.getTime();
          if (Number.isNaN(t)) throw new TypeError('Invalid Date');
          return { $date: { $numberLong: String(t) } };
        }
        if (v instanceof RegExp) {
          const options = v.flags.replace(/[^imsu]/g, '').split('').sort().join('');
          return { $regularExpression: { pattern: v.__bsonPattern !== undefined ? v.__bsonPattern : v.source, options: options } };
        }
        if (Array.isArray(v)) return v.map(function (x) { const e = toEJ(x); return e === undefined ? null : e; });
        switch (v._bsontype) {
          case 'ObjectId': return { $oid: v.$oid };
          case 'Long': return { $numberLong: v.value };
          case 'Int32': return { $numberInt: String(v.value) };
          case 'Double': return { $numberDouble: numText(v.value) };
          case 'Decimal128': return { $numberDecimal: v.value };
          case 'Binary': return { $binary: { base64: v.base64, subType: hex2(v.sub_type) } };
          case 'Timestamp': return { $timestamp: { t: v.t, i: v.i } };
          case 'Code': return v.scope ? { $code: v.code, $scope: toEJ(v.scope) } : { $code: v.code };
          case 'DBRef': { const o = { $ref: v.collection, $id: toEJ(v.oid) }; if (v.db) o.$db = v.db; return o; }
          case 'DBPointer': return { $dbPointer: { $ref: v.namespace, $id: toEJ(v.oid) } };
          case 'BSONRegExp': return { $regularExpression: { pattern: v.pattern, options: v.options } };
          case 'Symbol': return { $symbol: v.value };
          case 'MinKey': return { $minKey: 1 };
          case 'MaxKey': return { $maxKey: 1 };
        }
        if (v instanceof Map) {
          const m = {};
          v.forEach(function (value, key) { const e = toEJ(value); if (e !== undefined) m[String(key)] = e; });
          return m;
        }
        const out = {};
        Object.keys(v).forEach(function (k) { const e = toEJ(v[k]); if (e !== undefined) out[k] = e; });
        return out;
      }
      function stringify(v) { const e = toEJ(v); return JSON.stringify(e === undefined ? null : e); }

      function revive(key, v) {
        if (v === null || typeof v !== 'object' || Array.isArray(v)) return v;
        const keys = Object.keys(v);
        if (keys.length === 0 || keys[0].charAt(0) !== '$') return v;
        const k = keys[0];
        if (keys.length === 1) {
          const x = v[k];
          switch (k) {
            case '$oid': return new ObjectId(x);
            case '$numberInt': return parseInt(x, 10);
            case '$numberDouble': return x === 'NaN' ? NaN : x === 'Infinity' ? Infinity : x === '-Infinity' ? -Infinity : parseFloat(x);
            case '$numberLong': return new Long(x);
            case '$numberDecimal': return new Decimal128(x);
            case '$date': return new Date(x instanceof Long ? Number(x.value) : typeof x === 'string' ? N.parseDate(x) : x);
            case '$binary': return x && typeof x === 'object' ? new Binary(x.base64, parseInt(x.subType, 16)) : v;
            case '$timestamp': return new Timestamp(x.t, x.i);
            case '$regularExpression': return makeRegex(x.pattern, x.options);
            case '$code': return new Code(x);
            case '$symbol': return x;
            case '$minKey': return new MinKey();
            case '$maxKey': return new MaxKey();
            case '$undefined': return undefined;
            case '$dbPointer': return new DBPointer(x.collection || x.$ref, x.oid || x.$id);
            case '$uuid': return UUID(x);
          }
          return v;
        }
        if (keys.length === 2 && k === '$code' && keys[1] === '$scope') return new Code(v.$code, v.$scope);
        if (k === '$ref' && keys[1] === '$id' && keys.length <= 3 && typeof v.$ref === 'string') return new DBRef(v.$ref, v.$id, v.$db);
        return v;
      }
      function parseEJ(text) { return JSON.parse(text, revive); }

      // ---------- Commands ----------
      function runCmd(dbName, cmd) { return parseEJ(N.command(dbName, stringify(cmd))); }
      function toNum(v) { return v == null ? 0 : typeof v === 'number' ? v : Number(v.valueOf()); }
      function isZeroId(id) { return id == null || String(id.value !== undefined ? id.value : id) === '0'; }
      function withId(doc) {
        if (doc === null || typeof doc !== 'object' || Array.isArray(doc)) throw new TypeError('Documents must be objects');
        if (doc._id !== undefined) return doc;
        const out = { _id: new ObjectId() };
        Object.keys(doc).forEach(function (k) { out[k] = doc[k]; });
        return out;
      }
      function hasOperators(doc) { return doc != null && !Array.isArray(doc) && typeof doc === 'object' && Object.keys(doc).some(function (k) { return k.charAt(0) === '$'; }); }
      function indexName(keys) { return Object.keys(keys).map(function (k) { return k + '_' + String(keys[k]); }).join('_'); }
      function copyOptions(target, options, names) {
        if (!options) return target;
        names.forEach(function (n) { if (options[n] !== undefined) target[n] = options[n]; });
        return target;
      }

      // ---------- Cursor ----------
      function Cursor(dbName, collName, kind, spec) {
        this._db = dbName; this._coll = collName; this._kind = kind; this._spec = spec || {};
        this._opts = {}; this._buffer = []; this._id = null; this._started = false; this._done = false;
        this._ns = dbName + '.' + collName; this._transform = null;
      }
      Cursor.prototype._mod = function (name, value) {
        if (this._started) throw new Error('Cannot call ' + name + '() after the cursor has been iterated');
        this._opts[name] = value;
        return this;
      };
      ['sort', 'limit', 'skip', 'hint', 'collation', 'batchSize', 'maxTimeMS', 'comment', 'min', 'max', 'let'].forEach(function (name) {
        Cursor.prototype[name] = function (value) { return this._mod(name, value); };
      });
      Cursor.prototype.projection = function (p) { return this._mod('projection', p); };
      Cursor.prototype.project = Cursor.prototype.projection;
      Cursor.prototype.allowDiskUse = function (v) { return this._mod('allowDiskUse', v === undefined ? true : !!v); };
      Cursor.prototype.noCursorTimeout = function () { return this._mod('noCursorTimeout', true); };
      Cursor.prototype.returnKey = function (v) { return this._mod('returnKey', v === undefined ? true : !!v); };
      Cursor.prototype.showRecordId = function (v) { return this._mod('showRecordId', v === undefined ? true : !!v); };
      Cursor.prototype.readConcern = function (level) { return this._mod('readConcern', { level: level }); };
      Cursor.prototype.readPref = function () { return this; };
      Cursor.prototype.pretty = function () { return this; };
      Cursor.prototype.toString = function () { return 'Cursor(' + this._ns + ')'; };
      Cursor.prototype._command = function () {
        const o = this._opts;
        if (this._kind === 'find') {
          const c = { find: this._coll, filter: this._spec.filter || {} };
          ['sort', 'projection', 'hint', 'skip', 'collation', 'batchSize', 'maxTimeMS', 'comment', 'min', 'max', 'returnKey', 'showRecordId', 'allowDiskUse', 'noCursorTimeout', 'readConcern', 'let'].forEach(function (n) {
            if (o[n] !== undefined) c[n] = o[n];
          });
          if (o.limit !== undefined && o.limit !== 0) {
            const limit = toNum(o.limit);
            c.limit = Math.abs(limit);
            if (limit < 0) c.singleBatch = true;
          }
          return c;
        }
        if (this._kind === 'aggregate') {
          const pipeline = (this._spec.pipeline || []).slice();
          if (o.sort) pipeline.push({ $sort: o.sort });
          if (o.skip) pipeline.push({ $skip: o.skip });
          if (o.limit) pipeline.push({ $limit: Math.abs(toNum(o.limit)) });
          if (o.projection) pipeline.push({ $project: o.projection });
          const c = { aggregate: this._coll === null ? 1 : this._coll, pipeline: pipeline, cursor: {} };
          const options = Object.assign({}, this._spec.options || {});
          if (o.batchSize !== undefined) options.batchSize = o.batchSize;
          if (options.batchSize !== undefined) { c.cursor.batchSize = options.batchSize; delete options.batchSize; }
          ['hint', 'collation', 'maxTimeMS', 'comment', 'allowDiskUse', 'let'].forEach(function (n) { if (o[n] !== undefined) options[n] = o[n]; });
          Object.keys(options).forEach(function (n) { c[n] = options[n]; });
          return c;
        }
        return Object.assign({}, this._spec.command);
      };
      Cursor.prototype._start = function () {
        if (this._started) return;
        this._started = true;
        const r = runCmd(this._db, this._command());
        this._absorb(r.cursor, 'firstBatch');
      };
      Cursor.prototype._absorb = function (cur, field) {
        const batch = cur[field] || [];
        for (let i = 0; i < batch.length; i++) this._buffer.push(batch[i]);
        this._id = cur.id;
        if (cur.ns) this._ns = cur.ns;
        if (isZeroId(cur.id)) this._done = true;
      };
      Cursor.prototype._more = function () {
        if (this._done) return;
        const coll = this._ns.slice(this._ns.indexOf('.') + 1);
        const c = { getMore: this._id, collection: coll };
        if (this._opts.batchSize) c.batchSize = this._opts.batchSize;
        const r = runCmd(this._db, c);
        this._absorb(r.cursor, 'nextBatch');
      };
      Cursor.prototype.hasNext = function () {
        this._start();
        while (this._buffer.length === 0 && !this._done) this._more();
        return this._buffer.length > 0;
      };
      Cursor.prototype.next = function () {
        if (!this.hasNext()) throw new Error('Cursor is exhausted');
        const d = this._buffer.shift();
        return this._transform ? this._transform(d) : d;
      };
      Cursor.prototype.tryNext = function () { return this.hasNext() ? this.next() : null; };
      Cursor.prototype.isExhausted = function () { return this._started && this._done && this._buffer.length === 0; };
      Cursor.prototype.objsLeftInBatch = function () { return this._buffer.length; };
      Cursor.prototype.toArray = function () {
        const out = [];
        while (this.hasNext()) out.push(this.next());
        return out;
      };
      Cursor.prototype._take = function (limit) {
        const out = [];
        while ((limit < 0 || out.length <= limit) && this.hasNext()) out.push(this.next());
        return out;
      };
      Cursor.prototype.forEach = function (fn) {
        while (this.hasNext()) { if (fn(this.next()) === false) break; }
      };
      Cursor.prototype.map = function (fn) {
        const previous = this._transform;
        this._transform = previous ? function (d) { return fn(previous(d)); } : fn;
        return this;
      };
      Cursor.prototype.itcount = function () { let n = 0; while (this.hasNext()) { this.next(); n++; } return n; };
      Cursor.prototype.count = function (applySkipLimit) {
        if (this._kind !== 'find') return this.itcount();
        const c = { count: this._coll, query: this._spec.filter || {} };
        if (applySkipLimit) {
          if (this._opts.limit) c.limit = Math.abs(toNum(this._opts.limit));
          if (this._opts.skip) c.skip = this._opts.skip;
        }
        copyOptions(c, this._opts, ['hint', 'collation', 'maxTimeMS']);
        return toNum(runCmd(this._db, c).n);
      };
      Cursor.prototype.size = function () { return this.count(true); };
      Cursor.prototype.explain = function (verbosity) {
        return runCmd(this._db, { explain: this._command(), verbosity: verbosity === true ? 'allPlansExecution' : (verbosity || 'queryPlanner') });
      };
      Cursor.prototype.close = function () {
        if (this._started && !this._done && !isZeroId(this._id)) {
          try { runCmd(this._db, { killCursors: this._ns.slice(this._ns.indexOf('.') + 1), cursors: [this._id] }); } catch (e) { /* already gone */ }
        }
        this._done = true; this._started = true; this._buffer = [];
      };

      // ---------- Collection ----------
      function Collection(dbName, name) { this._dbName = dbName; this._name = name; }
      Collection.prototype.getName = function () { return this._name; };
      Collection.prototype.getFullName = function () { return this._dbName + '.' + this._name; };
      Collection.prototype.toString = function () { return this.getFullName(); };
      Collection.prototype.getDB = function () { return makeDB(this._dbName); };
      Collection.prototype._cmd = function (c) { return runCmd(this._dbName, c); };
      Collection.prototype._write = function (c, options) {
        if (options && options.writeConcern) c.writeConcern = options.writeConcern;
        if (options && options.bypassDocumentValidation) c.bypassDocumentValidation = true;
        if (options && options.comment !== undefined) c.comment = options.comment;
        return this._cmd(c);
      };
      Collection.prototype.find = function (filter, projection, options) {
        const c = new Cursor(this._dbName, this._name, 'find', { filter: filter || {} });
        if (projection) c.projection(projection);
        if (options) Object.keys(options).forEach(function (k) { if (typeof c[k] === 'function') c[k](options[k]); });
        return c;
      };
      Collection.prototype.findOne = function (filter, projection, options) {
        const c = this.find(filter, projection, options).limit(-1);
        return c.hasNext() ? c.next() : null;
      };
      Collection.prototype.aggregate = function (pipeline, options) {
        if (!Array.isArray(pipeline)) { pipeline = Array.prototype.slice.call(arguments); options = undefined; }
        const c = new Cursor(this._dbName, this._name, 'aggregate', { pipeline: pipeline, options: options || {} });
        const writes = pipeline.some(function (s) { return s && (s.$out !== undefined || s.$merge !== undefined); });
        if (writes) c._start();
        return c;
      };
      Collection.prototype.count = function (query, options) {
        const c = copyOptions({ count: this._name, query: query || {} }, options, ['limit', 'skip', 'hint', 'maxTimeMS', 'collation']);
        return toNum(this._cmd(c).n);
      };
      Collection.prototype.countDocuments = function (query, options) {
        const pipeline = [{ $match: query || {} }];
        if (options && options.skip) pipeline.push({ $skip: options.skip });
        if (options && options.limit) pipeline.push({ $limit: options.limit });
        pipeline.push({ $group: { _id: 1, n: { $sum: 1 } } });
        const c = copyOptions({ aggregate: this._name, pipeline: pipeline, cursor: {} }, options, ['hint', 'maxTimeMS', 'collation']);
        const batch = this._cmd(c).cursor.firstBatch;
        return batch.length ? toNum(batch[0].n) : 0;
      };
      Collection.prototype.estimatedDocumentCount = function (options) {
        return toNum(this._cmd(copyOptions({ count: this._name }, options, ['maxTimeMS'])).n);
      };
      Collection.prototype.distinct = function (key, query, options) {
        return this._cmd(copyOptions({ distinct: this._name, key: key, query: query || {} }, options, ['collation', 'maxTimeMS', 'hint'])).values;
      };
      Collection.prototype.insertOne = function (doc, options) {
        const d = withId(doc);
        this._write({ insert: this._name, documents: [d] }, options);
        return { acknowledged: true, insertedId: d._id };
      };
      Collection.prototype.insertMany = function (docs, options) {
        if (!Array.isArray(docs)) throw new TypeError('insertMany() needs an array of documents');
        const ds = docs.map(withId);
        const r = this._write({ insert: this._name, documents: ds, ordered: !(options && options.ordered === false) }, options);
        const ids = {};
        ds.forEach(function (d, i) { ids[i] = d._id; });
        return { acknowledged: true, insertedCount: toNum(r.n), insertedIds: ids };
      };
      Collection.prototype.insert = function (docs, options) {
        if (Array.isArray(docs)) return this.insertMany(docs, options);
        const r = this.insertOne(docs, options);
        return { acknowledged: true, insertedCount: 1, insertedId: r.insertedId };
      };
      Collection.prototype._update = function (filter, update, options, multi) {
        const u = { q: filter || {}, u: update, multi: !!multi, upsert: !!(options && options.upsert) };
        copyOptions(u, options, ['arrayFilters', 'collation', 'hint']);
        const r = this._write({ update: this._name, updates: [u] }, options);
        const upserted = r.upserted && r.upserted.length ? r.upserted : [];
        return {
          acknowledged: true,
          insertedId: upserted.length ? upserted[0]._id : null,
          matchedCount: toNum(r.n) - upserted.length,
          modifiedCount: toNum(r.nModified),
          upsertedCount: upserted.length
        };
      };
      Collection.prototype.updateOne = function (filter, update, options) {
        if (!Array.isArray(update) && !hasOperators(update)) throw new Error('Update document requires atomic operators such as $set; use replaceOne() to replace a document');
        return this._update(filter, update, options, false);
      };
      Collection.prototype.updateMany = function (filter, update, options) {
        if (!Array.isArray(update) && !hasOperators(update)) throw new Error('Update document requires atomic operators such as $set');
        return this._update(filter, update, options, true);
      };
      Collection.prototype.replaceOne = function (filter, replacement, options) {
        if (hasOperators(replacement)) throw new Error('Replacement document must not contain atomic operators');
        return this._update(filter, replacement, options, false);
      };
      Collection.prototype.update = function (filter, update, options) {
        options = options || {};
        return this._update(filter, update, options, !!options.multi);
      };
      Collection.prototype._delete = function (filter, options, limit) {
        const d = copyOptions({ q: filter || {}, limit: limit }, options, ['collation', 'hint']);
        const r = this._write({ delete: this._name, deletes: [d] }, options);
        return { acknowledged: true, deletedCount: toNum(r.n) };
      };
      Collection.prototype.deleteOne = function (filter, options) { return this._delete(filter, options, 1); };
      Collection.prototype.deleteMany = function (filter, options) { return this._delete(filter, options, 0); };
      Collection.prototype.remove = function (filter, justOne) {
        const one = justOne === true || (justOne && justOne.justOne);
        return this._delete(filter, typeof justOne === 'object' ? justOne : undefined, one ? 1 : 0);
      };
      Collection.prototype._findAndModify = function (c, options) {
        copyOptions(c, options, ['sort', 'arrayFilters', 'collation', 'hint', 'maxTimeMS', 'bypassDocumentValidation']);
        if (options && options.projection) c.fields = options.projection;
        if (options && options.writeConcern) c.writeConcern = options.writeConcern;
        const r = this._cmd(c);
        return r.value === undefined ? null : r.value;
      };
      Collection.prototype.findOneAndUpdate = function (filter, update, options) {
        options = options || {};
        return this._findAndModify({ findAndModify: this._name, query: filter || {}, update: update, new: options.returnDocument === 'after' || options.returnNewDocument === true, upsert: !!options.upsert }, options);
      };
      Collection.prototype.findOneAndReplace = function (filter, replacement, options) {
        options = options || {};
        if (hasOperators(replacement)) throw new Error('Replacement document must not contain atomic operators');
        return this._findAndModify({ findAndModify: this._name, query: filter || {}, update: replacement, new: options.returnDocument === 'after' || options.returnNewDocument === true, upsert: !!options.upsert }, options);
      };
      Collection.prototype.findOneAndDelete = function (filter, options) {
        return this._findAndModify({ findAndModify: this._name, query: filter || {}, remove: true }, options || {});
      };
      Collection.prototype.findAndModify = function (spec) {
        const c = Object.assign({ findAndModify: this._name }, spec || {});
        const r = this._cmd(c);
        return r.value === undefined ? null : r.value;
      };
      Collection.prototype.bulkWrite = function (operations, options) {
        const ordered = !(options && options.ordered === false);
        const res = { acknowledged: true, insertedCount: 0, matchedCount: 0, modifiedCount: 0, deletedCount: 0, upsertedCount: 0, insertedIds: {}, upsertedIds: {} };
        const errors = [];
        const self = this;
        (operations || []).forEach(function (op, index) {
          if (!ordered || errors.length === 0) {
            try {
              const name = Object.keys(op)[0];
              const a = op[name] || {};
              if (name === 'insertOne') {
                const r = self.insertOne(a.document !== undefined ? a.document : a, options);
                res.insertedCount += 1; res.insertedIds[index] = r.insertedId;
              } else if (name === 'updateOne' || name === 'updateMany' || name === 'replaceOne') {
                const r = self._update(a.filter, name === 'replaceOne' ? a.replacement : a.update, a, name === 'updateMany');
                res.matchedCount += r.matchedCount; res.modifiedCount += r.modifiedCount; res.upsertedCount += r.upsertedCount;
                if (r.insertedId !== null) res.upsertedIds[index] = r.insertedId;
              } else if (name === 'deleteOne' || name === 'deleteMany') {
                res.deletedCount += self._delete(a.filter, a, name === 'deleteOne' ? 1 : 0).deletedCount;
              } else {
                throw new Error('Unknown bulkWrite operation ' + name);
              }
            } catch (e) {
              errors.push('operation ' + index + ': ' + e.message);
            }
          }
        });
        if (errors.length) throw new Error('bulkWrite failed at ' + errors.join('; '));
        return res;
      };
      Collection.prototype.createIndex = function (keys, options) {
        const spec = Object.assign({ key: keys, name: indexName(keys) }, options || {});
        this._cmd({ createIndexes: this._name, indexes: [spec] });
        return spec.name;
      };
      Collection.prototype.ensureIndex = Collection.prototype.createIndex;
      Collection.prototype.createIndexes = function (list, options) {
        const specs = (list || []).map(function (keys) { return Object.assign({ key: keys, name: indexName(keys) }, options || {}); });
        this._cmd({ createIndexes: this._name, indexes: specs });
        return specs.map(function (s) { return s.name; });
      };
      Collection.prototype.dropIndex = function (index) { return this._cmd({ dropIndexes: this._name, index: index }); };
      Collection.prototype.dropIndexes = function (indexes) { return this._cmd({ dropIndexes: this._name, index: indexes === undefined ? '*' : indexes }); };
      Collection.prototype.getIndexes = function () {
        return new Cursor(this._dbName, this._name, 'command', { command: { listIndexes: this._name, cursor: {} } }).toArray();
      };
      Collection.prototype.getIndexKeys = function () { return this.getIndexes().map(function (i) { return i.key; }); };
      Collection.prototype.drop = function () {
        try { this._cmd({ drop: this._name }); return true; } catch (e) { if (e.code === 26) return false; throw e; }
      };
      Collection.prototype.renameCollection = function (target, dropTarget) {
        return runCmd('admin', { renameCollection: this.getFullName(), to: this._dbName + '.' + target, dropTarget: !!dropTarget });
      };
      Collection.prototype.stats = function (options) {
        const scale = typeof options === 'number' ? options : (options && options.scale) || 1;
        try {
          return this._cmd({ collStats: this._name, scale: scale });
        } catch (e) {
          if (e.code !== 59) throw e;
          const r = this.aggregate([{ $collStats: { storageStats: { scale: scale } } }]).toArray();
          return r.length ? Object.assign({ ns: this.getFullName() }, r[0].storageStats) : {};
        }
      };
      Collection.prototype.dataSize = function () { return this.stats().size; };
      Collection.prototype.storageSize = function () { return this.stats().storageSize; };
      Collection.prototype.totalIndexSize = function () { return this.stats().totalIndexSize; };
      Collection.prototype.isCapped = function () { return !!this.stats().capped; };
      Collection.prototype.exists = function () {
        const r = makeDB(this._dbName).getCollectionInfos({ name: this._name });
        return r.length ? r[0] : null;
      };
      Collection.prototype.validate = function (options) {
        const full = options === true || (options && options.full);
        return this._cmd({ validate: this._name, full: !!full });
      };
      Collection.prototype.watch = function () { throw new Error('Change streams are not supported in this shell'); };

      // ---------- Database ----------
      function DB(name) { this._name = name; }
      DB.prototype.getName = function () { return this._name; };
      DB.prototype.toString = function () { return this._name; };
      DB.prototype.getSiblingDB = function (name) { return makeDB(name); };
      DB.prototype.getCollection = function (name) { return makeCollection(this._name, String(name)); };
      DB.prototype.getMongo = function () {
        return { getDB: makeDB, getDBNames: function () { return runCmd('admin', { listDatabases: 1, nameOnly: true }).databases.map(function (d) { return d.name; }); }, toString: function () { return 'Mongo'; } };
      };
      DB.prototype.getCollectionInfos = function (filter, nameOnly) {
        return new Cursor(this._name, '$cmd', 'command', { command: { listCollections: 1, filter: filter || {}, nameOnly: !!nameOnly, authorizedCollections: true, cursor: {} } }).toArray();
      };
      DB.prototype.getCollectionNames = function () {
        return this.getCollectionInfos({}, true).map(function (c) { return c.name; }).sort();
      };
      DB.prototype.runCommand = function (cmd) {
        if (typeof cmd === 'string') { const o = {}; o[cmd] = 1; cmd = o; }
        return runCmd(this._name, cmd);
      };
      DB.prototype.adminCommand = function (cmd) {
        if (typeof cmd === 'string') { const o = {}; o[cmd] = 1; cmd = o; }
        return runCmd('admin', cmd);
      };
      DB.prototype.createCollection = function (name, options) { return runCmd(this._name, Object.assign({ create: name }, options || {})); };
      DB.prototype.createView = function (name, source, pipeline, options) {
        return runCmd(this._name, Object.assign({ create: name, viewOn: source, pipeline: pipeline || [] }, options || {}));
      };
      DB.prototype.dropDatabase = function () { return runCmd(this._name, { dropDatabase: 1 }); };
      DB.prototype.stats = function (scale) { return runCmd(this._name, { dbStats: 1, scale: typeof scale === 'number' ? scale : 1 }); };
      DB.prototype.version = function () { return N.serverVersion(); };
      DB.prototype.serverStatus = function (options) { return runCmd('admin', Object.assign({ serverStatus: 1 }, options || {})); };
      DB.prototype.serverBuildInfo = function () { return runCmd('admin', { buildInfo: 1 }); };
      DB.prototype.hostInfo = function () { return runCmd('admin', { hostInfo: 1 }); };
      DB.prototype.hello = function () { return runCmd('admin', { hello: 1 }); };
      DB.prototype.isMaster = DB.prototype.hello;
      DB.prototype.currentOp = function (filter) {
        return runCmd('admin', Object.assign({ currentOp: 1 }, filter === true ? { $all: true } : (filter || {})));
      };
      DB.prototype.killOp = function (op) { return runCmd('admin', { killOp: 1, op: op }); };
      DB.prototype.aggregate = function (pipeline, options) {
        return new Cursor(this._name, null, 'aggregate', { pipeline: pipeline || [], options: options || {} });
      };
      DB.prototype.createUser = function (user) {
        const c = { createUser: user.user };
        Object.keys(user).forEach(function (k) { if (k !== 'user') c[k] = user[k]; });
        return runCmd(this._name, c);
      };
      DB.prototype.updateUser = function (name, update) { return runCmd(this._name, Object.assign({ updateUser: name }, update || {})); };
      DB.prototype.dropUser = function (name) { return runCmd(this._name, { dropUser: name }); };
      DB.prototype.getUser = function (name) { const r = runCmd(this._name, { usersInfo: { user: name, db: this._name } }).users; return r.length ? r[0] : null; };
      DB.prototype.getUsers = function () { return runCmd(this._name, { usersInfo: 1 }).users; };
      DB.prototype.grantRolesToUser = function (name, roles) { return runCmd(this._name, { grantRolesToUser: name, roles: roles }); };
      DB.prototype.revokeRolesFromUser = function (name, roles) { return runCmd(this._name, { revokeRolesFromUser: name, roles: roles }); };
      DB.prototype.createRole = function (role) {
        const c = { createRole: role.role };
        Object.keys(role).forEach(function (k) { if (k !== 'role') c[k] = role[k]; });
        return runCmd(this._name, c);
      };
      DB.prototype.dropRole = function (name) { return runCmd(this._name, { dropRole: name }); };
      DB.prototype.getRoles = function () { return runCmd(this._name, { rolesInfo: 1 }).roles; };
      DB.prototype.auth = function (user, password) {
        let mechanism = '';
        if (user && typeof user === 'object') { password = user.pwd; mechanism = user.mechanism || ''; user = user.user; }
        N.auth(this._name, String(user), String(password), mechanism);
        return { ok: 1 };
      };
      DB.prototype.getProfilingStatus = function () { return runCmd(this._name, { profile: -1 }); };
      DB.prototype.setProfilingLevel = function (level, options) { return runCmd(this._name, Object.assign({ profile: level }, typeof options === 'number' ? { slowms: options } : (options || {}))); };
      DB.prototype.listCommands = function () { return runCmd('admin', { listCommands: 1 }); };

      const reserved = { then: 1, toJSON: 1, inspect: 1, _bsontype: 1, constructor: 1, valueOf: 1, toString: 1, asymmetricMatch: 1, nodeType: 1 };
      function makeDB(name) {
        return new Proxy(new DB(String(name)), {
          get: function (target, prop, receiver) {
            if (typeof prop === 'symbol' || prop in target || reserved[prop]) return Reflect.get(target, prop, receiver);
            return target.getCollection(prop);
          }
        });
      }
      function makeCollection(dbName, name) {
        return new Proxy(new Collection(dbName, name), {
          get: function (target, prop, receiver) {
            if (typeof prop === 'symbol' || prop in target || reserved[prop]) return Reflect.get(target, prop, receiver);
            return makeCollection(dbName, name + '.' + prop);
          }
        });
      }

      // ---------- Printing ----------
      function format(v, pretty) {
        if (v === undefined) return 'undefined';
        if (v instanceof Cursor) v = v.toArray();
        if (v instanceof DB || v instanceof Collection) return String(v);
        return N.format(stringify(v), !!pretty);
      }
      function print() {
        const parts = [];
        for (let i = 0; i < arguments.length; i++) parts.push(typeof arguments[i] === 'string' ? arguments[i] : format(arguments[i], false));
        N.print(parts.join(' '));
      }

      // ---------- Result description ----------
      function isDocument(x) {
        if (x === null || typeof x !== 'object' || Array.isArray(x)) return false;
        if (x instanceof DB || x instanceof Collection || x instanceof Cursor) return false;
        if (x instanceof Date || x instanceof RegExp) return false;
        return x._bsontype === undefined || x._bsontype === 'DBRef';
      }
      function describe(v, limit) {
        if (v === undefined) return JSON.stringify({ kind: 'none' });
        if (v instanceof Cursor) {
          if (!v._started && !v._transform && v._kind !== 'command') return JSON.stringify({ kind: 'cursor', db: v._db, command: toEJ(v._command()) });
          const items = v._take(limit);
          const truncated = limit >= 0 && items.length > limit;
          if (truncated) items.length = limit;
          return JSON.stringify({ kind: items.every(isDocument) && items.length ? 'documents' : 'values', items: toEJ(items), truncated: truncated });
        }
        if (v instanceof DB) return JSON.stringify({ kind: 'message', text: v.getName() });
        if (v instanceof Collection) return JSON.stringify({ kind: 'message', text: v.getFullName() });
        if (typeof v === 'function') return JSON.stringify({ kind: 'message', text: '[Function' + (v.name ? ': ' + v.name : '') + ']' });
        if (Array.isArray(v)) {
          const truncated = limit >= 0 && v.length > limit;
          const items = truncated ? v.slice(0, limit) : v;
          return JSON.stringify({ kind: items.length && items.every(isDocument) ? 'documents' : 'values', items: toEJ(items), truncated: truncated });
        }
        if (isDocument(v)) return JSON.stringify({ kind: 'document', doc: toEJ(v) });
        const e = toEJ(v);
        return JSON.stringify({ kind: 'value', value: e === undefined ? null : e });
      }

      // ---------- Globals ----------
      const globals = {
        ObjectId: ObjectId, ObjectID: ObjectId, NumberLong: Long, Long: Long, NumberInt: Int32, Int32: Int32, Double: Double,
        NumberDecimal: Decimal128, Decimal128: Decimal128, Binary: Binary, BinData: BinData, HexData: HexData, MD5: MD5, UUID: UUID,
        Timestamp: Timestamp, Code: Code, DBRef: DBRef, DBPointer: DBPointer, BSONRegExp: BSONRegExp, BSONSymbol: BSONSymbol,
        MinKey: MinKey, MaxKey: MaxKey, ISODate: ISODate,
        print: print, printjson: function (v) { N.print(format(v, true)); }, printjsononeline: function (v) { N.print(format(v, false)); },
        tojson: function (v) { return format(v, true); }, tojsononeline: function (v) { return format(v, false); },
        sleep: function (ms) { N.sleep(Number(ms) || 0); },
        EJSON: {
          stringify: function (v, replacer, space, options) { const o = options || (replacer && typeof replacer === 'object' ? replacer : {}); return N.ejson(stringify(v), o.relaxed !== false); },
          parse: function (text) { return parseEJ(text); },
          serialize: function (v) { return JSON.parse(N.ejson(stringify(v), false)); },
          deserialize: function (v) { return parseEJ(JSON.stringify(v)); }
        },
        __eqDescribe: describe,
        __eqSetDB: function (name) { global.db = makeDB(name); }
      };
      Object.keys(globals).forEach(function (k) {
        Object.defineProperty(global, k, { value: globals[k], writable: true, enumerable: false, configurable: true });
      });
      global.db = makeDB('test');
    })(this);
    """#
    // swiftlint:enable line_length
}
