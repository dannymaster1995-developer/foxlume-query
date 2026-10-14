import FoxlumeQueryCore
import Foundation

/// fqprobe: exercise an Foxlume Query driver from the terminal.
///
///   fqprobe --kind postgresql --host 127.0.0.1 --port 55432 --user postgres --password postgres \
///           --db foxlume --ssl prefer query "SELECT 1; SELECT now()"
///   fqprobe ... meta [table]          databases, schemas, tables, structure and DDL
///   fqprobe ... cancel                runs a long sleep and cancels it after 1 second
///   fqprobe --kind sqlite --file /path/db.sqlite query "..."

func usage() -> Never {
    FileHandle.standardError.write(Data("usage: fqprobe --kind postgresql|mysql|mariadb|sqlite|duckdb|mongodb|redis [--host H] [--port P] [--user U] [--password PW] [--db DB] [--ssl disable|prefer|require|verifyFull] [--file PATH] [--readonly 1] [--limit N] [--opt-<ConnectionOption> VALUE] [--ssh-host H --ssh-port P --ssh-user U --ssh-auth agent|keyFile|password --ssh-key PATH --ssh-secret S] (query SQL | meta [TABLE] | cancel)\n".utf8))
    exit(64)
}

var arguments = Array(CommandLine.arguments.dropFirst())
var options: [String: String] = [:]
while let first = arguments.first, first.hasPrefix("--") {
    arguments.removeFirst()
    guard let value = arguments.first else { usage() }
    arguments.removeFirst()
    options[String(first.dropFirst(2))] = value
}
guard let command = arguments.first, let kind = DatabaseKind(rawValue: options["kind"] ?? "") else { usage() }

var config = ConnectionConfig(
    name: "probe",
    kind: kind,
    host: options["host"] ?? "127.0.0.1",
    port: options["port"].flatMap(Int.init),
    user: options["user"],
    database: options["db"] ?? "",
    filePath: options["file"] ?? "",
    sslMode: options["ssl"].flatMap(SSLMode.init(rawValue:)) ?? .prefer,
    readOnly: options["readonly"] == "1",
    ssh: options["ssh-host"].map {
        SSHConfig(
            isEnabled: true,
            host: $0,
            port: options["ssh-port"].flatMap(Int.init) ?? 22,
            user: options["ssh-user"] ?? NSUserName(),
            authMethod: options["ssh-auth"].flatMap(SSHAuthMethod.init(rawValue:)) ?? (options["ssh-key"] == nil ? .agent : .keyFile),
            keyPath: options["ssh-key"] ?? ""
        )
    }
)
// `--opt-redisMode cluster` style flags set engine options (`ConnectionOption` raw values).
for (key, value) in options where key.hasPrefix("opt-") {
    if let option = ConnectionOption(rawValue: String(key.dropFirst(4))) { config.setOption(option, value) }
}
let session = DatabaseSession(parameters: ConnectionParameters(config: config, password: options["password"] ?? "", sshSecret: options["ssh-secret"]))
let rowLimit = options["limit"].flatMap(Int.init)

func render(_ result: StatementResult) {
    if result.hasResultSet {
        let header = result.columns.map { "\($0.name)<\($0.typeName)\($0.isNumeric ? ",num" : "")>" }
        print(header.joined(separator: " | "))
        for row in result.rows {
            print(row.map { $0.isNull ? "∅" : $0.displayString }.joined(separator: " | "))
        }
        print("(\(result.rows.count) rows\(result.truncated ? ", truncated" : ""), \(String(format: "%.1f", result.elapsed * 1000)) ms)")
    } else {
        print("OK: \(result.message ?? "-") affected=\(result.affectedRows.map(String.init) ?? "-") (\(String(format: "%.1f", result.elapsed * 1000)) ms)")
    }
}

