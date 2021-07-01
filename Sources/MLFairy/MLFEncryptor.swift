//
//  MLFEncryptor.swift
//  MLFairy
//
//  Copyright © 2019 MLFairy. All rights reserved.
//

import Foundation
import MLFSupport

class MLFEncryptor {
	private let parameters: MLFEncryptionData
	private let support: MLFTools
	private let encoder = JSONEncoder()
	
	init(
		_ parameters: MLFEncryptionData,
		support: MLFTools
	) {
		self.support = support
		self.parameters = parameters
	}
	
	 func encrypt(_ prediction: MLFPrediction) throws -> MLFEncryptedData {
		let encoded = try self.encoder.encode(prediction).base64EncodedData()
		let result = try self.support.encrypt(encoded, with: self.parameters.publicKey)
		
		let data = MLFEncryptedData(
			data: result.output.base64EncodedString(),
			modelId: prediction.modelId,
			encryptionId: self.parameters.id,
			aesKey: result.aes.base64EncodedString(),
			ivKey: result.iv.base64EncodedString()
		)
		
		return data
	}
}
