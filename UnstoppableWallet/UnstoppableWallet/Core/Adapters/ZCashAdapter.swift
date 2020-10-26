import Foundation

import ZcashLightClientKit
import RxSwift
import HdWalletKit
import HsToolKit

class ZСashAdapter {
    private let coinRate: Decimal = pow(10, 8)
    let fee: Decimal = 0.0001

    private let synchronizer: SDKSynchronizer
    private let transactionPool: ZCashTransactionPool

    private let keys: [String]
    private let loggingProxy = ZCashLogger(logLevel: .verbose)

    private let lastBlockUpdatedSubject = PublishSubject<Void>()
    private let stateUpdatedSubject = PublishSubject<Void>()
    private let balanceUpdatedSubject = PublishSubject<Void>()
    private let transactionRecordsSubject = PublishSubject<[TransactionRecord]>()

    private var lastBlockHeight: Int? = 0

    private(set) var state: AdapterState

    init(wallet: Wallet, syncMode: SyncMode?, derivation: MnemonicDerivation?, testMode: Bool) throws {
        guard case let .mnemonic(words, _) = wallet.account.type else {
            throw AdapterError.unsupportedAccount
        }

        let endPoint = testMode ? "lightwalletd.testnet.electriccoin.co" : "lightwalletd.electriccoin.co"
        let birthday = testMode ? 620_000 : 995_000
//        let birthday = testMode ? 620_000 : 663_174

        let initializer = Initializer(cacheDbURL:try! ZСashAdapter.__cacheDbURL(),
                                      dataDbURL: try! ZСashAdapter.__dataDbURL(),
                                      pendingDbURL: try! ZСashAdapter.__pendingDbURL(),
                endpoint: LightWalletEndpoint(address: endPoint, port: 9067),
                spendParamsURL: try! ZСashAdapter.__spendParamsURL(),
                outputParamsURL: try! ZСashAdapter.__outputParamsURL(),
                loggerProxy: loggingProxy)


        let seedData = [UInt8](Mnemonic.seed(mnemonic: words))
        try initializer.initialize(viewingKeys: try DerivationTool.default.deriveViewingKeys(seed: seedData, numberOfAccounts: 1),
                walletBirthday: BlockHeight(birthday))

        keys = try DerivationTool.default.deriveSpendingKeys(seed: seedData, numberOfAccounts: 1)
        synchronizer = try SDKSynchronizer(initializer: initializer)

        transactionPool = ZCashTransactionPool()
        transactionPool.store(confirmedTransactions: synchronizer.clearedTransactions, pendingTransactions: synchronizer.pendingTransactions)

        state = .syncing(progress: 0, lastBlockDate: nil)
        lastBlockHeight = try? synchronizer.latestHeight()

        subscribeSynchronizerNotifications()
    }

