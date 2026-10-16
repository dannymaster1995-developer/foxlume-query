import Foundation

/// Reads what a column reorder needs to rebuild a table (TableRebuild.swift), and what keeps it from being rebuilt
/// safely. OIDs are integers parsed from the server's own answer; names never reach SQL from outside.
extension PostgresConnection {
    public func tableRebuildInfo(of table: TableRef) throws -> TableRebuildInfo {
        let relation = try relation(table)
        let oid = relation.oid
        guard serverVersionNumber >= 100_000 else {
            return TableRebuildInfo(table: relation.ref, blockers: ["it needs PostgreSQL 10 or later"], columns: [])
        }
        guard let tableRow = try rows("""
            SELECT c.relkind, c.relispartition, c.reloftype <> 0, c.relrowsecurity, c.relpersistence,
                   pg_catalog.array_to_json(c.reloptions), ts.spcname, c.relreplident,
                   pg_catalog.pg_get_userbyid(c.relowner), current_user, pg_catalog.pg_has_role(c.relowner, 'USAGE'),
                   (SELECT ic.relname FROM pg_catalog.pg_index i JOIN pg_catalog.pg_class ic ON ic.oid = i.indexrelid
                    WHERE i.indrelid = c.oid AND i.indisreplident),
                   (SELECT ic.relname FROM pg_catalog.pg_index i JOIN pg_catalog.pg_class ic ON ic.oid = i.indexrelid
                    WHERE i.indrelid = c.oid AND i.indisclustered)
            FROM pg_catalog.pg_class c
            LEFT JOIN pg_catalog.pg_tablespace ts ON ts.oid = c.reltablespace
            WHERE c.oid = \(oid)
            """).first, tableRow.count >= 13
        else {
            throw DatabaseError.server(message: "relation \(dialect.qualifiedName(table)) does not exist", code: "42P01")
        }
        let owner = tableRow[8].textValue
        var info = TableRebuildInfo(
            table: relation.ref,
            blockers: try rebuildBlockers(oid: oid, table: tableRow),
            columns: try rebuildColumns(oid: oid),
            constraints: try rebuildConstraints(oid: oid),
            indexes: try rebuildIndexes(oid: oid),
            ownedSequences: try ownedSequences(oid: oid),
            comment: relation.comment,
            owner: owner != tableRow[9].textValue ? owner : nil,
            privileges: try privileges("SELECT c.relacl, c.relowner FROM pg_catalog.pg_class c WHERE c.oid = \(oid)"),
            isUnlogged: tableRow[4].textValue == "u",
            options: Self.jsonStrings(tableRow[5].textValue),
            tablespace: tableRow[6].textValue,
            replicaIdentity: tableRow[7].textValue ?? "d",
            replicaIdentityIndex: tableRow[11].textValue,
            clusterIndex: tableRow[12].textValue
        )
        // Constraint indexes come back with their constraint; a plain index named here is in `indexes`.
        if info.replicaIdentity == "i", info.replicaIdentityIndex == nil { info.replicaIdentity = "d" }
        return info
    }

