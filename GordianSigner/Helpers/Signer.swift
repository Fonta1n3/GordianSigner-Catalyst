//
//  Signer.swift
//  GordianSigner
//
//  Created by Peter on 9/29/20.
//  Copyright © 2020 Blockchain Commons. All rights reserved.
//

import Foundation
import LibWally

class PSBTSigner {
    
    class func sign(_ psbt: String, _ xprv: HDKey?, completion: @escaping ((psbt: PSBT?, signedFor: [String]?, errorMessage: String?)) -> Void) {
        var seedsToSignWith = [String]()
        var xprvsToSignWith = [HDKey]()
        
        if xprv != nil {
            xprvsToSignWith.append(xprv!)
        }
        
        var psbtToSign:PSBT!
        var network:Network!
        var signedFor = [String]()
        
        func reset() {
            seedsToSignWith.removeAll()
            xprvsToSignWith.removeAll()
            psbtToSign = nil
        }
        
        func attemptToSignLocally() {
            /// Need to ensure similiar seeds do not sign mutliple times. This can happen if a user adds the same seed multiple times.
            var xprvStrings = [String]()
            
            for xprv in xprvsToSignWith {
                xprvStrings.append(xprv.description)
            }
            
            xprvsToSignWith.removeAll()
            let uniqueXprvs = Array(Set(xprvStrings))
            
            for uniqueXprv in uniqueXprvs {
                if let xprv = try? HDKey(base58: uniqueXprv) {
                    xprvsToSignWith.append(xprv)
                }
            }
            
            guard xprvsToSignWith.count > 0  else { return }
            var signableKeys = [String]()
            
            for (i, key) in xprvsToSignWith.enumerated() {
                let inputs = psbtToSign.inputs
                
                for (x, input) in inputs.enumerated() {
                    /// Create an array of child keys that we know can sign our inputs.                    
                    if let origins: [PubKey : KeyOrigin] = input.canSignOrigins(with: key) {
                        for origin in origins {
                            if let childKey = try? key.derive(using: origin.value.path) {
                                if let privKey = childKey.privKey {
                                    signableKeys.append(privKey.wif)
                                }
                            }
                        }
                    }
                    
                    /// Once the above loops complete we remove an duplicate signing keys from the array then sign the psbt with each unique key.
                    if i + 1 == xprvsToSignWith.count && x + 1 == inputs.count {
                        let uniqueSigners = Array(Set(signableKeys))
                        
                        guard uniqueSigners.count > 0 else {
                            completion((nil, nil, "Looks like none of your signers can sign this psbt, ensure you added the signer and its optional passphrase correctly."))
                            return
                        }
                        
                        for (s, signer) in uniqueSigners.enumerated() {
                            guard let signingKey = try? Key(wif: signer, network: network) else { return }
                            signedFor.append(signingKey.pubKey.data.hexString)
                            psbtToSign = try? psbtToSign.signed(with: signingKey)
                            //psbtToSign.sign(signingKey)
                            /// Once we completed the signing loop we finalize with our node.
                            if s + 1 == uniqueSigners.count {
                                completion((psbtToSign, signedFor, nil))
                            }
                        }
                    }
                }
            }
        }
        
        /// Fetch keys to sign with
        func getKeysToSignWith() {
            xprvsToSignWith.removeAll()
            if xprv != nil {
                xprvsToSignWith.append(xprv!)
            }
            
            if seedsToSignWith.count > 0 {
                for (i, words) in seedsToSignWith.enumerated() {
                    guard let masterKey = Keys.masterXprv(words, ""),
                        let hdkey = try? HDKey(base58: masterKey) else { return }
                    
                    xprvsToSignWith.append(hdkey)
                    
                    if i + 1 == seedsToSignWith.count {
                        attemptToSignLocally()
                    }
                }
            } else {
                attemptToSignLocally()
            }            
        }
        
        /// Fetch wallets on the same network
        func getSeeds() {
            seedsToSignWith.removeAll()
            
            CoreDataService.retrieveEntity(entityName: .signer) { (signers, errorDescription) in
                guard let signers = signers, signers.count > 0 else {
                    completion((nil, nil, "Looks like you do not have any signers added yet. Tap the signer button then + to add signers."))
                    return
                }
                
                for (i, signer) in signers.enumerated() {
                    let signerStruct = SignerStruct(dictionary: signer)
                    
                    if let encryptedEntropy = signerStruct.entropy {
                        guard let decryptedEntropy = Encryption.decrypt(encryptedEntropy) else {
                            completion((nil, nil, "There was an error decrypting your signer"))
                            return
                        }
                        
                        guard let words = Keys.mnemonic(decryptedEntropy) else {
                            completion((nil, nil, "There was an error converting your signer to a mnemonic"))
                            return
                        }
                        
                        seedsToSignWith.append(words)
                    }
                    
                    if i + 1 == signers.count {
                        getKeysToSignWith()
                    }
                }
            }
        }
        
        do {
            psbtToSign = try PSBT(psbt: psbt, network: .testnet)
            network = .testnet
            
            if psbtToSign.isComplete {
                completion((psbtToSign, nil, nil))
            } else {
                getSeeds()
            }
            
        } catch {
             completion((nil, nil, "Error converting that psbt"))
        }
    }
}