    private func subscribeSynchronizerNotifications() {
        let center = NotificationCenter.default

        // state changing
        center.addObserver(self, selector: #selector(statusUpdated(_:)), name: Notification.Name.synchronizerDisconnected, object: synchronizer)
        center.addObserver(self, selector: #selector(statusUpdated(_:)), name: Notification.Name.synchronizerStarted, object: synchronizer)
        center.addObserver(self, selector: #selector(statusUpdated(_:)), name: Notification.Name.synchronizerSynced, object: synchronizer)
        center.addObserver(self, selector: #selector(statusUpdated(_:)), name: Notification.Name.synchronizerDisconnected, object: synchronizer)
        center.addObserver(self, selector: #selector(statusUpdated(_:)), name: Notification.Name.synchronizerFailed, object: synchronizer)

        // sync progress changing
        center.addObserver(self, selector: #selector(statusUpdated(_:)), name: Notification.Name.synchronizerProgressUpdated, object: synchronizer)
        center.addObserver(self, selector: #selector(statusUpdated(_:)), name: Notification.Name.transactionsUpdated, object: synchronizer)

        //found new transactions
        center.addObserver(self, selector: #selector(transactionsUpdated(_:)), name: Notification.Name.synchronizerFoundTransactions, object: synchronizer)

        //latestHeight
        center.addObserver(self, selector: #selector(blockHeightUpdated(_:)), name: Notification.Name.blockProcessorUpdated, object: synchronizer.blockProcessor)
    }

    @objc private func statusUpdated(_ notification: Notification) {
        var newState = state
        print("===== STATUS: \(synchronizer.status) =====")

        switch synchronizer.status {
        case .disconnected: newState = .notSynced(error: AppError.noConnection)
        case .stopped: newState = .notSynced(error: AppError.unknownError)
        case .synced: newState = .synced
        case .syncing: newState = .syncing(progress: Int(synchronizer.progress * 100), lastBlockDate: nil)
        }

        if newState != state {
            print("===== ZCASH =====")
            print("-> newState: \(newState)")
            state = newState
            stateUpdatedSubject.onNext(())
        }
    }

    @objc private func transactionsUpdated(_ notification: Notification) {
        print("Transactions Updated with Mined+!")
        if let userInfo = notification.userInfo, let txs2 = userInfo[SDKSynchronizer.NotificationKeys.foundTransactions] {
            if let txs = txs2 as? [ConfirmedTransactionEntity] {

                print("=======================================")
                print("-> Updated TRANSACTION_FOUND txs count: \(txs.count)")
                txs.forEach { description($0) }

                print("=======================================")
                let newTxs = transactionPool.sync(transactions: txs)

                print("after pool sync:")
                newTxs.forEach { print($0.description) }
                print("result transactions count: \(newTxs.count)")

                transactionRecordsSubject.onNext(newTxs.map {
                    transactionRecord(fromTransaction: $0)
                })
            }
        }
    }

    @objc private func blockHeightUpdated(_ notification: Notification) {
        if let userInfo = notification.userInfo, let blockHeight = userInfo[CompactBlockProcessorNotificationKey.progressHeight] as? BlockHeight {
            lastBlockHeight = blockHeight
            lastBlockUpdatedSubject.onNext(())

            print("===== ZCASH =====")
            print("-> BLOCK HEIGHT UPDATED: \(blockHeight)")
        }

        balanceUpdatedSubject.onNext(())
    }

    private func syncPending() {
        let newTxs = transactionPool.sync(transactions: synchronizer.pendingTransactions)

        if !newTxs.isEmpty {
            transactionRecordsSubject.onNext(newTxs.map {
                transactionRecord(fromTransaction: $0)
            })
        }
    }

    private static func __documentsDirectory() throws -> URL {
        try FileManager.default.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
    }

    private static func __cacheDbURL() throws -> URL {
        try __documentsDirectory().appendingPathComponent(ZcashSDK.DEFAULT_DB_NAME_PREFIX+ZcashSDK.DEFAULT_CACHES_DB_NAME, isDirectory: false)
    }

    private static func __dataDbURL() throws -> URL {
        try __documentsDirectory().appendingPathComponent(ZcashSDK.DEFAULT_DB_NAME_PREFIX+ZcashSDK.DEFAULT_DATA_DB_NAME, isDirectory: false)
    }

    private static func __pendingDbURL() throws -> URL {
        try __documentsDirectory().appendingPathComponent(ZcashSDK.DEFAULT_DB_NAME_PREFIX+ZcashSDK.DEFAULT_PENDING_DB_NAME)
    }

    private static func __spendParamsURL() throws -> URL {
        try __documentsDirectory().appendingPathComponent("sapling-spend.params")
    }

    private static func __outputParamsURL() throws -> URL {
        try __documentsDirectory().appendingPathComponent("sapling-output.params")
    }

    func transactionRecord(fromTransaction transaction: ZCashTransaction) -> TransactionRecord {
        var incoming = true
        if let toAddress = transaction.toAddress, toAddress != receiveAddress {
            incoming = false
        }

        return TransactionRecord(
                uid: transaction.transactionHash,
                transactionHash: transaction.transactionHash,
                transactionIndex: transaction.transactionIndex,
                interTransactionIndex: 0,
                type: incoming ? .incoming : .outgoing,
                blockHeight: transaction.minedHeight,
                confirmationsThreshold: 10,
                amount: Decimal(transaction.value) / coinRate,
                fee: fee,
                date: Date(timeIntervalSince1970: transaction.timestamp),
                failed: transaction.failed,
                from: nil,
                to: transaction.toAddress,
                lockInfo: nil,
                conflictingHash: nil,
                showRawTransaction: false
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        self.synchronizer.blockProcessor?.stop()
        self.synchronizer.stop()
    }

}

extension ZСashAdapter: IAdapter {

    func start() {
        sync()
    }

    func stop() {
        synchronizer.stop()
    }

    func refresh() {
        sync()
    }

    private func sync() {
        do {
            try synchronizer.start()
        } catch {
            state = .notSynced(error: error)
            stateUpdatedSubject.onNext(())
        }
    }

    var debugInfo: String {
        """
        ZcashAdapter address: \(synchronizer.getAddress(accountIndex: 0))
        spendingKeys: \(keys.description)
        balance: \(synchronizer.initializer.getBalance())
        verified balance: \(synchronizer.initializer.getVerifiedBalance())
        """
    }

}

extension ZСashAdapter: ITransactionsAdapter {

    var lastBlockInfo: LastBlockInfo? {
        lastBlockHeight.map { LastBlockInfo(height: $0, timestamp: nil) }
    }

    var lastBlockUpdatedObservable: Observable<Void> {
        lastBlockUpdatedSubject.asObservable()
    }

    var transactionRecordsObservable: Observable<[TransactionRecord]> {
        transactionRecordsSubject.asObservable()
    }

    func transactionsSingle(from: TransactionRecord?, limit: Int) -> Single<[TransactionRecord]> {
        transactionPool.transactionsSingle(from: from, limit: limit).map { [weak self] txs in
            let txs = txs.compactMap { self?.transactionRecord(fromTransaction: $0) }
            print(txs)
            return txs
        }
    }

    func rawTransaction(hash: String) -> String? {
        "hz-znaet"
    }

}

extension ZСashAdapter: IBalanceAdapter {

    var stateUpdatedObservable: Observable<Void> {
        stateUpdatedSubject.asObservable()
    }

    var balanceUpdatedObservable: Observable<Void> {
        balanceUpdatedSubject.asObservable()
    }

    var balance: Decimal {
        print("STATE = \(synchronizer.status)")
        print("balance = \(synchronizer.initializer.getBalance())")
        return Decimal(synchronizer.initializer.getBalance()) / coinRate
    }

    var balanceLocked: Decimal? {
        let verifiedBalance = Decimal(synchronizer.initializer.getVerifiedBalance())
        let balance = Decimal(synchronizer.initializer.getBalance())
        let diff = balance - verifiedBalance

        return !diff.isZero ? (diff / coinRate) : nil
    }

}

extension ZСashAdapter: IDepositAdapter {

    var receiveAddress: String {
        // using only first account
        synchronizer.getAddress(accountIndex: 0)
    }

}

extension ZСashAdapter: ISendZCashAdapter {

    var availableBalance: Decimal {
        max(0, Decimal(synchronizer.initializer.getVerifiedBalance()) / coinRate - fee)
    }

    func validate(address: String) throws {
        guard synchronizer.initializer.isValidShieldedAddress(address) || synchronizer.initializer.isValidTransparentAddress(address) else {
            throw AdapterError.wrongParameters
        }
    }

    func sendSingle(amount: Decimal, address: String, memo: String?) -> Single<()> {
        guard let spendingKey = keys.first else {
            return Single.error(AdapterError.unsupportedAccount)
        }

        let amount = NSDecimalNumber(decimal: amount * coinRate).int64Value
        let synchronizer = self.synchronizer

        return Single<()>.create { [weak self] single in
            synchronizer.sendToAddress(spendingKey: spendingKey, zatoshi: amount, toAddress: address, memo: memo, from: 0) { result in
                self?.syncPending()
                switch result {
                case .success:
                    single(.success(()))
                case .failure(let error):
                    single(.error(error))
                }
            }

            return Disposables.create()
        }
    }

}

extension ZСashAdapter {

    static func clear(except excludedWalletIds: [String]) throws {
//        try BitcoinKit.clear(exceptFor: excludedWalletIds)
    }

}

private class ZCashLogger: ZcashLightClientKit.Logger {

    private let level: HsToolKit.Logger.Level
    private let logger: HsToolKit.Logger

    init(logLevel: HsToolKit.Logger.Level) {
        self.level = logLevel

        logger = Logger(minLogLevel: logLevel)
    }

    func debug(_ message: String, file: String = #file, function: String = #function, line: Int = #line) {
        log(level: .debug, message: message, file: file, function: function, line: line)
    }

    func error(_ message: String, file: String = #file, function: String = #function, line: Int = #line) {
        log(level: .error, message: message, file: file, function: function, line: line)
    }

    func warn(_ message: String, file: String = #file, function: String = #function, line: Int = #line) {
        log(level: .warning, message: message, file: file, function: function, line: line)
    }

    func event(_ message: String, file: String = #file, function: String = #function, line: Int = #line) {
        log(level: .verbose, message: message, file: file, function: function, line: line)
    }

    func info(_ message: String, file: String = #file, function: String = #function, line: Int = #line) {
        log(level: .info, message: message, file: file, function: function, line: line)
    }

    private func log(level: HsToolKit.Logger.Level, message: String, file: String, function: String, line: Int) {
        logger.log(level: level, message: message, file: file, function: function, line: line)
    }

}

func description(_ tx: ConfirmedTransactionEntity) {
    print("TX(Confirmed) === hash:\(tx.rawTransactionId?.reversedHex ?? "N/A") : \(tx.toAddress?.prefix(6) ?? "NoAddr") : \(tx.transactionIndex) height: \(tx.minedHeight) timestamp \(tx.blockTimeInMilliseconds.description) ")
}

func description(_ tx: PendingTransactionEntity) {
    print("TX(Confirmed) === hash:\(tx.rawTransactionId?.reversedHex ?? "N/A") : \(tx.toAddress.prefix(6)) : N/A height: N/A timestamp \(tx.createTime.description) ")
}