    /// Everything that would be lost, or would stop the old table from being dropped. The DROP has no CASCADE, so an
    /// unexpected dependency still fails the whole script; these are found up front to say why.
    private func rebuildBlockers(oid: UInt32, table: [CellValue]) throws -> [String] {
        var blockers: [String] = []
        switch table[0].textValue {
        case "p": blockers.append("it is partitioned")
        case "f": blockers.append("it is a foreign table")
        default: break
        }
        if table[1].textValue == "t" { blockers.append("it is a partition") }
        if table[2].textValue == "t" { blockers.append("it is a typed table") }
        if table[3].textValue == "t" { blockers.append("row level security is enabled") }
        if table[10].textValue != "t" { blockers.append("only its owner (\(table[8].textValue ?? "another role")) can rebuild it") }

        let publicationsBySchema = serverVersionNumber >= 150_000
            ? """
              UNION ALL
              SELECT 'publication', p.pubname FROM pg_catalog.pg_publication_namespace pn
              JOIN pg_catalog.pg_publication p ON p.oid = pn.pnpubid
              JOIN pg_catalog.pg_class c ON c.relnamespace = pn.pnnspid WHERE c.oid = \(oid)
              """
            : ""
        let found = try rows("""
            SELECT 'view', r.ev_class::pg_catalog.regclass::text FROM pg_catalog.pg_depend d
            JOIN pg_catalog.pg_rewrite r ON r.oid = d.objid
            WHERE d.classid = 'pg_catalog.pg_rewrite'::pg_catalog.regclass AND d.refclassid = 'pg_catalog.pg_class'::pg_catalog.regclass
              AND d.refobjid = \(oid) AND r.ev_class <> \(oid)
            UNION ALL
            SELECT 'reference', con.conrelid::pg_catalog.regclass::text || ' (' || con.conname || ')' FROM pg_catalog.pg_constraint con
            WHERE con.contype = 'f' AND con.confrelid = \(oid) AND con.conrelid <> \(oid)
            UNION ALL
            SELECT 'trigger', t.tgname FROM pg_catalog.pg_trigger t WHERE t.tgrelid = \(oid) AND NOT t.tgisinternal
            UNION ALL
            SELECT 'parent', i.inhparent::pg_catalog.regclass::text FROM pg_catalog.pg_inherits i WHERE i.inhrelid = \(oid)
            UNION ALL
            SELECT 'child', i.inhrelid::pg_catalog.regclass::text FROM pg_catalog.pg_inherits i WHERE i.inhparent = \(oid)
            UNION ALL
            SELECT 'publication', p.pubname FROM pg_catalog.pg_publication_rel pr
            JOIN pg_catalog.pg_publication p ON p.oid = pr.prpubid WHERE pr.prrelid = \(oid)
            UNION ALL
            SELECT 'publication', p.pubname FROM pg_catalog.pg_publication p WHERE p.puballtables
            \(publicationsBySchema)
            UNION ALL
            SELECT 'policy', p.polname FROM pg_catalog.pg_policy p WHERE p.polrelid = \(oid)
            UNION ALL
            SELECT 'rule', r.rulename FROM pg_catalog.pg_rewrite r WHERE r.ev_class = \(oid) AND r.rulename <> '_RETURN'
            UNION ALL
            SELECT 'statistics', s.stxname FROM pg_catalog.pg_statistic_ext s WHERE s.stxrelid = \(oid)
            UNION ALL
            SELECT 'rowtype', a.attrelid::pg_catalog.regclass::text || '.' || a.attname FROM pg_catalog.pg_attribute a
            JOIN pg_catalog.pg_class c ON c.oid = \(oid)
            JOIN pg_catalog.pg_type t ON t.oid = c.reltype
            WHERE a.atttypid IN (t.oid, t.typarray) AND a.attrelid <> \(oid) AND NOT a.attisdropped
            UNION ALL
            SELECT 'other', pg_catalog.pg_describe_object(d.classid, d.objid, d.objsubid) FROM pg_catalog.pg_depend d
            WHERE d.refclassid = 'pg_catalog.pg_class'::pg_catalog.regclass AND d.refobjid = \(oid) AND d.deptype = 'n'
              AND d.classid NOT IN ('pg_catalog.pg_rewrite'::pg_catalog.regclass, 'pg_catalog.pg_constraint'::pg_catalog.regclass,
                                    'pg_catalog.pg_trigger'::pg_catalog.regclass, 'pg_catalog.pg_policy'::pg_catalog.regclass,
                                    'pg_catalog.pg_attrdef'::pg_catalog.regclass, 'pg_catalog.pg_statistic_ext'::pg_catalog.regclass)
            """)
        var byKind: [String: [String]] = [:]
        for row in found {
            guard row.count >= 2, let kind = row[0].textValue, let name = row[1].textValue else { continue }
            if byKind[kind]?.contains(name) != true { byKind[kind, default: []].append(name) }
        }
        let phrases: [(String, String)] = [
            ("view", "views depend on it"),
            ("reference", "other tables reference it with foreign keys"),
            ("trigger", "it has triggers"),
            ("parent", "it inherits from another table"),
            ("child", "other tables inherit from it"),
            ("publication", "it is published for replication"),
            ("policy", "it has row level security policies"),
            ("rule", "it has rules"),
            ("statistics", "it has extended statistics"),
            ("rowtype", "other columns use its row type"),
            ("other", "other objects depend on it"),
        ]
        for (kind, phrase) in phrases {
            guard let names = byKind[kind], !names.isEmpty else { continue }
            blockers.append("\(phrase) (\(names.joined(separator: ", ")))")
        }
        return blockers
    }

