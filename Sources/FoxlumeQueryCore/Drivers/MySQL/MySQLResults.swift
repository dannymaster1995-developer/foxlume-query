import Foundation

/// Reads the response to one COM_QUERY: OK packets and text result sets, following SERVER_MORE_RESULTS_EXISTS.
struct MySQLResultReader {
    static let localInfileError = DatabaseError.unsupported("LOAD DATA LOCAL INFILE is not supported.")

    let stream: MySQLPacketStream
    /// True when CLIENT_DEPRECATE_EOF was negotiated: no EOF after the columns, rows end with an 0xFE OK packet.
    let deprecateEOF: Bool

    /// Rows beyond `rowLimit` are read and dropped. `onStatus` sees the server status of every result.
    func readAll(rowLimit: Int?, onStatus: (MySQLServerStatus) -> Void) throws -> [StatementResult] {
        var results: [StatementResult] = []
        var mark = Date()
        var rejectedLocalInfile = false
        while true {
            let packet = try stream.read()
            guard let header = packet.first else {
                throw DatabaseError.protocolViolation("Empty response packet")
            }
            var result: StatementResult
            let status: MySQLServerStatus
            switch header {
            case MySQLProtocol.okHeader:
                let ok = try MySQLOKPacket(payload: packet)
                result = StatementResult(affectedRows: Int(clamping: ok.affectedRows), message: ok.message)
                status = ok.statusFlags
            case MySQLProtocol.errHeader:
                if rejectedLocalInfile { throw Self.localInfileError }
                throw try MySQLErrorPacket(payload: packet).serverError
            case MySQLProtocol.localInfileHeader:
                // Never read local files on the server's request. An empty packet ends the transfer.
                try stream.write([])
                rejectedLocalInfile = true
                continue
            default:
                let (resultSet, resultSetStatus) = try readResultSet(header: packet, rowLimit: rowLimit)
                result = resultSet
                status = resultSetStatus
            }
            onStatus(status)
            let now = Date()
            result.elapsed = now.timeIntervalSince(mark)
            mark = now
            results.append(result)
            if !status.contains(.moreResultsExist) { break }
        }
        if rejectedLocalInfile { throw Self.localInfileError }
        return results
    }

    private func readResultSet(header: [UInt8], rowLimit: Int?) throws -> (StatementResult, MySQLServerStatus) {
        var reader = ByteReader(header)
        guard let count = try reader.lengthEncodedInt(), count > 0, count <= UInt64(UInt16.max) else {
            throw DatabaseError.protocolViolation("Invalid column count")
        }
        var definitions: [MySQLColumnDefinition] = []
        definitions.reserveCapacity(Int(count))
        for _ in 0..<count {
            definitions.append(try MySQLColumnDefinition(payload: try stream.read()))
        }
        if !deprecateEOF {
            let eof = try stream.read()
            guard eof.first == MySQLProtocol.eofHeader else {
                throw DatabaseError.protocolViolation("Expected EOF after column definitions")
            }
        }

        let limit = rowLimit.map { max(0, $0) }
        var rows: [[CellValue]] = []
        var truncated = false
        while true {
            let packet = try stream.read()
            guard let first = packet.first else {
                throw DatabaseError.protocolViolation("Empty row packet")
            }
            // A row can only start with 0xFE when its first value is 16 MB or longer.
            if first == MySQLProtocol.eofHeader, packet.count < MySQLProtocol.maxPacketPayload {
                let status = deprecateEOF
                    ? try MySQLOKPacket(payload: packet).statusFlags
                    : try MySQLEOFPacket(payload: packet).statusFlags
                let result = StatementResult(columns: definitions.map(\.resultColumn), rows: rows, truncated: truncated)
                return (result, status)
            }
            if first == MySQLProtocol.errHeader {
                throw try MySQLErrorPacket(payload: packet).serverError
            }
            if let limit, rows.count >= limit {
                truncated = true
                continue
            }
            rows.append(try MySQLTextRow.decode(packet, columns: definitions))
        }
    }
}
