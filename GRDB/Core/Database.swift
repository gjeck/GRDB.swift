import Foundation

/// A raw SQLite connection, suitable for the SQLite C API.
public typealias SQLiteConnection = COpaquePointer

/// A Database connection.
///
/// You don't create a database directly. Instead, you use a DatabaseQueue:
///
///     let dbQueue = DatabaseQueue(...)
///
///     // The Database is the `db` in the closure:
///     dbQueue.inDatabase { db in
///         db.execute(...)
///     }
public final class Database {
    
    /// The database configuration
    public let configuration: Configuration
    
    /// The raw SQLite connection, suitable for the SQLite C API.
    public let sqliteConnection: SQLiteConnection
    
    var lastErrorMessage: String? { return String.fromCString(sqlite3_errmsg(sqliteConnection)) }
    
    private var functions = Set<DatabaseFunction>()
    private var collations = Set<DatabaseCollation>()
    
    private var primaryKeyCache: [String: PrimaryKey] = [:]
    private var updateStatementCache: [String: UpdateStatement] = [:]
    private var selectStatementCache: [String: SelectStatement] = [:]
    
    /// See setupTransactionHooks(), updateStatementDidFail(), updateStatementDidExecute()
    private var transactionState: TransactionState = .WaitForTransactionCompletion
    
    /// The transaction observers
    private var transactionObservers = [TransactionObserverType]()
    
    /// See setupBusyMode()
    private var busyCallback: BusyCallback?
    
    /// The queue from which the database can be used.
    /// See preconditionValidQueue().
    var databaseQueueID: DatabaseQueueID = nil
    
    init(path: String, configuration: Configuration) throws {
        self.configuration = configuration
        
        // See https://www.sqlite.org/c3ref/open.html
        var sqliteConnection = SQLiteConnection()
        let code = sqlite3_open_v2(path, &sqliteConnection, configuration.sqliteOpenFlags, nil)
        self.sqliteConnection = sqliteConnection
        if code != SQLITE_OK {
            throw DatabaseError(code: code, message: String.fromCString(sqlite3_errmsg(sqliteConnection)))
        }
        
        // Setup trace first, so that all queries, including initialization queries, are traced.
        setupTrace()
        
        try setupForeignKeys()
        setupBusyMode()
    }
    
    // Initializes an in-memory database
    convenience init(configuration: Configuration) {
        try! self.init(path: ":memory:", configuration: configuration)
    }
    
    deinit {
        sqlite3_close(sqliteConnection)
    }
    
    func preconditionValidQueue() {
        precondition(databaseQueueID == nil || databaseQueueID == dispatch_get_specific(DatabaseQueue.databaseQueueIDKey), "Database was not used on the correct thread: execute your statements inside DatabaseQueue.inDatabase() or DatabaseQueue.inTransaction(). If you get this error while iterating the result of a fetch() method, consider using the array returned by fetchAll() instead.")
    }
    
    private func setupForeignKeys() throws {
        if configuration.foreignKeysEnabled {
            try execute("PRAGMA foreign_keys = ON")
        }
    }
    
    private func setupTrace() {
        guard configuration.trace != nil else {
            return
        }
        let dbPointer = unsafeBitCast(self, UnsafeMutablePointer<Void>.self)
        sqlite3_trace(sqliteConnection, { (dbPointer, sql) in
            let database = unsafeBitCast(dbPointer, Database.self)
            database.configuration.trace!(String.fromCString(sql)!)
            }, dbPointer)
    }
    
    private func setupBusyMode() {
        switch configuration.busyMode {
        case .ImmediateError:
            break
            
        case .Timeout(let duration):
            let milliseconds = Int32(duration * 1000)
            sqlite3_busy_timeout(sqliteConnection, milliseconds)
            
        case .Callback(let callback):
            let dbPointer = unsafeBitCast(self, UnsafeMutablePointer<Void>.self)
            busyCallback = callback
            
            sqlite3_busy_handler(
                sqliteConnection,
                { (dbPointer: UnsafeMutablePointer<Void>, numberOfTries: Int32) in
                    let database = unsafeBitCast(dbPointer, Database.self)
                    let callback = database.busyCallback!
                    return callback(numberOfTries: Int(numberOfTries)) ? 1 : 0
                },
                dbPointer)
        }
    }
}


/// A SQLite threading mode. See https://www.sqlite.org/threadsafe.html.
enum ThreadingMode {
    case Default
    case MultiThread
    case Serialized
    