    private func rebuildColumns(oid: UInt32) throws -> [TableRebuildInfo.Column] {
        let generated = serverVersionNumber >= 120_000 ? "a.attgenerated" : "''"
        // PostgreSQL 18 keeps NOT NULL as named constraints.
        let notNullName = serverVersionNumber >= 180_000
            ? "(SELECT con.conname FROM pg_catalog.pg_constraint con WHERE con.conrelid = a.attrelid AND con.contype = 'n' AND con.conkey[1] = a.attnum)"
            : "NULL"
        let columnRows = try rows("""
            SELECT a.attname, pg_catalog.format_type(a.atttypid, a.atttypmod), a.attnotnull, \(notNullName),
                   pg_catalog.pg_get_expr(d.adbin, d.adrelid), a.attidentity, \(generated),
                   CASE WHEN a.attcollation <> 0 AND a.attcollation <> t.typcollation
                        THEN pg_catalog.quote_ident(cn.nspname) || '.' || pg_catalog.quote_ident(co.collname) END,
                   pg_catalog.col_description(a.attrelid, a.attnum),
                   sn.nspname, sc.relname,
                   s.seqstart, s.seqincrement, s.seqmin, s.seqmax, s.seqcache, s.seqcycle,
                   a.attacl IS NOT NULL
            FROM pg_catalog.pg_attribute a
            LEFT JOIN pg_catalog.pg_attrdef d ON d.adrelid = a.attrelid AND d.adnum = a.attnum
            LEFT JOIN pg_catalog.pg_type t ON t.oid = a.atttypid
            LEFT JOIN pg_catalog.pg_collation co ON co.oid = a.attcollation
            LEFT JOIN pg_catalog.pg_namespace cn ON cn.oid = co.collnamespace
            LEFT JOIN pg_catalog.pg_depend dep ON a.attidentity <> '' AND dep.refclassid = 'pg_catalog.pg_class'::pg_catalog.regclass
                 AND dep.refobjid = a.attrelid AND dep.refobjsubid = a.attnum AND dep.classid = 'pg_catalog.pg_class'::pg_catalog.regclass
                 AND dep.deptype = 'i'
            LEFT JOIN pg_catalog.pg_class sc ON sc.oid = dep.objid AND sc.relkind = 'S'
            LEFT JOIN pg_catalog.pg_namespace sn ON sn.oid = sc.relnamespace
            LEFT JOIN pg_catalog.pg_sequence s ON s.seqrelid = sc.oid
            WHERE a.attrelid = \(oid) AND a.attnum > 0 AND NOT a.attisdropped
            ORDER BY a.attnum
            """)
        return try columnRows.compactMap { row -> TableRebuildInfo.Column? in
            guard row.count >= 18, let name = row[0].textValue, let type = row[1].textValue else { return nil }
            let identity = row[5].textValue.flatMap { $0.isEmpty ? nil : $0 }
            let generationKind = row[6].textValue.flatMap { $0.isEmpty ? nil : $0 }
            var column = TableRebuildInfo.Column(
                name: name,
                dataType: type,
                isNotNull: row[2].textValue == "t",
                notNullConstraint: row[3].textValue,
                defaultExpression: generationKind == nil ? row[4].textValue : nil,
                identity: identity,
                generationExpression: generationKind != nil ? row[4].textValue : nil,
                generationKind: generationKind,
                collation: row[7].textValue,
                comment: row[8].textValue
            )
            if identity != nil, let sequence = row[10].textValue {
                column.identitySequence = TableRef(schema: row[9].textValue, name: sequence)
                // No AS type: an identity sequence takes the column's type, and naming it again is an error.
                var options: [String] = []
                if let start = row[11].textValue { options.append("START WITH \(start)") }
                if let increment = row[12].textValue { options.append("INCREMENT BY \(increment)") }
                if let minimum = row[13].textValue { options.append("MINVALUE \(minimum)") }
                if let maximum = row[14].textValue { options.append("MAXVALUE \(maximum)") }
                if let cache = row[15].textValue { options.append("CACHE \(cache)") }
                options.append(row[16].textValue == "t" ? "CYCLE" : "NO CYCLE")
                column.identityOptions = options.joined(separator: " ")
            }
            if row[17].textValue == "t" {
                column.privileges = try privileges("""
                    SELECT a.attacl, c.relowner FROM pg_catalog.pg_attribute a JOIN pg_catalog.pg_class c ON c.oid = a.attrelid
                    WHERE a.attrelid = \(oid) AND a.attname = \(dialect.quoteString(name))
                    """)
            }
            return column
        }
    }

