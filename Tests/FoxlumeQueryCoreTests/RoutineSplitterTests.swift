import Foundation
import Testing
@testable import FoxlumeQueryCore

/// Routine bodies written as compound statements stay one statement, so scripts run without DELIMITER.
@Suite struct RoutineSplitterTests {
    private func split(_ sql: String, _ family: SQLDialect.Family) -> [String] {
        SQLStatementSplitter.split(sql, family: family).map(\.text)
    }

    @Test func mysqlProcedureWithNestedBlocksIsOneStatement() {
        let procedure = """
            CREATE DEFINER=`root`@`%` PROCEDURE `fq_rt_proc`(IN p_id INT, OUT p_total DECIMAL(10,2))
            BEGIN
              DECLARE done INT DEFAULT 0;
              DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN ROLLBACK; END;
              IF p_id > 0 THEN
                SET p_total = (SELECT CASE WHEN p_id > 10 THEN 1 ELSE 0 END);
              ELSEIF p_id = 0 THEN
                SET p_total = 0;
              END IF;
              lbl: LOOP
                SET done = done + 1;
                IF done > 3 THEN LEAVE lbl; END IF;
              END LOOP lbl;
              WHILE done < 5 DO SET done = done + 1; END WHILE;
              REPEAT SET done = done - 1; UNTIL done = 0 END REPEAT;
              CASE p_id WHEN 1 THEN SET p_total = 1; ELSE SET p_total = 2; END CASE;
            END
            """
        let parts = split("DROP PROCEDURE IF EXISTS `fq_rt_proc`;\n\(procedure);\nSELECT 1;", .mysql)
        #expect(parts == ["DROP PROCEDURE IF EXISTS `fq_rt_proc`", procedure, "SELECT 1"])
    }

    @Test func mysqlFunctionTriggerAndEvent() {
        let function = "CREATE FUNCTION f(x INT) RETURNS INT DETERMINISTIC RETURN CASE WHEN x > 0 THEN 1 ELSE 0 END"
        let trigger = "CREATE TRIGGER t BEFORE INSERT ON items FOR EACH ROW BEGIN SET NEW.`end` = 1; SET NEW.begin = NEW.end; END"
        let simpleTrigger = "CREATE TRIGGER t2 AFTER DELETE ON items FOR EACH ROW SET @n = 1"
        let event = "CREATE EVENT e ON SCHEDULE EVERY 1 HOUR DO BEGIN DELETE FROM log; INSERT INTO log VALUES (1); END"
        let parts = split([function, trigger, simpleTrigger, event, "SELECT 2"].joined(separator: ";\n"), .mysql)
        #expect(parts == [function, trigger, simpleTrigger, event, "SELECT 2"])
    }

    @Test func transactionsAndOrdinaryStatementsStillSplit() {
        #expect(split("BEGIN; UPDATE t SET a = 1; COMMIT;", .mysql) == ["BEGIN", "UPDATE t SET a = 1", "COMMIT"])
        #expect(split("BEGIN; UPDATE t SET a = 1; END;", .postgresql) == ["BEGIN", "UPDATE t SET a = 1", "END"])
        #expect(split("CREATE TABLE trigger_log (id int, `begin` int); SELECT 1", .mysql) == ["CREATE TABLE trigger_log (id int, `begin` int)", "SELECT 1"])
        #expect(split("SELECT CASE WHEN a THEN 1 END FROM t; SELECT 2", .mysql) == ["SELECT CASE WHEN a THEN 1 END FROM t", "SELECT 2"])
    }

    @Test func sqliteTriggerBody() {
        let trigger = "CREATE TEMP TRIGGER IF NOT EXISTS t AFTER INSERT ON items BEGIN UPDATE items SET n = n + 1 WHERE id = NEW.id; INSERT INTO log VALUES ('end;'); END"
        #expect(split(trigger + "; SELECT 1", .sqlite) == [trigger, "SELECT 1"])
    }

    @Test func postgresBeginAtomicAndDollarBodies() {
        let atomic = "CREATE OR REPLACE FUNCTION public.f(a integer)\n RETURNS integer\n LANGUAGE sql\nBEGIN ATOMIC\n SELECT CASE WHEN a > 0 THEN a ELSE 0 END;\n SELECT 1;\nEND"
        let dollar = "CREATE FUNCTION g() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN NEW.x := 1; RETURN NEW; END $$"
        let parts = split("\(atomic);\n\(dollar);\nCREATE TRIGGER trg BEFORE INSERT ON t FOR EACH ROW EXECUTE FUNCTION g();\nSELECT 3", .postgresql)
        #expect(parts == [atomic, dollar, "CREATE TRIGGER trg BEFORE INSERT ON t FOR EACH ROW EXECUTE FUNCTION g()", "SELECT 3"])
    }

    @Test func statementAtCursorInsideABodyIsTheWholeRoutine() {
        let sql = "SELECT 0;\nCREATE PROCEDURE p() BEGIN SELECT 1; SELECT 2; END;\nSELECT 3"
        let location = (sql as NSString).range(of: "SELECT 2").location
        #expect(SQLStatementSplitter.statement(at: location, in: sql, family: .mysql)?.text == "CREATE PROCEDURE p() BEGIN SELECT 1; SELECT 2; END")
    }
}
