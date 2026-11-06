//
//  JSONFragments.swift
//  LegacyCompat
//
//  iOS 12's JSONEncoder and JSONDecoder refuse a top-level value that is not
//  an array or an object ("Top-level Int encoded as number JSON fragment");
//  iOS 13 accepts it. A setting stored as a bare Bool, Int, String or Data
//  was therefore never written on iOS 12, and came back as its default on
//  every launch. These wrap the value in a one-element array, and read
//  either form, so what a later system wrote bare still reads.
//

import Foundation

public enum LegacyJSON {
    public static func encode<Value: Encodable>(_ value: Value) -> Data? {
        try? JSONEncoder().encode([value])
    }

    public static func decode<Value: Decodable>(_: Value.Type, from data: Data) -> Value? {
        if let wrapped = try? JSONDecoder().decode([Value].self, from: data), let value = wrapped.first {
            return value
        }
        return try? JSONDecoder().decode(Value.self, from: data)
    }
}