    var sqliteOpenFlags: Int32 {
        switch self {
        case .Default:
            return 0
        case .MultiThread:
            return SQLITE_OPEN_NOMUTEX
        case .Serialized:
            return SQLITE_OPEN_FULLMUTEX
        }
    }
}


/// See BusyMode and https://www.sqlite.org/c3ref/busy_handler.html
public typealias BusyCallback = (numberOfTries: Int) -> Bool

/// When there are several connections to a database, a connection may try to
/// access the database while it is locked by another connection.
///
/// The BusyMode enum describes the behavior of GRDB when such a situation
/// occurs:
///
/// - .ImmediateError: The SQLITE_BUSY error is immediately returned to the
///   connection that tries to access the locked database.
///
/// - .Timeout: The SQLITE_BUSY error will be returned only if the database
///   remains locked for more than the specified duration.
///
/// - .Callback: Perform your custom lock handling.
///
/// To set the busy mode of a database, use Configuration:
///
///     let configuration = Configuration(busyMode: .Timeout(1))
///     let dbQueue = DatabaseQueue(path: "...", configuration: configuration)
///
/// Relevant SQLite documentation:
///
/// - https://www.sqlite.org/c3ref/busy_timeout.html
/// - https://www.sqlite.org/c3ref/busy_handler.html
/// - https://www.sqlite.org/lang_transaction.html
/// - https://www.sqlite.org/wal.html
public enum BusyMode {
    /// The SQLITE_BUSY error is immediately returned to the connection that
    /// tries to access the locked database.
    case ImmediateError
    
    /// The SQLITE_BUSY error will be returned only if the database remains
    /// locked for more than the specified duration.
    case Timeout(NSTimeInterval)
    
    /// A custom callback that is called when a database is locked.
    /// See https://www.sqlite.org/c3ref/busy_handler.html
    case Callback(BusyCallback)
}


// =========================================================================
// MARK: - Statements

extension Database {
    
    /// Returns a prepared statement that can be reused.
    ///
    ///     let statement = try db.selectStatement("SELECT * FROM persons WHERE age > ?")
    ///     let moreThanTwentyCount = Int.fetchOne(statement, arguments: [20])!
    ///     let moreThanThirtyCount = Int.fetchOne(statement, arguments: [30])!
    ///
    /// - parameter sql: An SQL query.
    /// - returns: A SelectStatement.
    /// - throws: A DatabaseError whenever SQLite could not parse the sql query.
    public func selectStatement(sql: String) throws -> SelectStatement {
        return try SelectStatement(database: self, sql: sql)
    }
    
    func cachedSelectStatement(sql: String) throws -> SelectStatement {
        if let statement = selectStatementCache[sql] {
            return statement
        }
        
        let statement = try selectStatement(sql)
        selectStatementCache[sql] = statement
        return statement
    }
    
    /// Returns a prepared statement that can be reused.
    ///
    ///     let statement = try db.updateStatement("INSERT INTO persons (name) VALUES (?)")
    ///     try statement.execute(arguments: ["Arthur"])
    ///     try statement.execute(arguments: ["Barbara"])
    ///
    /// This method may throw a DatabaseError.
    ///
    /// - parameter sql: An SQL query.
    /// - returns: An UpdateStatement.
    /// - throws: A DatabaseError whenever SQLite could not parse the sql query.
    public func updateStatement(sql: String) throws -> UpdateStatement {
        return try UpdateStatement(database: self, sql: sql)
    }
    
    func cachedUpdateStatement(sql: String) throws -> UpdateStatement {
        if let statement = updateStatementCache[sql] {
            return statement
        }
        
        let statement = try updateStatement(sql)
        updateStatementCache[sql] = statement
        return statement
    }
    
