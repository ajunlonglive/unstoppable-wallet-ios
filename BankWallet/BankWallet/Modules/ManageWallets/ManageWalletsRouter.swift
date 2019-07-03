import UIKit

class ManageWalletsRouter {
    weak var viewController: UIViewController?
    weak var createAccountDelegate: ICreateAccountDelegate?
}

extension ManageWalletsRouter: IManageWalletsRouter {

    func showCreateAccount(coin: Coin) {
        viewController?.present(CreateAccountRouter.module(coin: coin, delegate: createAccountDelegate), animated: true)
    }

    func close() {
        viewController?.dismiss(animated: true)
    }

}

extension ManageWalletsRouter {

    static func module() -> UIViewController {
        let router = ManageWalletsRouter()
        let interactor = ManageWalletsInteractor(appConfigProvider: App.shared.appConfigProvider, walletManager: App.shared.walletManager, accountManager: App.shared.accountManager)
        let presenter = ManageWalletsPresenter(interactor: interactor, router: router)
        let viewController = ManageWalletsViewController(delegate: presenter)

        interactor.delegate = presenter
        presenter.view = viewController

        router.viewController = viewController
        router.createAccountDelegate = interactor

        let navigationController = WalletNavigationController(rootViewController: viewController)
        navigationController.navigationBar.barStyle = AppTheme.navigationBarStyle
        navigationController.navigationBar.tintColor = AppTheme.navigationBarTintColor
        navigationController.navigationBar.prefersLargeTitles = true

        return navigationController
    }

}
