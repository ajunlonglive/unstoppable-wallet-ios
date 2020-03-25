import UIKit
import SnapKit
import ActionSheet
import DeepDiff
import ThemeKit
import HUD

class TransactionsViewController: ThemeViewController {
    let delegate: ITransactionsViewDelegate

    let queue = DispatchQueue.global(qos: .userInteractive)
    let differ: IDiffer

    let tableView = UITableView(frame: .zero, style: .plain)
    private var headerBackgroundTriggerOffset: CGFloat?

    private let cellName = String(describing: TransactionCell.self)

    private let emptyLabel = UILabel()
    private let filterHeaderView = TransactionCurrenciesHeaderView()

    private var items: [TransactionViewItem]?

    private let syncSpinner = HUDProgressView(strokeLineWidth: 2, radius: 9, strokeColor: .themeGray, duration: 2)

    init(delegate: ITransactionsViewDelegate, differ: IDiffer) {
        self.delegate = delegate
        self.differ = differ

        super.init()

        tabBarItem = UITabBarItem(title: "transactions.tab_bar_item".localized, image: UIImage(named: "transactions.tab_bar_item"), tag: 0)
    }

    required init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        title = "transactions.title".localized

        filterHeaderView.onSelectWallet = { [weak self] wallet in
            self?.delegate.onFilterSelect(wallet: wallet)
        }

        view.addSubview(tableView)
        tableView.backgroundColor = .clear
        tableView.snp.makeConstraints { maker in
            maker.edges.equalToSuperview()
        }
        tableView.dataSource = self
        tableView.delegate = self
        tableView.separatorStyle = .none
        tableView.backgroundColor = .clear
        tableView.tableFooterView = UIView(frame: .zero)

        tableView.registerCell(forClass: TransactionCell.self)
        tableView.estimatedRowHeight = 0
        tableView.delaysContentTouches = false

        view.addSubview(emptyLabel)
        emptyLabel.snp.makeConstraints { maker in
            maker.centerY.equalToSuperview()
            maker.leading.equalToSuperview().offset(50)
            maker.trailing.equalToSuperview().offset(-50)
        }

        emptyLabel.text = "transactions.empty_text".localized
        emptyLabel.numberOfLines = 0
        emptyLabel.font = .systemFont(ofSize: 14)
        emptyLabel.textColor = .themeGray
        emptyLabel.textAlignment = .center

        let holder = UIView(frame: CGRect(x: 0, y: 0, width: 20, height: 20))
        holder.addSubview(syncSpinner)

        navigationItem.rightBarButtonItem = UIBarButtonItem(customView: holder)

        delegate.viewDidLoad()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        headerBackgroundTriggerOffset = headerBackgroundTriggerOffset == nil ? tableView.contentOffset.y : headerBackgroundTriggerOffset
    }

    private func reload(indexPaths: [IndexPath]) {
        for indexPath in indexPaths {
            if let cell = tableView.cellForRow(at: indexPath) as? TransactionCell, let item = items?[indexPath.row] {
                delegate.willShow(item: item)
                cell.bind(item: item, first: indexPath.row == 0, last: tableView.numberOfRows(inSection: indexPath.section) == indexPath.row + 1)
            }
        }
    }

    private func reload(with diff: [Change<TransactionViewItem>], animated: Bool) {
        let changes = IndexPathConverter().convert(changes: diff, section: 0)

        guard !changes.inserts.isEmpty || !changes.moves.isEmpty || !changes.deletes.isEmpty else {
            reload(indexPaths: changes.replaces)
            return
        }

        tableView.performBatchUpdates({ [weak self] in
            self?.tableView.deleteRows(at: changes.deletes, with: animated ? .fade : .none)
            self?.tableView.insertRows(at: changes.inserts, with: animated ? .fade : .none)
            for movedIndex in changes.moves {
                self?.tableView.moveRow(at: movedIndex.from, to: movedIndex.to)
            }
        }, completion: { [weak self] _ in
            self?.reload(indexPaths: changes.replaces)
        })
    }

    private func show(status: TransactionViewStatus) {
        syncSpinner.isHidden = !status.showProgress
        if status.showProgress {
            syncSpinner.startAnimating()
        } else {
            syncSpinner.stopAnimating()
        }

        emptyLabel.isHidden = !status.showMessage
    }

}

extension TransactionsViewController: ITransactionsView {

    func set(status: TransactionViewStatus) {
        DispatchQueue.main.async { [weak self] in
            self?.show(status: status)
        }
    }

    func show(filters: [Wallet?]) {
        filterHeaderView.reload(filters: filters)
    }

    func show(transactions newViewItems: [TransactionViewItem], animated: Bool) {
        queue.sync { [weak self] in
            if (self?.items == nil) || !(isViewLoaded && view.window != nil) {
                self?.items = newViewItems

                DispatchQueue.main.async { [weak self] in
                    self?.tableView.reloadData()
                }

                return
            }

            let viewChanges = differ.changes(old: items ?? [], new: newViewItems)
            self?.items = newViewItems

            DispatchQueue.main.async { [weak self] in
                self?.reload(with: viewChanges, animated: animated)
            }
        }
    }

    func showNoTransactions() {
        show(transactions: [], animated: false)
    }

    func reloadTransactions() {
        DispatchQueue.main.async { [weak self] in
            self?.tableView.reloadData()
        }
    }

}

extension TransactionsViewController: UITableViewDelegate, UITableViewDataSource {

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        items?.count ?? 0
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        tableView.dequeueReusableCell(withIdentifier: cellName, for: indexPath)
    }

    func tableView(_ tableView: UITableView, willDisplay cell: UITableViewCell, forRowAt indexPath: IndexPath) {
        guard let items = items, items.count > indexPath.row else {
            return
        }
        if let cell = cell as? TransactionCell {
            delegate.willShow(item: items[indexPath.row])
            cell.bind(item: items[indexPath.row], first: indexPath.row == 0, last: tableView.numberOfRows(inSection: indexPath.section) == indexPath.row + 1)
        }

        if indexPath.row >= self.tableView(tableView, numberOfRowsInSection: 0) - 1 {
            delegate.onBottomReached()
        }
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        if let item = items?[indexPath.row] {
            delegate.onTransactionClick(item: item)
        }
    }

    func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat {
        72
    }

    func tableView(_ tableView: UITableView, heightForHeaderInSection section: Int) -> CGFloat {
        filterHeaderView.filters.isEmpty ? 0 : TransactionCurrenciesHeaderView.headerHeight
    }

    func tableView(_ tableView: UITableView, viewForHeaderInSection section: Int) -> UIView? {
        filterHeaderView
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        if let headerBackgroundTriggerOffset = headerBackgroundTriggerOffset {
            filterHeaderView.backgroundColor = scrollView.contentOffset.y > headerBackgroundTriggerOffset ? .themeNavigationBarBackground : .clear
        }
    }

}