func runProbe() async -> Int32 {
    do {
        let started = Date()
        try await session.connect()
        print("connected: \(kind.displayName) \(session.serverVersion) in \(Int(Date().timeIntervalSince(started) * 1000)) ms")
        switch command {
        case "query":
            guard arguments.count >= 2 else { usage() }
            for result in try await session.execute(arguments[1], rowLimit: rowLimit) {
                render(result)
            }
        case "meta":
            let databases = try await session.run { try $0.databases() }
            print("databases: \(databases)")
            print("current database: \(await session.currentDatabase() ?? "-")")
            let schemas = try await session.run { try $0.schemas() }
            print("schemas: \(schemas)  default: \(await session.defaultSchema() ?? "-")")
            let defaultSchema = await session.defaultSchema()
            let tables = try await session.run { try $0.tables(schema: defaultSchema) }
            for table in tables {
                print("  \(table.kind.rawValue): \(table.ref.schema.map { $0 + "." } ?? "")\(table.name) rows≈\(table.estimatedRows.map(String.init) ?? "-") \(table.comment ?? "")")
            }
            if arguments.count >= 2 {
                let parts = arguments[1].split(separator: ".", maxSplits: 1).map(String.init)
                let ref = parts.count == 2 ? TableRef(schema: parts[0], name: parts[1]) : TableRef(schema: defaultSchema, name: parts[0])
                let structure = try await session.run { try $0.structure(of: ref) }
                print("columns:")
                for column in structure.columns {
                    print("  \(column.name) \(column.dataType) null=\(column.isNullable) default=\(column.defaultValue ?? "-") pk=\(column.isPrimaryKey) auto=\(column.isAutoIncrement) \(column.comment ?? "") \(column.extra ?? "")")
                }
                print("primary key: \(structure.primaryKey)")
                for index in structure.indexes {
                    print("  index \(index.name) \(index.columns) unique=\(index.isUnique) primary=\(index.isPrimary) \(index.method ?? "")")
                }
                for fk in structure.foreignKeys {
                    print("  fk \(fk.name) \(fk.columns) -> \(fk.referencedTable.schema ?? "").\(fk.referencedTable.name)\(fk.referencedColumns) upd=\(fk.onUpdate ?? "-") del=\(fk.onDelete ?? "-")")
                }
                print("ddl:\n" + (try await session.run { try $0.ddl(of: ref) }))
            }
        case "cancel":
            let sleepSQL: String
            switch kind {
            case .postgresql: sleepSQL = "SELECT pg_sleep(30)"
            case .mysql, .mariadb: sleepSQL = "SELECT SLEEP(30)"
            case .sqlite: sleepSQL = "WITH RECURSIVE c(x) AS (SELECT 1 UNION ALL SELECT x + 1 FROM c) SELECT count(*) FROM c"
            case .duckdb: sleepSQL = "SELECT sum(hash(range)) FROM range(100000000000)"
            // The sleep command needs enableTestCommands; a $where that sleeps per document works on any server.
            case .mongodb: sleepSQL = #"db.orders.find({ $where: "sleep(100) || true" }).toArray()"#
            case .redis: sleepSQL = "BLPOP foxlume:never:pushed 30"
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + 1) { session.cancel() }
            let began = Date()
            do {
                let results = try await session.execute(sleepSQL)
                print("not cancelled after \(Date().timeIntervalSince(began))s: \(results.first?.rows ?? [])")
            } catch {
                print("cancelled after \(String(format: "%.2f", Date().timeIntervalSince(began)))s: \(error.localizedDescription)")
            }
            let after = try await session.execute(kind == .redis ? "PING" : kind == .mongodb ? "db.runCommand({ ping: 1 })" : "SELECT 1 AS still_alive")
            render(after[0])
        default:
            usage()
        }
        await session.close()
        return 0
    } catch {
        print("error: \(error.localizedDescription)")
        return 1
    }
}

let semaphore = DispatchSemaphore(value: 0)
var exitCode: Int32 = 0
Task {
    exitCode = await runProbe()
    semaphore.signal()
}
semaphore.wait()
SSHTunnel.stopAll()
exit(exitCode)