    /// Executes one or several SQL statements, separated by semi-colons.
    ///
    ///     try db.execute(
    ///         "INSERT INTO persons (name) VALUES (:name)",
    ///         arguments: ["name": "Arthur"])
    ///
    ///     try db.execute(
    ///         "INSERT INTO persons (name) VALUES (?);" +
    ///         "INSERT INTO persons (name) VALUES (?);" +
    ///         "INSERT INTO persons (name) VALUES (?);",
    ///         arguments; ['Harry', 'Ron', 'Hermione'])
    ///
    /// This method may throw a DatabaseError.
    ///
    /// - parameter sql: An SQL query.
    /// - parameter arguments: Optional statement arguments.
    /// - returns: A DatabaseChanges.
    /// - throws: A DatabaseError whenever a SQLite error occurs.
    public func execute(sql: String, arguments: StatementArguments? = nil) throws -> DatabaseChanges {
        preconditionValidQueue()
        
        // The tricky part is to consume arguments as statements are executed.
        //
        // Here we build two functions:
        // - consumeArguments returns arguments for a statement
        // - validateRemainingArguments validates the remaining arguments, after
        //   all statements have been executed, in the same way
        //   as Statement.validateArguments()
        let consumeArguments: UpdateStatement -> StatementArguments
        let validateRemainingArguments: () throws -> ()
        
        if let arguments = arguments {
            switch arguments.kind {
            case .Values(let values):
                // Extract as many values as needed, statement after statement:
                var remainingValues = values
                consumeArguments = { (statement: UpdateStatement) -> StatementArguments in
                    let argumentCount = statement.sqliteArgumentCount
                    defer {
                        if remainingValues.count >= argumentCount {
                            remainingValues = Array(remainingValues.suffixFrom(argumentCount))
                        } else {
                            remainingValues = []
                        }
                    }
                    return StatementArguments(remainingValues.prefix(argumentCount))
                }
                // It's not OK if there remains unused arguments:
                validateRemainingArguments = {
                    if !remainingValues.isEmpty {
                        throw DatabaseError(code: SQLITE_MISUSE, message: "wrong number of statement arguments: \(values.count)")
                    }
                }
            case .NamedValues:
                // Reuse the dictionary argument for all statements:
                consumeArguments = { _ in return arguments }
                validateRemainingArguments = { _ in }
            }
        } else {
            // Empty arguments for all statements:
            consumeArguments = { _ in return [] }
            validateRemainingArguments = { _ in }
        }
        
        
        // Execute statements
        
        let changedRowsBefore = sqlite3_total_changes(sqliteConnection)
        let sqlCodeUnits = sql.nulTerminatedUTF8
        var error: ErrorType?
        sqlCodeUnits.withUnsafeBufferPointer { codeUnits in
            let sqlStart = UnsafePointer<Int8>(codeUnits.baseAddress)
            let sqlEnd = sqlStart + sqlCodeUnits.count
            var statementStart = sqlStart
            while statementStart < sqlEnd - 1 {
                var statementEnd: UnsafePointer<Int8> = nil
                var sqliteStatement: SQLiteStatement = nil
                let code = sqlite3_prepare_v2(sqliteConnection, statementStart, -1, &sqliteStatement, &statementEnd)
                guard code == SQLITE_OK else {
                    error = DatabaseError(code: code, message: lastErrorMessage, sql: sql)
                    break
                }
                let sql = NSString(bytes: statementStart, length: statementEnd - statementStart, encoding: NSUTF8StringEncoding)! as String
                let statement = UpdateStatement(database: self, sql: sql, sqliteStatement: sqliteStatement)
                
                do {
                    try statement.execute(arguments: consumeArguments(statement))
                } catch let statementError {
                    error = statementError
                    break
                }
                
                statementStart = statementEnd
            }
        }
        if let error = error {
            throw error
        }
        // Force arguments validity. See UpdateStatement.execute(), and SelectStatement.fetchSequence()
        try! validateRemainingArguments()
        
        let changedRowsAfter = sqlite3_total_changes(sqliteConnection)
        let lastInsertedRowID = sqlite3_last_insert_rowid(sqliteConnection)
        let insertedRowID: Int64? = (lastInsertedRowID == 0) ? nil : lastInsertedRowID
        return DatabaseChanges(changedRowCount: changedRowsAfter - changedRowsBefore, insertedRowID: insertedRowID)
    }
    
    
}


// =========================================================================
// MARK: - Functions

extension Database {
    
