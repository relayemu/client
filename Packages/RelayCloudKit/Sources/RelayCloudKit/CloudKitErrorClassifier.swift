// SPDX-FileCopyrightText: 2026 Maiko BOSSUYT
// SPDX-License-Identifier: GPL-3.0-or-later
//  CloudKitErrorClassifier.swift
//  RelayCloudKit
//
//  One place that turns CKError codes into RelaySync's stable classifications.
//  Nothing else in Relay looks at CKError.

import CloudKit
import Foundation
import RelaySync

public enum CloudKitErrorClassifier {
    public static func classify(_ error: Error) -> TransportProblem {
        guard let ck = error as? CKError else { return .other(String(describing: type(of: error))) }
        switch ck.code {
        case .quotaExceeded: return .quotaFull
        case .notAuthenticated, .accountTemporarilyUnavailable, .permissionFailure: return .accountUnavailable
        case .networkUnavailable, .networkFailure, .serviceUnavailable, .serverResponseLost: return .network
        case .requestRateLimited, .zoneBusy: return .rateLimited(retryAfterSeconds: ck.retryAfterSeconds.map { Int($0.rounded(.up)) })
        case .serverRecordChanged: return .serverRecordChanged
        case .zoneNotFound, .userDeletedZone: return .zoneMissing
        case .unknownItem: return .unknownItem
        case .limitExceeded: return .limitExceeded
        case .invalidArguments, .constraintViolation, .serverRejectedRequest, .incompatibleVersion, .assetFileNotFound, .assetFileModified, .assetNotAvailable:
            return .invalidRecord(ck.code.description)
        case .partialFailure:
            // The engine reports per-record failures separately; a bare partial failure is transient.
            return .network
        default:
            return .other(ck.code.description)
        }
    }

    /// The account availability CloudKit reports.
    public static func availability(_ status: CKAccountStatus) -> AccountAvailability {
        switch status {
        case .available: return .available
        case .noAccount: return .noAccount
        case .restricted: return .restricted
        case .temporarilyUnavailable: return .temporarilyUnavailable
        case .couldNotDetermine: return .unknown
        @unknown default: return .unknown
        }
    }
}

extension CKError.Code: @retroactive CustomStringConvertible {
    public var description: String {
        switch self {
        case .internalError: return "internalError"
        case .partialFailure: return "partialFailure"
        case .networkUnavailable: return "networkUnavailable"
        case .networkFailure: return "networkFailure"
        case .badContainer: return "badContainer"
        case .serviceUnavailable: return "serviceUnavailable"
        case .requestRateLimited: return "requestRateLimited"
        case .missingEntitlement: return "missingEntitlement"
        case .notAuthenticated: return "notAuthenticated"
        case .permissionFailure: return "permissionFailure"
        case .unknownItem: return "unknownItem"
        case .invalidArguments: return "invalidArguments"
        case .resultsTruncated: return "resultsTruncated"
        case .serverRecordChanged: return "serverRecordChanged"
        case .serverRejectedRequest: return "serverRejectedRequest"
        case .assetFileNotFound: return "assetFileNotFound"
        case .assetFileModified: return "assetFileModified"
        case .incompatibleVersion: return "incompatibleVersion"
        case .constraintViolation: return "constraintViolation"
        case .operationCancelled: return "operationCancelled"
        case .changeTokenExpired: return "changeTokenExpired"
        case .batchRequestFailed: return "batchRequestFailed"
        case .zoneBusy: return "zoneBusy"
        case .badDatabase: return "badDatabase"
        case .quotaExceeded: return "quotaExceeded"
        case .zoneNotFound: return "zoneNotFound"
        case .limitExceeded: return "limitExceeded"
        case .userDeletedZone: return "userDeletedZone"
        case .tooManyParticipants: return "tooManyParticipants"
        case .alreadyShared: return "alreadyShared"
        case .referenceViolation: return "referenceViolation"
        case .managedAccountRestricted: return "managedAccountRestricted"
        case .participantMayNeedVerification: return "participantMayNeedVerification"
        case .serverResponseLost: return "serverResponseLost"
        case .assetNotAvailable: return "assetNotAvailable"
        case .accountTemporarilyUnavailable: return "accountTemporarilyUnavailable"
        @unknown default: return "ckError(\(rawValue))"
        }
    }
}
