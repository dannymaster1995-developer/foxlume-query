import Testing
@testable import FoxlumeQueryCore

@Suite struct SQLFormatterTests {
    @Test func formatsSelectWithConditions() {
        let sql = "select id, name from users where status = 'paid' and total > 10 order by id desc limit 5"
        #expect(SQLFormatter.format(sql) == """
        SELECT
            id,
            name
        FROM
            users
        WHERE
            status = 'paid'
            AND total > 10
        ORDER BY
            id DESC
        LIMIT 5
        """)
    }

    @Test func formatsJoinsAndFunctions() {
        let sql = "select u.name, count(o.id) as n from users u left join orders o on o.user_id = u.id and o.status <> 'x' group by u.name"
        #expect(SQLFormatter.format(sql) == """
        SELECT
            u.name,
            count(o.id) AS n
        FROM
            users u
            LEFT JOIN orders o ON o.user_id = u.id
                AND o.status <> 'x'
        GROUP BY
            u.name
        """)
    }

    @Test func nestsSubqueries() {
        let sql = "select * from (select id from t where a in (1, 2)) x where x.id in (select id from y)"
        #expect(SQLFormatter.format(sql) == """
        SELECT
            *
        FROM
            (
                SELECT
                    id
                FROM
                    t
                WHERE
                    a IN (1, 2)
            ) x
        WHERE
            x.id IN (
                SELECT
                    id
                FROM
                    y
            )
        """)
    }

    @Test func keepsStringsCommentsAndSeparatesStatements() {
        let sql = "insert into t (a, b) values ('select from', 1), ('x', 2); -- done\nupdate t set a = 'Müller', b = b + 1 where id = 3"
        #expect(SQLFormatter.format(sql) == """
        INSERT INTO
            t (a, b)
        VALUES
            ('select from', 1),
            ('x', 2);

        -- done
        UPDATE
            t
        SET
            a = 'Müller',
            b = b + 1
        WHERE
            id = 3
        """)
    }

    @Test func caseExpressionsStayInline() {
        let sql = "select case when a > 1 then 'big' else 'small' end as size, b::text from t"
        #expect(SQLFormatter.format(sql) == """
        SELECT
            CASE WHEN a > 1 THEN 'big' ELSE 'small' END AS size,
            b::text
        FROM
            t
        """)
    }
}
