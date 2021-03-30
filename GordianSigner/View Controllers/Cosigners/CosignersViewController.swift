//
//  KeysetsViewController.swift
//  GordianSigner
//
//  Created by Peter on 11/15/20.
//  Copyright © 2020 Blockchain Commons. All rights reserved.
//

import UIKit
import LibWally

class KeysetsViewController: UIViewController, UITableViewDelegate, UITableViewDataSource, UINavigationControllerDelegate {
    
    let shardRecovery = ShardRecovery.shared
    var addButton = UIBarButtonItem()
    var editButton = UIBarButtonItem()
    private var cosigners = [CosignerStruct]()
    private var accounts = [AccountStruct]()
    private var cosignerToExport = ""
    private var headerText = ""
    private var subheaderText = ""
    private var cosigner:CosignerStruct!
    private var providedMnemonic = ""
    private var coinType = "0"
    let spinner = Spinner()

    @IBOutlet weak private var keysetsTable: UITableView!
    
    override func viewDidLoad() {
        super.viewDidLoad()
        
        // Do any additional setup after loading the view.
        keysetsTable.delegate = self
        keysetsTable.dataSource = self
        navigationController?.delegate = self
        
        if KeyChain.getData("hasUpdated") == nil {
            KeyChain.removeAll()
            CoreDataService.deleteAllData(entity: .account) { (_) in }
            CoreDataService.deleteAllData(entity: .cosigner) { (_) in }
            CoreDataService.deleteAllData(entity: .payment) { (_) in }
            UserDefaults.standard.setValue(true, forKey: "hasUpdated")
            let _ = KeyChain.set("true".utf8, forKey: "hasUpdated")
        }
        
        if !FirstTime.firstTimeHere() {
            showAlert(self, "Fatal error", "We were unable to set and save an encryption key to your secure enclave, the app will not function without this key.")
        }
        
        addButton = UIBarButtonItem.init(barButtonSystemItem: .add, target: self, action: #selector(add))
        editButton = UIBarButtonItem.init(barButtonSystemItem: .edit, target: self, action: #selector(editCosigners))
        self.navigationItem.setRightBarButtonItems([addButton, editButton], animated: true)
        NotificationCenter.default.addObserver(self, selector: #selector(refreshTable), name: .cosignerAdded, object: nil)
        
        if UserDefaults.standard.object(forKey: "coinType") == nil {
            UserDefaults.standard.setValue("0", forKey: "coinType")
        }
        
        load()
        
        if UserDefaults.standard.object(forKey: "hasUpdatedShouldSign") == nil {
            updateCosignersForShouldSign()
            UserDefaults.standard.setValue(true, forKey: "hasUpdatedShouldSign")
        }
    }
    
    override func viewDidAppear(_ animated: Bool) {
        coinType = UserDefaults.standard.object(forKey: "coinType") as? String ?? "0"
        
        if UserDefaults.standard.object(forKey: "acceptDisclaimer") == nil {
            DispatchQueue.main.async {
                self.performSegue(withIdentifier: "segueToDisclaimer", sender: self)
            }
        } else {
            self.load()
            
            if UserDefaults.standard.object(forKey: "seenCosignerInfo") == nil {
                showInfo()
                UserDefaults.standard.set(true, forKey: "seenCosignerInfo")
            }
        }
    }
    
    private func processShardUr(_ shardUr: String) {
        let (isValid, alreadyAdded, s) = shardRecovery.parseUr(shardUr)
        
        if isValid && !alreadyAdded {
            if let shardStruct = shardRecovery.parseShard(s) {                
                shardRecovery.shards.append(shardStruct)
                
                let (complete, entropy, totalRemaining) = shardRecovery.processShard(shardStruct)
                                
                if !complete {
                    self.promptToImportAnotherShard(totalRemaining)
                } else if entropy != nil {
                    self.shardRecovery.reset()
                    self.deriveMnemonicFromEntropy(entropy!)
                } else {
                    self.shardRecovery.reset()
                    showAlert(self, "Error!", "There was an error converting those shards to entropy.")
                }
            }
        }
    }
    
    private func promptToImportAnotherShard(_ totalSharesRemainingInGroup: Int) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            
            var alertStyle = UIAlertController.Style.actionSheet
            
            if (UIDevice.current.userInterfaceIdiom == .pad) {
              alertStyle = UIAlertController.Style.alert
            }
            
            var message = "You still need \(totalSharesRemainingInGroup) more shards from this group."
            
            if totalSharesRemainingInGroup == 0 {
                message = "You need to add more shards from another group."
            }
            
            let alert = UIAlertController(title: "Valid SSKR shard scanned ✓", message: message, preferredStyle: alertStyle)
            
            alert.addAction(UIAlertAction(title: "Scan another shard", style: .default, handler: { action in
                self.segueToScanner()
            }))
            
            alert.addAction(UIAlertAction(title: "Paste another shard", style: .default, handler: { action in
                self.getPasteboard()
            }))
            
            alert.addAction(UIAlertAction(title: "Cancel", style: .cancel, handler: { action in }))
            
            alert.popoverPresentationController?.sourceView = self.view
            alert.popoverPresentationController?.sourceRect = self.view.bounds
            self.present(alert, animated: true, completion: nil)
        }
    }
    
    private func deriveMnemonicFromEntropy(_ entropy: Data) {
        let recoveredEntropy = BIP39Mnemonic.Entropy(entropy)
        
        guard let mnemonic = try? BIP39Mnemonic(entropy: recoveredEntropy) else {
            showAlert(self, "", "That is not a valid bip39 mnemonic.")
            return
        }
        
        providedMnemonic = mnemonic.description
        addSeedWords()
    }
    
    @IBAction func scanQrAction(_ sender: Any) {
        segueToScanner()
    }
    
    
    private func updateCosignersForShouldSign() {
        CoreDataService.retrieveEntity(entityName: .cosigner) { [weak self] (cosigners, errorDescription) in
            guard let self = self else { return }
            
            guard let cosigners = cosigners, cosigners.count > 0 else { return }
            
            for cosigner in cosigners {
                let str = CosignerStruct(dictionary: cosigner)
                
                if str.xprv != nil || str.words != nil {
                    self.update(str.id, true)
                } else {
                    self.update(str.id, false)
                }
            }
        }
    }
    
    private func update(_ id: UUID, _ shouldSign: Bool) {
        CoreDataService.updateEntity(id: id, keyToUpdate: "shouldSign", newValue: shouldSign, entityName: .cosigner) { (_, _) in }
    }
    
    @IBAction func infoAction(_ sender: Any) {
        showInfo()
    }
    
    private func addSeedWords() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            
            self.performSegue(withIdentifier: "segueToAddSeedWords", sender: self)
        }
    }
    
    private func getPasteboard() {
        guard let text = UIPasteboard.general.string else { return }
        
        let processedText = text.lowercased().condenseWhitespace()
        
        if processedText.hasPrefix("ur:crypto-account") {
            guard let cosigner = URHelper.accountUrToCosigner(processedText) else { return }
            
            promptToAddCosigner(cosigner)
            
        } else if processedText.hasPrefix("ur:crypto-hdkey") {
            guard let cosigner = URHelper.urHdkeyToCosigner(processedText) else {
                showAlert(self, "", "Unsupported key, we only support Bitcoin mainnet/testnet hdkeys.")
                return
            }
            
            promptToAddCosigner(cosigner)
            
        } else if processedText.contains("ur:crypto-seed") {
            guard let mnemonic = URHelper.cryptoSeedToMnemonic(cryptoSeed: processedText) else { return }
            self.providedMnemonic = mnemonic
            self.addSeedWords()
            
        } else if text.contains("48h/\(coinType)h/0h/2h") || text.contains("48'/\(coinType)'/0'/2'") {
            self.addCosigner(text.condenseWhitespace())
            
        } else if Keys.validMnemonicString(processedCharacters(text)) {
            self.providedMnemonic = processedCharacters(text)
            self.addSeedWords()
            
        } else if processedText.hasPrefix("ur:crypto-sskr") {
            self.processShardUr(processedText)
            
        } else {
            showAlert(self, "", "Invalid cosigner text, we accept UR crypto-account or [<fingerprint>/48h/\(coinType)h/0h/2h]tpub.....")
        }
    }
    
    private func promptToAddCosigner(_ cosigner: String) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            
            var alertStyle = UIAlertController.Style.actionSheet
            if (UIDevice.current.userInterfaceIdiom == .pad) {
                alertStyle = UIAlertController.Style.alert
            }
            
            let alert = UIAlertController(title: "Import Cosigner?", message: "You have a valid cosigner on your clipboard, would you like to import it?", preferredStyle: alertStyle)
            
            alert.addAction(UIAlertAction(title: "Yes", style: .default, handler: { action in
                self.addCosigner(cosigner)
            }))
            
            alert.addAction(UIAlertAction(title: "Cancel", style: .cancel, handler: { action in }))
            alert.popoverPresentationController?.sourceView = self.view
            self.present(alert, animated: true, completion: nil)
        }
    }
    
    @objc func add() {
        promptToAdd()
    }
    
    private func promptToAdd() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            
            var alertStyle = UIAlertController.Style.actionSheet
            if (UIDevice.current.userInterfaceIdiom == .pad) {
                alertStyle = UIAlertController.Style.alert
            }
            
            let alert = UIAlertController(title: "Add Cosigner", message: "You may either create or import a cosigner.", preferredStyle: alertStyle)
            
            alert.addAction(UIAlertAction(title: "Create", style: .default, handler: { action in
                self.addSeedWords()
            }))
            
            alert.addAction(UIAlertAction(title: "Import", style: .default, handler: { action in
                self.importCosigner()
            }))
            
            alert.addAction(UIAlertAction(title: "Cancel", style: .cancel, handler: { action in }))
            alert.popoverPresentationController?.sourceView = self.view
            self.present(alert, animated: true, completion: nil)
        }
    }
    
    private func importCosigner() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            
            let alert = UIAlertController(title: "Import Cosigner", message: "You may either paste one as text or scan a QR code.", preferredStyle: .alert)
            
            alert.addAction(UIAlertAction(title: "Paste", style: .default, handler: { action in
                self.getPasteboard()
            }))
            
            alert.addAction(UIAlertAction(title: "Scan QR", style: .default, handler: { action in
                self.segueToScanner()
            }))
            
            alert.addAction(UIAlertAction(title: "Cancel", style: .cancel, handler: { action in }))
            alert.popoverPresentationController?.sourceView = self.view
            self.present(alert, animated: true, completion: nil)
        }
    }
    
    private func segueToScanner() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            
            self.performSegue(withIdentifier: "segueToScanKeyset", sender: self)
        }
    }
    
    @objc func refreshTable() {
        load()
    }
    
    private func load() {
        cosigners.removeAll()
        accounts.removeAll()
        
        CoreDataService.retrieveEntity(entityName: .account) { (accounts, err) in
            if let accounts = accounts {
                for account in accounts {
                    self.accounts.append(AccountStruct(dictionary: account))
                }
            }
        }
        
        CoreDataService.retrieveEntity(entityName: .cosigner) { [weak self] (cosigners, errorDescription) in
            guard let self = self else { return }
            
            guard let cosigners = cosigners, cosigners.count > 0 else {
                return
            }
            
            for (i, cosigner) in cosigners.enumerated() {
                let cosignerStruct = CosignerStruct(dictionary: cosigner)
                self.cosigners.append(cosignerStruct)
                
                if i + 1 == cosigners.count {
                    DispatchQueue.main.async { [weak self] in
                        guard let self = self else { return }
                        
                        self.keysetsTable.reloadData()
                    }
                }
            }
        }
    }
    
    private func refresh(_ section: Int) {
        cosigners.removeAll()
        
        CoreDataService.retrieveEntity(entityName: .cosigner) { [weak self] (cosigners, errorDescription) in
            guard let self = self else { return }
            
            guard let cosigners = cosigners, cosigners.count > 0 else { return }
            
            for (i, cosigner) in cosigners.enumerated() {
                let cosignerStruct = CosignerStruct(dictionary: cosigner)
                self.cosigners.append(cosignerStruct)
                
                if i + 1 == cosigners.count {
                    DispatchQueue.main.async { [weak self] in
                        guard let self = self else { return }
                        
                        self.keysetsTable.reloadSections(IndexSet(arrayLiteral: section), with: .none)
                    }
                }
            }
        }
    }
    
    func numberOfSections(in tableView: UITableView) -> Int {
        if cosigners.count > 0 {
            return cosigners.count
        } else {
            return 1
        }
    }
    
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return 1
    }
    
    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        if cosigners.count > 0 {
            let cell = tableView.dequeueReusableCell(withIdentifier: "keysetCell", for: indexPath)
            configureCell(cell)
            
            let cosigner = cosigners[indexPath.section]
            
            let fingerprintLabel = cell.viewWithTag(1) as! UILabel
            let dateAddedLabel = cell.viewWithTag(2) as! UILabel
            let isSharedImage = cell.viewWithTag(3) as! UIImageView
            let sharedText = cell.viewWithTag(4) as! UILabel
            let keysetLifehash = cell.viewWithTag(5) as! LifehashSeedView
            let detailButton = cell.viewWithTag(6) as! UIButton
            let isHotImageView = cell.viewWithTag(7) as! UIImageView
            
            if let key = cosigner.bip48SegwitAccount {
                let arr = key.split(separator: "]")
                let processed = "\(arr[0])".replacingOccurrences(of: "[", with: "")
                fingerprintLabel.text = processed
            } else {
                fingerprintLabel.text = "?"
            }            
            
            if cosigner.words != nil || cosigner.xprv != nil {
                isHotImageView.image = UIImage(systemName: "flame")
                isHotImageView.tintColor = .systemOrange
            } else {
                isHotImageView.image = UIImage(systemName: "snow")
                isHotImageView.tintColor = .white
            }
            
            dateAddedLabel.text = cosigner.dateAdded.formatted()
            
            if cosigner.sharedWith != nil {
                isSharedImage.image = UIImage(systemName: "person.2.square.stack")
                isSharedImage.tintColor = .systemPink
                sharedText.textColor = .systemPink
                for account in accounts {
                    if account.id == cosigner.sharedWith {
                        sharedText.text = account.label
                    }
                }
            } else {
                isSharedImage.image = UIImage(systemName: "person")
                isSharedImage.tintColor = .systemBlue
                sharedText.text = "unused"
                sharedText.textColor = .systemBlue
            }
            
            
            detailButton.addTarget(self, action: #selector(seeDetail(_:)), for: .touchUpInside)
            detailButton.restorationIdentifier = "\(indexPath.section)"
            
            keysetLifehash.backgroundColor = cell.backgroundColor
            keysetLifehash.background.backgroundColor = cell.backgroundColor
            keysetLifehash.lifehashImage.image = LifeHash.image(cosigner.lifehash) ?? UIImage()
            keysetLifehash.iconImage.image = UIImage(systemName: "person.2")
            keysetLifehash.iconLabel.text = cosigner.label
            
            return cell
            
        } else {
            let cell = tableView.dequeueReusableCell(withIdentifier: "cosignerDefaultCell", for: indexPath)
            let button = cell.viewWithTag(1) as! UIButton
            button.addTarget(self, action: #selector(add), for: .touchUpInside)
            return cell
        }
    }
    
    func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat {
        if cosigners.count > 0 {
            return 170
        } else {
            return 44
        }
    }
    
    func tableView(_ tableView: UITableView, commit editingStyle: UITableViewCell.EditingStyle, forRowAt indexPath: IndexPath) {
        if editingStyle == .delete {
            let keyset = cosigners[indexPath.section]
            deleteKeyset(keyset.id, indexPath.section)
        }
    }
    
    private func configureCell(_ cell: UITableViewCell) {
        cell.selectionStyle = .none
        cell.clipsToBounds = true
        cell.layer.cornerRadius = 8
        cell.layer.borderColor = UIColor.darkGray.cgColor
        cell.layer.borderWidth = 0.5
    }
    
    private func configureView(_ view: UIView) {
        view.clipsToBounds = true
        view.layer.cornerRadius = 8
    }
    
    @objc func seeDetail(_ sender: UIButton) {
        guard let sectionString = sender.restorationIdentifier, let int = Int(sectionString) else { return }
        
        cosigner = cosigners[int]
        
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            
            self.performSegue(withIdentifier: "segueToSeeCosignerDetail", sender: self)
        }
    }
    
    private func promptToEditLabel(_ keyset: CosignerStruct) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            
            let title = "Add Cosigner label"
            let message = ""
            let style = UIAlertController.Style.alert
            let alert = UIAlertController(title: title, message: message, preferredStyle: style)
            
            let save = UIAlertAction(title: "Save", style: .default) { [weak self] (alertAction) in
                guard let self = self else { return }
                
                let textField1 = (alert.textFields![0] as UITextField).text
                
                guard let updatedLabel = textField1, updatedLabel != "" else { return }
                
                self.updateLabel(keyset.id, updatedLabel)
            }
            
            alert.addTextField { (textField) in
                textField.text = keyset.label
                textField.isSecureTextEntry = false
                textField.keyboardAppearance = .dark
            }
            
            alert.addAction(save)
            
            let cancel = UIAlertAction(title: "Cancel", style: .default) { (alertAction) in }
            alert.addAction(cancel)
            
            self.present(alert, animated:true, completion: nil)
        }
    }
    
    
    private func updateLabel(_ id: UUID, _ label: String) {
        CoreDataService.updateEntity(id: id, keyToUpdate: "label", newValue: label, entityName: .cosigner) { (success, errorDescription) in
            guard success else { showAlert(self, "Label not saved!", "There was an error updating your label, please let us know about it: \(errorDescription ?? "unknown")"); return }
            
            self.load()
        }
    }
    
    @objc func deleteKeyset(_ id: UUID, _ section: Int) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            
            var alertStyle = UIAlertController.Style.actionSheet
            if (UIDevice.current.userInterfaceIdiom == .pad) {
              alertStyle = UIAlertController.Style.alert
            }
            
            let alert = UIAlertController(title: "Delete cosigner?", message: "", preferredStyle: alertStyle)
            
            alert.addAction(UIAlertAction(title: "Delete", style: .destructive, handler: { action in
                self.deleteCosignerNow(id, section)
            }))
            
            alert.addAction(UIAlertAction(title: "Cancel", style: .cancel, handler: { action in }))
            alert.popoverPresentationController?.sourceView = self.view
            self.present(alert, animated: true, completion: nil)
        }
    }
    
    private func deleteCosignerNow(_ id: UUID, _ section: Int) {
        CoreDataService.deleteEntity(id: id, entityName: .cosigner) { (success, errorDescription) in
            guard success else {
                showAlert(self, "Error deleting cosigner", "We were unable to delete that cosigner!")
                return
            }
            
            DispatchQueue.main.async { [weak self] in
                self?.cosigners.remove(at: section)
                if self?.cosigners.count ?? 0 > 0 {
                    self?.keysetsTable.deleteSections(IndexSet.init(arrayLiteral: section), with: .fade)
                } else {
                    self?.editCosigners()
                    self?.keysetsTable.reloadData()
                }
            }            
        }
    }
    
    @objc func editCosigners() {
        if cosigners.count > 0 {
            keysetsTable.setEditing(!keysetsTable.isEditing, animated: true)
        } else {
            keysetsTable.setEditing(false, animated: true)
        }
        
        if keysetsTable.isEditing {
            editButton = UIBarButtonItem(title: "Done", style: .plain, target: self, action: #selector(editCosigners))
        } else {
            editButton = UIBarButtonItem(title: "Edit", style: .plain, target: self, action: #selector(editCosigners))
        }
        
        self.navigationItem.setRightBarButtonItems([addButton, editButton], animated: true)
    }
    
    private func addCosigner(_ account: String) {
        AddCosigner.add(account) { (success, message, errorDescription, savedNew, cosignerStruct) in
            guard success, let cosignerStruct = cosignerStruct else {
                showAlert(self, message, errorDescription ?? "unknown error")
                return
            }
            
            guard savedNew else {
                self.load()
                showAlert(self, "", "\(cosignerStruct.label) has been updated with a private key ✓")
                return
            }
            
            DispatchQueue.main.async {
                self.keysetsTable.reloadData()
                
                var alertStyle = UIAlertController.Style.actionSheet
                if (UIDevice.current.userInterfaceIdiom == .pad) {
                  alertStyle = UIAlertController.Style.alert
                }
                
                let alert = UIAlertController(title: "Cosigner imported ✓", message: "Would you like to give it a label now? You can edit the label at any time.", preferredStyle: alertStyle)
                
                alert.addAction(UIAlertAction(title: "Add label", style: .default, handler: { action in
                    self.promptToEditLabel(cosignerStruct)
                }))
                                
                alert.addAction(UIAlertAction(title: "Cancel", style: .cancel, handler: { action in
                    self.load()
                }))
                
                alert.popoverPresentationController?.sourceView = self.view
                self.present(alert, animated: true, completion: nil)
            }
        }
    }
    
    private func showInfo() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            
            self.performSegue(withIdentifier: "segueToCosignersInfo", sender: self)
        }
    }
    
    // MARK: - Navigation

    // In a storyboard-based application, you will often want to do a little preparation before navigation
    override func prepare(for segue: UIStoryboardSegue, sender: Any?) {
        // Get the new view controller using segue.destination.
        // Pass the selected object to the new view controller.
        switch segue.identifier {
        case "segueToSeeCosignerDetail":
            guard let vc = segue.destination as? SeedDetailViewController else { fallthrough }
            
            vc.cosigner = self.cosigner
            
        case "segueToScanKeyset":
            guard let vc = segue.destination as? QRScannerViewController else { fallthrough }
            
            vc.doneBlock = { [weak self] result in
                guard let self = self, let result = result else { return }
                
                let processedResult = result.lowercased().condenseWhitespace()
                
                if processedResult.hasPrefix("ur:crypto-account"), let account = URHelper.accountUrToCosigner(processedResult) {
                    self.addCosigner(account)
                    
                } else if processedResult.hasPrefix("ur:crypto-hdkey"), let account = URHelper.urHdkeyToCosigner(processedResult) {
                    self.addCosigner(account)
                    
                } else if result.contains("48h/\(self.coinType)h/0h/2h") || result.contains("48'/\(self.coinType)'/0'/2'") {
                    self.addCosigner(result)
                    
                } else if processedResult.lowercased().contains("ur:crypto-seed") {
                    guard let mnemonic = URHelper.cryptoSeedToMnemonic(cryptoSeed: processedResult) else { return }
                    self.providedMnemonic = mnemonic
                    self.addSeedWords()
                    
                } else if Keys.validMnemonicString(processedCharacters(result)) {
                    self.providedMnemonic = processedCharacters(result)
                    self.addSeedWords()
                    
                } else if processedResult.hasPrefix("ur:crypto-response"), let account = URHelper.decodeResponse(processedResult) {
                    self.addCosigner(account)
                    
                } else if processedResult.hasPrefix("ur:crypto-sskr") {
                    self.processShardUr(processedResult)
                    
                } else if processedResult.hasPrefix("ur:crypto-output") {
                    print("crypto-output: \(processedResult)")
                    
                } else {
                    showAlert(self, "", "Unrecognized format.")
                }
            }
            
        case "segueToCosignersInfo":
            guard let vc = segue.destination as? InfoViewController else { fallthrough }
            
            vc.isCosigner = true
            
        case "segueToAddSeedWords":
            guard let vc = segue.destination as? AddSignerViewController else { fallthrough }
            
            vc.providedMnemonic = self.providedMnemonic
            self.providedMnemonic = ""
            
            vc.doneBlock = {
                self.load()
            }
            
        default:
            break
        }
    }
    
    private func authenticate() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            
            self.performSegue(withIdentifier: "segueToAuth", sender: self)
        }
    }
}