    /// Add or redefine an SQL function.
    ///
    ///     let fn = DatabaseFunction("succ", argumentCount: 1) { databaseValues in
    ///         let dbv = databaseValues.first!
    ///         guard let int = dbv.value() as Int? else {
    ///             return nil
    ///         }
    ///         return int + 1
    ///     }
    ///     db.addFunction(fn)
    ///     Int.fetchOne(db, "SELECT succ(1)")! // 2
    public func addFunction(function: DatabaseFunction) {
        functions.remove(function)
        functions.insert(function)
        let functionPointer = unsafeBitCast(function, UnsafeMutablePointer<Void>.self)
        let code = sqlite3_create_function_v2(
            sqliteConnection,
            function.name,
            function.argumentCount,
            SQLITE_UTF8 | function.eTextRep,
            functionPointer,
            { (context, argc, argv) in
                let function = unsafeBitCast(sqlite3_user_data(context), DatabaseFunction.self)
                do {
                    let result = try function.function(context, argc, argv)
                    switch result.storage {
                    case .Null:
                        sqlite3_result_null(context)
                    case .Int64(let int64):
                        sqlite3_result_int64(context, int64)
                    case .Double(let double):
                        sqlite3_result_double(context, double)
                    case .String(let string):
                        sqlite3_result_text(context, string, -1, SQLITE_TRANSIENT)
                    case .Blob(let data):
                        sqlite3_result_blob(context, data.bytes, Int32(data.length), SQLITE_TRANSIENT)
                    }
                } catch let error as DatabaseError {
                    if let message = error.message {
                        sqlite3_result_error(context, message, -1)
                    }
                    sqlite3_result_error_code(context, Int32(error.code))
                } catch {
                    sqlite3_result_error(context, "\(error)", -1)
                }
            }, nil, nil, nil)
        
        guard code == SQLITE_OK else {
            fatalError(DatabaseError(code: code, message: lastErrorMessage, sql: nil, arguments: nil).description)
        }
    }
    
    /// Remove an SQL function.
    public func removeFunction(function: DatabaseFunction) {
        functions.remove(function)
        let code = sqlite3_create_function_v2(
            sqliteConnection,
            function.name,
            function.argumentCount,
            SQLITE_UTF8 | function.eTextRep,
            nil, nil, nil, nil, nil)
        guard code == SQLITE_OK else {
            fatalError(DatabaseError(code: code, message: lastErrorMessage, sql: nil, arguments: nil).description)
        }
    }
}


/// An SQL function.
public class DatabaseFunction : Hashable {
    let name: String
    let argumentCount: Int32
    let pure: Bool
    let function: (COpaquePointer, Int32, UnsafeMutablePointer<COpaquePointer>) throws -> DatabaseValue
    var eTextRep: Int32 { return pure ? SQLITE_DETERMINISTIC : 0 }
    
    /// The hash value.
    public var hashValue: Int {
        return name.hashValue ^ argumentCount.hashValue
    }
    
    /// Returns an SQL function.
    ///
    ///     let fn = DatabaseFunction("succ", argumentCount: 1) { databaseValues in
    ///         let dbv = databaseValues.first!
    ///         guard let int = dbv.value() as Int? else {
    ///             return nil
    ///         }
    ///         return int + 1
    ///     }
    ///     db.addFunction(fn)
    ///     Int.fetchOne(db, "SELECT succ(1)")! // 2
    ///
    /// - parameter name: The function name.
    /// - parameter argumentCount: The number of arguments of the function. If
    ///   omitted, or nil, the function accepts any number of arguments.
    /// - parameter pure: Whether the function is "pure", which means that its
    ///   results only depends on its inputs. When a function is pure, SQLite
    ///   has the opportunity to perform additional optimizations. Default value
    ///   is false.
    /// - parameter function: A function that takes an array of DatabaseValue
    ///   arguments, and returns an optional DatabaseValueConvertible such as
    ///   Int, String, NSDate, etc. The array is guaranteed to have exactly
    ///   *argumentCount* elements, provided *argumentCount* is not nil.
    public init(_ name: String, argumentCount: Int32? = nil, pure: Bool = false, function: [DatabaseValue] throws -> DatabaseValueConvertible?) {
        self.name = name
        self.argumentCount = argumentCount ?? -1
        self.pure = pure
        self.function = { (context, argc, argv) in
            let arguments = (0..<Int(argc)).map { index in DatabaseValue(sqliteValue: argv[index]) }
            return try function(arguments)?.databaseValue ?? .Null
        }
    }
}

/// Two functions are equal if they share the same name and argumentCount.
public func ==(lhs: DatabaseFunction, rhs: DatabaseFunction) -> Bool {
    return lhs.name == rhs.name && lhs.argumentCount == rhs.argumentCount
}


// =========================================================================
// MARK: - Collations

extension Database {
    
