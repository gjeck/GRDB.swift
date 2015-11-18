import XCTest
import GRDB

typealias DatabaseFunction = (context: COpaquePointer, argc: Int32, argv: UnsafeMutablePointer<COpaquePointer>) -> Void
private let SQLITE_TRANSIENT = unsafeBitCast(COpaquePointer(bitPattern: -1), sqlite3_destructor_type.self)

struct CustomFunctionResult : DatabaseValueConvertible {
    var databaseValue: DatabaseValue {
        return DatabaseValue(string: "CustomFunctionResult")
    }
    static func fromDatabaseValue(databaseValue: DatabaseValue) -> CustomFunctionResult? {
        guard let string = String.fromDatabaseValue(databaseValue) where string == "CustomFunctionResult" else {
            return nil
        }
        return CustomFunctionResult()
    }
}

class FunctionTests: GRDBTestCase {
//    // Crash: SQLite error 1 with statement `SELECT f(1)`: wrong number of arguments to function f()
//    func testAddFunctionArity0WithBadNumberOfArguments() {
//        assertNoError {
//            dbQueue.inDatabase { db in
//                db.addFunction("f") { nil }
//                Row.fetchOne(db, "SELECT f(1)")
//            }
//        }
//    }
    
    func testAddFunctionReturningNull() {
        assertNoError {
            dbQueue.inDatabase { db in
                db.addFunction("f", argumentCount: 0) { databaseValues in nil }
                XCTAssertTrue(Row.fetchOne(db, "SELECT f()")!.value(atIndex: 0) == nil)
            }
        }
    }
    
    func testAddFunctionReturningInt64() {
        assertNoError {
            dbQueue.inDatabase { db in
                db.addFunction("f", argumentCount: 0) { databaseValues in Int64(1) }
                XCTAssertEqual(Int64.fetchOne(db, "SELECT f()")!, Int64(1))
            }
        }
    }
    
    func testAddFunctionReturningDouble() {
        assertNoError {
            dbQueue.inDatabase { db in
                db.addFunction("f", argumentCount: 0) { databaseValues in 1e100 }
                XCTAssertEqual(Double.fetchOne(db, "SELECT f()")!, 1e100)
            }
        }
    }
    
    func testAddFunctionReturningString() {
        assertNoError {
            dbQueue.inDatabase { db in
                db.addFunction("f", argumentCount: 0) { databaseValues in "foo" }
                XCTAssertEqual(String.fetchOne(db, "SELECT f()")!, "foo")
            }
        }
    }
    
    func testAddFunctionReturningData() {
        assertNoError {
            dbQueue.inDatabase { db in
                let data = "foo".dataUsingEncoding(NSUTF8StringEncoding)
                db.addFunction("f", argumentCount: 0) { databaseValues in data }
                XCTAssertEqual(NSData.fetchOne(db, "SELECT f()")!, "foo".dataUsingEncoding(NSUTF8StringEncoding))
            }
        }
    }
    
    func testAddFunctionReturningCustomFunctionResult() {
        assertNoError {
            dbQueue.inDatabase { db in
                db.addFunction("f", argumentCount: 0) { databaseValues in CustomFunctionResult() }
                XCTAssertTrue(CustomFunctionResult.fetchOne(db, "SELECT f()") != nil)
            }
        }
    }
    
    func testFunctionWithoutArgument() {
        assertNoError {
            dbQueue.inDatabase { db in
                db.addFunction("f", argumentCount: 0) { databaseValues in
                    return "foo"
                }
                XCTAssertEqual(String.fetchOne(db, "SELECT f()")!, "foo")
            }
        }
    }
    
    func testFunctionOfOneArgument() {
        assertNoError {
            dbQueue.inDatabase { db in
                db.addFunction("f", argumentCount: 1) { databaseValues in
                    guard let int = databaseValues.first!.value() as Int? else {
                        return nil
                    }
                    return int + 1
                }
                XCTAssertEqual(Int.fetchOne(db, "SELECT f(2)")!, 3)
                XCTAssertTrue(Int.fetchOne(db, "SELECT f(NULL)") == nil)
            }
        }
    }
    
    func testFunctionOfTwoArguments() {
        assertNoError {
            dbQueue.inDatabase { db in
                db.addFunction("f", argumentCount: 2) { databaseValues in
                    let ints = databaseValues.flatMap { $0.value() as Int? }
                    let sum = ints.reduce(0) { $0 + $1 }
                    return sum
                }
                XCTAssertEqual(Int.fetchOne(db, "SELECT f(1, 2)")!, 3)
            }
        }
    }
    
    func testVariadicFunction() {
        assertNoError {
            dbQueue.inDatabase { db in
                db.addVariadicFunction("f") { databaseValues in
                    return databaseValues.count
                }
                XCTAssertEqual(Int.fetchOne(db, "SELECT f()")!, 0)
                XCTAssertEqual(Int.fetchOne(db, "SELECT f(1)")!, 1)
                XCTAssertEqual(Int.fetchOne(db, "SELECT f(1, 1)")!, 2)
            }
        }
    }
    
    func testFunctionsAreClosures() {
        assertNoError {
            dbQueue.inDatabase { db in
                let x = 123
                db.addFunction("f", argumentCount: 0) { databaseValues in
                    return x
                }
                XCTAssertEqual(Int.fetchOne(db, "SELECT f()")!, 123)
            }
        }
    }
}