    /// Every constraint but NOT NULL, which the columns carry.
    private func rebuildConstraints(oid: UInt32) throws -> [TableRebuildInfo.Constraint] {
        try rows("""
            SELECT con.conname, con.contype, pg_catalog.pg_get_constraintdef(con.oid),
                   pg_catalog.obj_description(con.oid, 'pg_constraint'),
                   CASE WHEN con.contype IN ('p', 'u', 'x') THEN pg_catalog.obj_description(con.conindid, 'pg_class') END
            FROM pg_catalog.pg_constraint con
            WHERE con.conrelid = \(oid) AND con.contype IN ('p', 'u', 'x', 'c', 'f')
            ORDER BY con.conname
            """).compactMap { row in
            guard row.count >= 5, let name = row[0].textValue, let kind = row[1].textValue, let definition = row[2].textValue else { return nil }
            return TableRebuildInfo.Constraint(name: name, kind: kind, definition: definition, comment: row[3].textValue, indexComment: row[4].textValue)
        }
    }

    /// Indexes that no constraint of this table owns.
    private func rebuildIndexes(oid: UInt32) throws -> [TableRebuildInfo.Index] {
        try rows("""
            SELECT ic.relname, pg_catalog.pg_get_indexdef(i.indexrelid), pg_catalog.obj_description(i.indexrelid, 'pg_class')
            FROM pg_catalog.pg_index i
            JOIN pg_catalog.pg_class ic ON ic.oid = i.indexrelid
            WHERE i.indrelid = \(oid)
              AND NOT EXISTS (SELECT 1 FROM pg_catalog.pg_constraint con WHERE con.conindid = i.indexrelid AND con.conrelid = \(oid))
            ORDER BY ic.relname
            """).compactMap { row in
            guard row.count >= 3, let name = row[0].textValue, let definition = row[1].textValue else { return nil }
            return TableRebuildInfo.Index(name: name, definition: definition, comment: row[2].textValue)
        }
    }

    /// Sequences a column owns (serial columns), which go with the table when it is dropped.
    private func ownedSequences(oid: UInt32) throws -> [TableRebuildInfo.OwnedSequence] {
        try rows("""
            SELECT sn.nspname, sc.relname, a.attname
            FROM pg_catalog.pg_depend dep
            JOIN pg_catalog.pg_class sc ON sc.oid = dep.objid AND sc.relkind = 'S'
            JOIN pg_catalog.pg_namespace sn ON sn.oid = sc.relnamespace
            JOIN pg_catalog.pg_attribute a ON a.attrelid = dep.refobjid AND a.attnum = dep.refobjsubid
            WHERE dep.classid = 'pg_catalog.pg_class'::pg_catalog.regclass AND dep.refclassid = 'pg_catalog.pg_class'::pg_catalog.regclass
              AND dep.refobjid = \(oid) AND dep.deptype = 'a'
            ORDER BY a.attnum
            """).compactMap { row in
            guard row.count >= 3, let sequence = row[1].textValue, let column = row[2].textValue else { return nil }
            return TableRebuildInfo.OwnedSequence(sequence: TableRef(schema: row[0].textValue, name: sequence), column: column)
        }
    }

    /// The grants of an ACL. `source` selects the ACL and the table owner, whose own privileges are left out:
    /// the owner of the new table has them anyway.
    private func privileges(_ source: String) throws -> [TableRebuildInfo.Privilege] {
        try rows("""
            SELECT CASE WHEN x.grantee = 0 THEN NULL ELSE pg_catalog.pg_get_userbyid(x.grantee) END, x.privilege_type, x.is_grantable
            FROM (\(source)) src(acl, owner), pg_catalog.aclexplode(src.acl) x
            WHERE x.grantee <> src.owner
            """).compactMap { row in
            guard row.count >= 3, let privilege = row[1].textValue else { return nil }
            return TableRebuildInfo.Privilege(grantee: row[0].textValue, privilege: privilege, isGrantable: row[2].textValue == "t")
        }
    }

    private static func jsonStrings(_ json: String?) -> [String] {
        guard let data = json?.data(using: .utf8) else { return [] }
        return (try? JSONDecoder().decode([String].self, from: data)) ?? []
    }
}
