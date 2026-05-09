//
//  PairCode.swift
//  leanring-buddy
//
//  6-digit, 5-min-expiry pairing token. Generated on the kid side,
//  typed in by the senior during the in-person install.
//

import Foundation

struct PairCode: Equatable, Codable {
    /// Six ASCII digits. Always padded with leading zeros so length is
    /// stable; Mom's display boxes assume exactly six characters.
    let digits: String
    let issuedAt: Date
    let expiresAt: Date

    func isExpired(at referenceDate: Date) -> Bool {
        expiresAt <= referenceDate
    }
}
