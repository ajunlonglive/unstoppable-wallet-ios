import RxSwift

class WalletManager {
    private let adapterFactory: IAdapterFactory

    private(set) var wallets: [Wallet] = []
    let walletsSubject = PublishSubject<[Wallet]>()

    init(adapterFactory: IAdapterFactory) {
        self.adapterFactory = adapterFactory
    }
}

extension WalletManager: IWalletManager {

    func initWallets(authData: AuthData, coins: [Coin]) {
        var newWallets = [Wallet]()

        wallets = coins.compactMap { coin in
            if let wallet = self.wallets.first(where: { $0.coin == coin }) {
                return wallet
            }

            guard let adapter = adapterFactory.adapter(forCoin: coin, authData: authData) else {
                return nil
            }

            let wallet = Wallet(coin: coin, adapter: adapter)
            newWallets.append(wallet)
            return wallet
        }

        walletsSubject.onNext(wallets)

        newWallets.forEach { $0.adapter.start() }
    }

    func clearWallets() {
        for wallet in wallets {
            wallet.adapter.clear()
        }
        wallets = []
    }

}