    /// Add or redefine a collation.
    ///
    ///     let collation = DatabaseCollation("localized_standard") { (string1, string2) in
    ///         return (string1 as NSString).localizedStandardCompare(string2)
    ///     }
    ///     db.addCollation(collation)
    ///     try db.execute("CREATE TABLE files (name TEXT COLLATE LOCALIZED_STANDARD")
    public func addCollation(collation: DatabaseCollation) {
        collations.remove(collation)
        collations.insert(collation)
        let collationPointer = unsafeBitCast(collation, UnsafeMutablePointer<Void>.self)
        let code = sqlite3_create_collation_v2(
            sqliteConnection,
            collation.name,
            SQLITE_UTF8,
            collationPointer,
            { (collationPointer, length1, buffer1, length2, buffer2) -> Int32 in
                let collation = unsafeBitCast(collationPointer, DatabaseCollation.self)
                // Buffers are not C strings: they do not end with \0.
                let string1 = String(bytesNoCopy: UnsafeMutablePointer<Void>(buffer1), length: Int(length1), encoding: NSUTF8StringEncoding, freeWhenDone: false)!
                let string2 = String(bytesNoCopy: UnsafeMutablePointer<Void>(buffer2), length: Int(length2), encoding: NSUTF8StringEncoding, freeWhenDone: false)!
                return Int32(collation.function(string1, string2).rawValue)
            }, nil)
        guard code == SQLITE_OK else {
            fatalError(DatabaseError(code: code, message: lastErrorMessage, sql: nil, arguments: nil).description)
        }
    }
    
    /// Remove a collation.
    public func removeCollation(collation: DatabaseCollation) {
        collations.remove(collation)
        sqlite3_create_collation_v2(
            sqliteConnection,
            collation.name,
            SQLITE_UTF8,
            nil, nil, nil)
    }
}

/// A Collation.
public class DatabaseCollation : Hashable {
    let name: String
    let function: (String, String) -> NSComparisonResult
    
    /// The hash value.
    public var hashValue: Int {
        // We can't compute a hash since the equality is based on the opaque
        // sqlite3_strnicmp SQLite function.
        return 0
    }
    
    /// Returns a collation.
    ///
    ///     let collation = DatabaseCollation("localized_standard") { (string1, string2) in
    ///         return (string1 as NSString).localizedStandardCompare(string2)
    ///     }
    ///     db.addCollation(collation)
    ///     try db.execute("CREATE TABLE files (name TEXT COLLATE LOCALIZED_STANDARD")
    ///
    /// - parameter name: The function name.
    /// - parameter function: A function that compares two strings.
    public init(_ name: String, function: (String, String) -> NSComparisonResult) {
        self.name = name
        self.function = function
    }
}

/// Two collations are equal if they share the same name (case insensitive)
public func ==(lhs: DatabaseCollation, rhs: DatabaseCollation) -> Bool {
    // See https://www.sqlite.org/c3ref/create_collation.html
    return sqlite3_stricmp(lhs.name, lhs.name) == 0
}


// =========================================================================
// MARK: - Database Schema

extension Database {
    
    /// Clears the database schema cache.
    ///
    /// You may need to clear the cache if you modify the database schema
    /// outside of a database migration performed by DatabaseMigrator.
    public func clearSchemaCache() {
        preconditionValidQueue()
        primaryKeyCache = [:]
        updateStatementCache = [:]
        selectStatementCache = [:]
    }
    
    /// Returns whether a table exists.
    public func tableExists(tableName: String) -> Bool {
        // SQlite identifiers are case-insensitive, case-preserving (http://www.alberton.info/dbms_identifiers_and_case_sensitivity.html)
        return Row.fetchOne(self,
            "SELECT sql FROM sqlite_master WHERE type = 'table' AND LOWER(name) = ?",
            arguments: [tableName.lowercaseString]) != nil
    }
    
