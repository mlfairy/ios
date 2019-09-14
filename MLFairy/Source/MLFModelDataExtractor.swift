//
//  MLFModelDataExtractor.swift
//  MLFairy
//
//  Copyright © 2019 MLFairy. All rights reserved.
//

import Foundation
import CoreML

class MLFModelDataExtractor {
	private let primitive = MLFPrimitiveValueExtractor()
	private let noop = MLFNoOpValueExtractor()
	
	func modelInformation(model: MLModel) -> [String: String] {
		var dictionary: [String: String] = [:]
		
		for (key, value) in model.modelDescription.metadata {
			if let value = value as? String {
				dictionary[key.rawValue] = value
			}
		}
		
		var counter = 0
		model.modelDescription.inputDescriptionsByName.forEach { _, description in
			self.describe(description) { key, value in
				dictionary["input\(counter)_\(key)"] = value
			}
			counter += 1
		}
		
		counter = 0
		model.modelDescription.outputDescriptionsByName.forEach { _, description in
			self.describe(description) { key, value in
				dictionary["output\(counter)_\(key)"] = value
			}
			
			counter += 1
		}
		
		return dictionary
	}
	
	func convert(
		input: MLFeatureProvider,
		output: MLFeatureProvider
	) -> (input: [String: Any], output: [String: Any]) {
		var inputResult: [String: Any] = [:]
		self.iterate(over: input).forEach { item in
			inputResult[item.name] = item.value
		}
		
		var outputResult: [String: Any] = [:]
		self.iterate(over: output).forEach { item in
			outputResult[item.name] = item.value
		}
		
		return (input: inputResult, output: outputResult)
	}
	
	private func iterate(over provider: MLFeatureProvider) -> [(name: String, value: Any)] {
		return provider.featureNames
			.map { name -> (name: String, feature:MLFeatureValue?) in
				return (name: name, feature: provider.featureValue(for: name))
			}.filter {
				$0.feature != nil
			}.map { (name: String, feature: MLFeatureValue?) -> (name: String, value: Any)? in
				let extractor = self.extractor(from: feature!)
				if let value = extractor.extract(feature!) {
					return (name: name, value: value)
				}
				return nil
			}.filter {
				$0 != nil
			} as! [(name: String, value: Any)]
	}
	
	private func extractor(from feature: MLFeatureValue) -> MLFValueExtractor {
		switch feature.type {
		case .int64, .double, .string:
			return primitive
		case .invalid, .dictionary, .image, .multiArray:
			return noop
		default:
			return noop
		}
	}
	
	private func describe(
		_ description: MLFeatureDescription,
		callback: (String, String) -> Void
	) {

		callback("name", description.name)
		callback("type", "\(description.type.rawValue)")
		callback("optional", description.isOptional ? "1" : "0")
		
		var extras: [String: String] = [:]
		if let constraint = description.dictionaryConstraint {
			extras["dictionaryConstraint"] = "\(constraint.keyType.rawValue)"
		}
		
		if let constraint = description.imageConstraint {
			extras["imageConstraint"] = "\(constraint)"
		}
		
		if let constraint = description.multiArrayConstraint {
			extras["multiArrayConstraint"] = "\(constraint)"
		}
		
		if #available(iOS 12.0, macOS 10.14, tvOS 12.0, *) {
			if let constraint = description.sequenceConstraint {
				extras["sequenceConstraint"] = "\(constraint)"
			}
		}
		
		if let extras = extras.asJsonString() {
			callback("extras", extras)
		}
	}
}

extension Dictionary {
	func asJsonString() -> String? {
		guard let jsonData = try? JSONSerialization.data(withJSONObject: self, options: []) else {
			return nil
		}
		
		return String(data: jsonData, encoding: .utf8)
	}
}
