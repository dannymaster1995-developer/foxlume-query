import Foundation
import Testing
@testable import FoxlumeQueryCore

@Suite struct ConnectionURLTests {
    @Test func parsesPostgresWithSSLMode() throws {
        let parsed = try #require(ConnectionURL.parse("postgresql://an%40corp:p%40ss@db.example.com:6543/shop?sslmode=require"))
        #expect(parsed.config.kind == .postgresql)
        #expect(parsed.config.user == "an@corp")
        #expect(parsed.password == "p@ss")
        #expect(parsed.config.host == "db.example.com")
        #expect(parsed.config.port == 6543)
        #expect(parsed.config.database == "shop")
        #expect(parsed.config.sslMode == .require)
    }

    @Test func defaultsPortAndUser() throws {
        let parsed = try #require(ConnectionURL.parse("mysql://localhost/app"))
        #expect(parsed.config.port == 3306)
        #expect(parsed.config.user == "root")
    }

    @Test func redisDatabaseIndexAndTLS() throws {
        let plain = try #require(ConnectionURL.parse("redis://:secret@cache:6380/3"))
        #expect(plain.config.database == "3")
        #expect(plain.password == "secret")
        #expect(plain.config.user == "")
        #expect(plain.config.sslMode == .disable)
        let tls = try #require(ConnectionURL.parse("rediss://default:pw@cache"))
        #expect(tls.config.sslMode == .require)
        #expect(tls.config.port == 6379)
    }

    @Test func mongoKeepsTheConnectionStringWithoutItsPassword() throws {
        let uri = "mongodb+srv://user:pw@cluster0.abc.mongodb.net/app?retryWrites=true"
        let parsed = try #require(ConnectionURL.parse(uri))
        #expect(parsed.config.kind == .mongodb)
        #expect(parsed.config.option(.mongoConnectionString) == "mongodb+srv://user@cluster0.abc.mongodb.net/app?retryWrites=true")
        #expect(parsed.config.option(.mongoSRV) == "true")
        #expect(parsed.password == "pw")
        let multi = try #require(ConnectionURL.parse("mongodb://a:27017,b:27018/db?replicaSet=rs0"))
        #expect(multi.config.database == "db")
    }

    @Test func fileURLsForEmbeddedEngines() throws {
        let parsed = try #require(ConnectionURL.parse("sqlite:///Users/me/data/app.db"))
        #expect(parsed.config.kind == .sqlite)
        #expect(parsed.config.filePath == "/Users/me/data/app.db")
        #expect(ConnectionURL.parse("ftp://nope") == nil)
    }

    @Test func embeddedMongoPasswordsMoveOutOfTheConfig() {
        #expect(ConnectionConfig.strippingPassword(fromURI: "mongodb://app:p%40ss:word@h1:27017,h2/db?authSource=admin")
            == ("mongodb://app@h1:27017,h2/db?authSource=admin", "p@ss:word"))
        #expect(ConnectionConfig.strippingPassword(fromURI: "mongodb://app@h1/db") == ("mongodb://app@h1/db", nil))
        #expect(ConnectionConfig.strippingPassword(fromURI: "mongodb://h1/db?x=a:b@c") == ("mongodb://h1/db?x=a:b@c", nil))

        var config = ConnectionConfig(kind: .mongodb, host: "mongodb://root:secret@127.0.0.1:57017/admin")
        config.setOption(.mongoConnectionString, "mongodb://reader:readerpass@127.0.0.1/foxlume")
        #expect(config.removeEmbeddedPassword() == "readerpass")
        #expect(config.option(.mongoConnectionString) == "mongodb://reader@127.0.0.1/foxlume")
        #expect(config.host == "mongodb://root@127.0.0.1:57017/admin")
        #expect(config.removeEmbeddedPassword() == nil)

        var postgres = ConnectionConfig(kind: .postgresql, host: "db.example.com")
        #expect(postgres.removeEmbeddedPassword() == nil)
    }
}

@Suite struct ConnectionURLTLSTests {
    @Test func postgresCertificateParameters() throws {
        let parsed = try #require(ConnectionURL.parse("postgresql://app@db.example.com/shop?sslmode=verify-ca&sslrootcert=/etc/ssl/root.pem&sslcert=~/certs/app.crt&sslkey=%2Ftmp%2Fapp.key&sslpassword=pa%26ss"))
        #expect(parsed.config.sslMode == .verifyCA)
        #expect(parsed.config.certificates.caCertificatePath == "/etc/ssl/root.pem")
        #expect(parsed.config.certificates.clientCertificatePath == NSHomeDirectory() + "/certs/app.crt")
        #expect(parsed.config.certificates.clientKeyPath == "/tmp/app.key")
        #expect(parsed.tlsSecret == "pa&ss")
    }

    @Test(arguments: [
        ("disable", SSLMode.disable), ("allow", .prefer), ("prefer", .prefer), ("require", .require),
        ("verify-ca", .verifyCA), ("VERIFY_CA", .verifyCA), ("verify-full", .verifyFull), ("VERIFY_IDENTITY", .verifyFull),
    ])
    func sslModeSpellings(text: String, mode: SSLMode) throws {
        let parsed = try #require(ConnectionURL.parse("postgres://u@h/db?sslmode=\(text)"))
        #expect(parsed.config.sslMode == mode)
    }

    @Test func systemRootMeansNoCAFile() throws {
        let parsed = try #require(ConnectionURL.parse("postgres://u@h/db?sslmode=verify-full&sslrootcert=system"))
        #expect(parsed.config.sslMode == .verifyFull)
        #expect(parsed.config.tlsFiles == nil)
    }

    @Test func mysqlCertificateParameters() throws {
        let parsed = try #require(ConnectionURL.parse("mysql://root:pw@db:3306/app?ssl-mode=VERIFY_IDENTITY&ssl-ca=/ca.pem&ssl-cert=/c.pem&ssl-key=/k.pem"))
        #expect(parsed.config.sslMode == .verifyFull)
        #expect(parsed.config.certificates == TLSCertificateFiles(caCertificatePath: "/ca.pem", clientCertificatePath: "/c.pem", clientKeyPath: "/k.pem"))
        #expect(parsed.tlsSecret == nil)
        // libpq names mean nothing to MySQL.
        #expect(try #require(ConnectionURL.parse("mysql://root@db/app?sslrootcert=/ca.pem")).config.tlsFiles == nil)
    }
}