    /// Return the primary key for table named `tableName`.
    /// Throws if table does not exist.
    ///
    /// This method is not thread-safe.
    func primaryKey(tableName: String) throws -> PrimaryKey {
        if let primaryKey = primaryKeyCache[tableName] {
            return primaryKey
        }
        
        // https://www.sqlite.org/pragma.html
        //
        // > PRAGMA database.table_info(table-name);
        // >
        // > This pragma returns one row for each column in the named table.
        // > Columns in the result set include the column name, data type,
        // > whether or not the column can be NULL, and the default value for
        // > the column. The "pk" column in the result set is zero for columns
        // > that are not part of the primary key, and is the index of the
        // > column in the primary key for columns that are part of the primary
        // > key.
        //
        // CREATE TABLE persons (
        //   id INTEGER PRIMARY KEY,
        //   firstName TEXT,
        //   lastName TEXT)
        //
        // PRAGMA table_info("persons")
        //
        // cid | name      | type    | notnull | dflt_value | pk |
        // 0   | id        | INTEGER | 0       | NULL       | 1  |
        // 1   | firstName | TEXT    | 0       | NULL       | 0  |
        // 2   | lastName  | TEXT    | 0       | NULL       | 0  |
        
        let columnInfos = ColumnInfo.fetchAll(self, "PRAGMA table_info(\(tableName.quotedDatabaseIdentifier))")
        guard columnInfos.count > 0 else {
            throw DatabaseError(message: "no such table: \(tableName)")
        }
        
        let primaryKey: PrimaryKey
        let pkColumnInfos = columnInfos
            .filter { $0.primaryKeyIndex > 0 }
            .sort { $0.primaryKeyIndex < $1.primaryKeyIndex }
        
        switch pkColumnInfos.count {
        case 0:
            // No primary key column
            primaryKey = PrimaryKey.None
        case 1:
            // Single column
            let pkColumnInfo = pkColumnInfos.first!
            
            // https://www.sqlite.org/lang_createtable.html:
            //
            // > With one exception noted below, if a rowid table has a primary
            // > key that consists of a single column and the declared type of
            // > that column is "INTEGER" in any mixture of upper and lower
            // > case, then the column becomes an alias for the rowid. Such a
            // > column is usually referred to as an "integer primary key".
            // > A PRIMARY KEY column only becomes an integer primary key if the
            // > declared type name is exactly "INTEGER". Other integer type
            // > names like "INT" or "BIGINT" or "SHORT INTEGER" or "UNSIGNED
            // > INTEGER" causes the primary key column to behave as an ordinary
            // > table column with integer affinity and a unique index, not as
            // > an alias for the rowid.
            // >
            // > The exception mentioned above is that if the declaration of a
            // > column with declared type "INTEGER" includes an "PRIMARY KEY
            // > DESC" clause, it does not become an alias for the rowid [...]
            //
            // We ignore the exception, and consider all INTEGER primary keys as
            // aliases for the rowid:
            if pkColumnInfo.type.uppercaseString == "INTEGER" {
                primaryKey = .RowID(pkColumnInfo.name)
            } else {
                primaryKey = .Regular([pkColumnInfo.name])
            }
        default:
            // Multi-columns primary key
            primaryKey = .Regular(pkColumnInfos.map { $0.name })
        }
        
        primaryKeyCache[tableName] = primaryKey
        return primaryKey
    }
    
    // CREATE TABLE persons (
    //   id INTEGER PRIMARY KEY,
    //   firstName TEXT,
    //   lastName TEXT)
    //
    // PRAGMA table_info("persons")
    //
    // cid | name      | type    | notnull | dflt_value | pk |
    // 0   | id        | INTEGER | 0       | NULL       | 1  |
    // 1   | firstName | TEXT    | 0       | NULL       | 0  |
    // 2   | lastName  | TEXT    | 0       | NULL       | 0  |
    private struct ColumnInfo : RowConvertible {
        let name: String
        let type: String
        let notNull: Bool
        let defaultDatabaseValue: DatabaseValue
        let primaryKeyIndex: Int
        
        static func fromRow(row: Row) -> ColumnInfo {
            return ColumnInfo(
                name:row.value(named: "name"),
                type:row.value(named: "type"),
                notNull:row.value(named: "notnull"),
                defaultDatabaseValue:row["dflt_value"]!,
                primaryKeyIndex:row.value(named: "pk"))
        }
    }
}

/// A primary key
enum PrimaryKey {
    
    /// No primary key
    case None
    
    /// An INTEGER PRIMARY KEY column that aliases the Row ID.
    /// Associated string is the column name.
    case RowID(String)
    
    /// Any primary key, but INTEGER PRIMARY KEY.
    /// Associated strings are column names.
    case Regular([String])
    
    /// The columns in the primary key. May be empty.
    var columns: [String] {
        switch self {
        case .None:
            return []
        case .RowID(let column):
            return [column]
        case .Regular(let columns):
            return columns
        }
    }
    
    /// The name of the INTEGER PRIMARY KEY
    var rowIDColumn: String? {
        switch self {
        case .None:
            return nil
        case .RowID(let column):
            return column
        case .Regular:
            return nil
        }
    }
}


// =========================================================================
// MARK: - Transactions

