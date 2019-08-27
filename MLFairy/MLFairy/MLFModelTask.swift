//
//  MLModelTask.swift
//  MLFairy
//
//  Copyright © 2019 MLFairy. All rights reserved.
//

import Foundation
import CoreML
import Alamofire

class MLFModelTask {
	private struct MutableState {
		var userId: String?
		var error: Error?
		var downloadMetadata: MLFDownloadMetadata?
		var downloadMetadataRequest: DataRequest?
		var downloadFileUrl: URL?
		var downloadRequest: DownloadRequest?
		
		var compiledUrl: URL?
		var compiledModel: MLModel?
		var callbacks: [() -> Void] = []
	}
	private let protectedMutableState: MLFProtector<MutableState> = MLFProtector(MutableState())
	
	private let token: String
	
	private let app: MLFApp
	private let network: MLFNetwork
	private let log: MLFLogger
	private let persistence: MLFPersistence
	
	private let underlyingQueue: DispatchQueue
	private let compilationQueue: DispatchQueue
	
	init(
		token: String,
		app: MLFApp,
		network: MLFNetwork,
		persistence: MLFPersistence,
		computationQueue: DispatchQueue,
		compilationQueue: DispatchQueue,
		log: MLFLogger
	) {
		self.token = token
		self.network = network
		self.app = app
		self.underlyingQueue = computationQueue
		self.compilationQueue = compilationQueue
		self.log = log
		self.persistence = persistence
	}
	
	@discardableResult
	func set(userId: String) -> MLFModelTask {
		self.protectedMutableState.write { $0.userId = userId }
		// TODO: Notify server of userId. Is this even possible if there's no task being held by anyone?
		return self;
	}
	
	@discardableResult
	func resume() -> MLFModelTask {		
		self.underlyingQueue.async {
			let body: [String: Any] = [
				"token": self.token,
				"data": self.app.appInformation(),
			]
			
			let request = self.network
				.metadata(body)
				.responseDecodable(queue: self.underlyingQueue) { self.onDownloadResponse($0) }

			self.protectedMutableState.write{ $0.downloadMetadataRequest = request }
			request.resume()
		}
		
		return self;
	}
	
	@discardableResult
	func response(queue: DispatchQueue, _ callback: @escaping (MLModel?, Error?) -> Void) -> MLFModelTask {
		appendResponseQueue {
			var model: MLModel?
			var error: Error?
			self.protectedMutableState.read {
				model = $0.compiledModel
				error = $0.error
			}
			
			queue.async {
				callback(model, error)
			}
		}
		
		return self;
	}
	
	private func appendResponseQueue(_ closure: @escaping () -> Void) {
		self.protectedMutableState.write { state in
			state.callbacks.append(closure)
		}
	}
	
	private func onDownloadResponse(_ response: DataResponse<MLFDownloadMetadata>) {
		self.protectedMutableState.write{ $0.downloadMetadataRequest = nil }
		
		switch(response.result) {
		case .success(let value):
			self.log.d("Successfully downloaded metadata:\n\(value.debugDescription)")
			self.persistence.save(value, for: self.token)
			self.didDownloadMetadata(value)
			break;
		case .failure(let failure):
			let error = MLFNetwork.remapToMLFErrorIfNecessary(failure, data:response.data)
			let diskMetadata = self.persistence.findModel(for: self.token)
			if let _ = diskMetadata.url, let metadata = diskMetadata.metadata {
				self.log.d("Failed to download model metadata for \(token). Will use version from disk:\n\(metadata.debugDescription)\n\(error)")
				self.didDownloadMetadata(metadata)
			} else {
				self.finish(error: .downloadFailed(message: "Failed to download model metadata for \(token)", reason: error))
			}

			break;
		}
	}
	