extension Database {
    /// Executes a block inside a database transaction.
    ///
    ///     try dbQueue.inDatabase do {
    ///         try db.inTransaction {
    ///             try db.execute("INSERT ...")
    ///             return .Commit
    ///         }
    ///     }
    ///
    /// If the block throws an error, the transaction is rollbacked and the
    /// error is rethrown.
    ///
    /// This method is not reentrant: you can't nest transactions.
    ///
    /// - parameter kind: The transaction type (default nil). If nil, the
    ///   transaction type is configuration.defaultTransactionKind, which itself
    ///   defaults to .Immediate. See https://www.sqlite.org/lang_transaction.html
    ///   for more information.
    /// - parameter block: A block that executes SQL statements and return
    ///   either .Commit or .Rollback.
    /// - throws: The error thrown by the block.
    public func inTransaction(kind: TransactionKind? = nil, block: () throws -> TransactionCompletion) throws {
        preconditionValidQueue()
        
        var completion: TransactionCompletion = .Rollback
        var blockError: ErrorType? = nil
        
        try beginTransaction(kind)
        
        do {
            completion = try block()
        } catch {
            completion = .Rollback
            blockError = error
        }
        
        switch completion {
        case .Commit:
            try commit()
        case .Rollback:
            // https://www.sqlite.org/lang_transaction.html#immediate
            //
            // > Response To Errors Within A Transaction
            // >
            // > If certain kinds of errors occur within a transaction, the
            // > transaction may or may not be rolled back automatically. The
            // > errors that can cause an automatic rollback include:
            // >
            // > - SQLITE_FULL: database or disk full
            // > - SQLITE_IOERR: disk I/O error
            // > - SQLITE_BUSY: database in use by another process
            // > - SQLITE_NOMEM: out or memory
            // >
            // > [...] It is recommended that applications respond to the errors
            // > listed above by explicitly issuing a ROLLBACK command. If the
            // > transaction has already been rolled back automatically by the
            // > error response, then the ROLLBACK command will fail with an
            // > error, but no harm is caused by this.
            if let blockError = blockError as? DatabaseError {
                switch Int32(blockError.code) {
                case SQLITE_FULL, SQLITE_IOERR, SQLITE_BUSY, SQLITE_NOMEM:
                    do { try rollback() } catch { }
                default:
                    try rollback()
                }
            } else {
                try rollback()
            }
        }
        
        if let blockError = blockError {
            throw blockError
        }
    }
    
    private func beginTransaction(kind: TransactionKind? = nil) throws {
        switch kind ?? configuration.defaultTransactionKind {
        case .Deferred:
            try execute("BEGIN DEFERRED TRANSACTION")
        case .Immediate:
            try execute("BEGIN IMMEDIATE TRANSACTION")
        case .Exclusive:
            try execute("BEGIN EXCLUSIVE TRANSACTION")
        }
    }
    
    private func rollback() throws {
        try execute("ROLLBACK TRANSACTION")
    }
    
    private func commit() throws {
        try execute("COMMIT TRANSACTION")
    }
    
    public func addTransactionObserver(transactionObserver: TransactionObserverType) {
        preconditionValidQueue()
        transactionObservers.append(transactionObserver)
        if transactionObservers.count == 1 {
            installTransactionObserverHooks()
        }
    }
    
    public func removeTransactionObserver(transactionObserver: TransactionObserverType) {
        preconditionValidQueue()
        transactionObservers.removeFirst { $0 === transactionObserver }
        if transactionObservers.isEmpty {
            uninstallTransactionObserverHooks()
        }
    }
    
    func updateStatementDidFail() throws {
        // Reset transactionState before didRollback eventually executes
        // other statements.
        let transactionState = self.transactionState
        self.transactionState = .WaitForTransactionCompletion
        
        switch transactionState {
        case .RollbackFromTransactionObserver(let error):
            didRollback()
            throw error
        default:
            break
        }
    }
    
    func updateStatementDidExecute() {
        // Reset transactionState before didCommit or didRollback eventually
        // execute other statements.
        let transactionState = self.transactionState
        self.transactionState = .WaitForTransactionCompletion
        
        switch transactionState {
        case .Commit:
            didCommit()
        case .Rollback:
            didRollback()
        default:
            break
        }
    }
    
    private func willCommit() throws {
        for observer in transactionObservers {
            try observer.databaseWillCommit()
        }
    }
    
    private func didChangeWithEvent(event: DatabaseEvent) {
        for observer in transactionObservers {
            observer.databaseDidChangeWithEvent(event)
        }
    }
    
    private func didCommit() {
        for observer in transactionObservers {
            observer.databaseDidCommit(self)
        }
    }
    
    private func didRollback() {
        for observer in transactionObservers {
            observer.databaseDidRollback(self)
        }
    }
    
    private func installTransactionObserverHooks() {
        let dbPointer = unsafeBitCast(self, UnsafeMutablePointer<Void>.self)
        
        sqlite3_update_hook(sqliteConnection, { (dbPointer, updateKind, databaseName, tableName, rowID) in
            let db = unsafeBitCast(dbPointer, Database.self)
            db.didChangeWithEvent(DatabaseEvent(
                kind: DatabaseEvent.Kind(rawValue: updateKind)!,
                databaseName: String.fromCString(databaseName)!,
                tableName: String.fromCString(tableName)!,
                rowID: rowID))
            }, dbPointer)
        
        
        sqlite3_commit_hook(sqliteConnection, { dbPointer in
            let db = unsafeBitCast(dbPointer, Database.self)
            do {
                try db.willCommit()
                db.transactionState = .Commit
                // Next step: updateStatementDidExecute()
                return 0
            } catch {
                db.transactionState = .RollbackFromTransactionObserver(error)
                // Next step: sqlite3_rollback_hook callback
                return 1
            }
            }, dbPointer)
        
        
        sqlite3_rollback_hook(sqliteConnection, { dbPointer in
            let db = unsafeBitCast(dbPointer, Database.self)
            switch db.transactionState {
            case .RollbackFromTransactionObserver:
                // Next step: updateStatementDidFail()
                break
            default:
                db.transactionState = .Rollback
                // Next step: updateStatementDidExecute()
            }
            }, dbPointer)
    }
    
    private func uninstallTransactionObserverHooks() {
        sqlite3_update_hook(sqliteConnection, nil, nil)
        sqlite3_commit_hook(sqliteConnection, nil, nil)
        sqlite3_rollback_hook(sqliteConnection, nil, nil)
    }
}


/// A SQLite transaction kind. See https://www.sqlite.org/lang_transaction.html
public enum TransactionKind {
    case Deferred
    case Immediate
    case Exclusive
}


/// The end of a transaction: Commit, or Rollback
public enum TransactionCompletion {
    case Commit
    case Rollback
}

/// The states that keep track of transaction completions in order to notify
/// transaction observers.
private enum TransactionState {
    case WaitForTransactionCompletion
    case Commit
    case Rollback
    case RollbackFromTransactionObserver(ErrorType)
}

/// A transaction observer is notified of all changes and transactions committed
/// or rollbacked on a database.
///
/// Adopting types must be a class.
public protocol TransactionObserverType : class {
    
    /// Notifies a database change (insert, update, or delete).
    ///
    /// The change is pending until the end of the current transaction, notified
    /// to databaseWillCommit, databaseDidCommit and databaseDidRollback.
    ///
    /// This method is called on the database queue.
    ///
    /// **WARNING**: this method must not change the database.
    func databaseDidChangeWithEvent(event: DatabaseEvent)
    
    /// When a transaction is about to be committed, the transaction observer
    /// has an opportunity to rollback pending changes by throwing an error.
    ///
    /// This method is called on the database queue.
    ///
    /// **WARNING**: this method must not change the database.
    ///
    /// - throws: An eventual error that rollbacks pending changes.
    func databaseWillCommit() throws
    
    /// Database changes have been committed.
    ///
    /// This method is called on the database queue. It can change the database.
    func databaseDidCommit(db: Database)
    
    /// Database changes have been rollbacked.
    ///
    /// This method is called on the database queue. It can change the database.
    func databaseDidRollback(db: Database)
}


/// A database event, notified to TransactionObserverType.
///
/// See https://www.sqlite.org/c3ref/update_hook.html for more information.
public struct DatabaseEvent {
    /// An event kind
    public enum Kind: Int32 {
        case Insert = 18    // SQLITE_INSERT
        case Delete = 9     // SQLITE_DELETE
        case Update = 23    // SQLITE_UPDATE
    }
    
    /// The event kind
    public let kind: Kind
    
    /// The database name
    public let databaseName: String
    
    /// The table name
    public let tableName: String
    
    /// The rowID of the changed row.
    public let rowID: Int64
}