	private func didDownloadMetadata(_ metadata: MLFDownloadMetadata) {
		self.protectedMutableState.write { $0.downloadMetadata = metadata }
		
		guard let _ = metadata.activeVersion, let url = metadata.modelFileUrl else {
			self.finish(error: .noDownloadAvailable)
			return;
		}
		
		if let destination = self.persistence.modelFileFor(model: metadata) {
			if self.persistence.exists(file: destination) {
				self.log.d("Skipping download. \(destination) exists. Will use existing file.")
				self.didDownloadFile(url: destination, metadata)
			} else {
				self.log.d("Downloading model into \(destination)")
				self.download(url:url, into: destination, metadata)
			}
		}
	}
	
	private func download(url: String, into destination: URL, _ metadata: MLFDownloadMetadata) {
		let request = self.network
			.download(url, into: destination)
			.response(queue: self.underlyingQueue) { self.onDownloadFileResponse($0, metadata) }
		
		self.protectedMutableState.write { $0.downloadRequest = request }
		
		request.resume()
	}
	
	private func onDownloadFileResponse(
		_ response: DownloadResponse<URL?>,
		_ metadata: MLFDownloadMetadata
	) {
		self.protectedMutableState.write { $0.downloadRequest = nil }
		switch(response.result) {
		case .success(let value):
			self.didDownloadFile(url: value!, metadata)
			break;
		case .failure(let failure):
			self.finish(
				error: .downloadFailed(
					message:"Failed to download model for \(token)",
					reason: failure
				)
			)
			break;
		}
	}
	
	private func didDownloadFile(url: URL, _ metadata: MLFDownloadMetadata) {
		self.protectedMutableState.write { $0.downloadFileUrl = url }
		
		do {
			try self.performChecksum(url, with:metadata)
			self.compileModel(at: url)
		} catch MLFError.failedChecksum {
			self.persistence.deleteFile(at: url)
			self.finish(error: .failedChecksum)
		} catch {
			self.finish(error: .checksumError(error: error))
		}
	}
	
	private func compileModel(at url: URL) {
		self.compilationQueue.async {
			do {
				let compiledUrl = try MLModel.compileModel(at: url)
				let model = try MLModel(contentsOf: compiledUrl)
				self.onCompiled(model: model, from:compiledUrl)
				self.finish()
			} catch {
				self.finish(error: .compilationFailed(
					message: "Failed to compile model for token \(self.token)",
					reason: error
				))
			}
		}
	}
	
	private func performChecksum(_ url: URL, with metadata: MLFDownloadMetadata) throws {
		guard let hash = metadata.hash, let algorithm = metadata.algorithm else {
			self.log.d("No hash or algorithm in metadata. Skipping checksum.")
			return;
		}
		
		guard algorithm.lowercased() == "md5" else {
			self.log.d("Unsupported checksum algorithm \(algorithm). Skipping checksum.")
			return;
		}
		
		let checksumDigest = try self.persistence.md5File(url: url)
		let data = Data(checksumDigest)
		let checksum = data.base64EncodedString(); // digest.map { String(format: "%02hhx", $0) }.joined()
		if checksum != hash {
			throw MLFError.failedChecksum
		}
	}
	
	private func onCompiled(model: MLModel, from url: URL) {
		self.protectedMutableState.write {
			$0.compiledModel = model
			$0.compiledUrl = url
		}
	}
	
	private func finish(error: MLFError? = nil) {
		if let error = error {
			switch(error) {
			case .compilationFailed(let message, let reason),
				 .downloadFailed(let message, let reason):
				self.log.d("\(message): \(reason)")
				break
			case .networkError(let response):
				self.log.d("\(response)")
				break
			case .noDownloadAvailable:
				self.log.d("No model available for download")
				break
			case .checksumError(let error):
				self.log.d("There was an error while performing checksum: \(error)")
				break;
			case .failedChecksum:
				self.log.d("Model failed checksum")
				break
			}
		}
		
		self.underlyingQueue.async {
			var completions: [() -> Void] = []
			
			self.protectedMutableState.write { state in
				state.error = error
				completions = state.callbacks
				state.callbacks.removeAll()
			}
			
			completions.forEach { $0() }
		}
	}
}
