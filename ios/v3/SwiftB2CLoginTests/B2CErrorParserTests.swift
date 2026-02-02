import Testing
@testable import SwiftB2CLogin

/// Tests para B2CErrorParser
/// Verifica la extracción correcta de errores B2C de respuestas MSAL
@Suite("B2CErrorParser Tests")
@MainActor
struct B2CErrorParserTests {
    
    // MARK: - Parse from JSON String
    
    @Test("Parse valid B2C error JSON")
    func parseValidB2CError() {
        let jsonString = """
        {"status": "400", "errorCode": "B2C0001", "message": "Token validation failed"}
        """
        let data = jsonString.data(using: .utf8)!
        
        let userInfo: [String: Any] = ["MSALErrorDescriptionKey": jsonString]
        let error = NSError(domain: "MSALErrorDomain", code: -50000, userInfo: userInfo)
        
        let result = B2CErrorParser.parse(from: error)
        
        #expect(result != nil)
        #expect(result?.errorCode == "B2C0001")
        #expect(result?.status == "400")
        #expect(result?.message == "Token validation failed")
    }
    
    @Test("Parse embedded JSON in error description")
    func parseEmbeddedJSON() {
        let description = """
        Some prefix text {"status": "400", "errorCode": "B2C0002", "message": "Max attempts reached"} some suffix
        """
        let userInfo: [String: Any] = ["NSLocalizedDescription": description]
        let error = NSError(domain: "MSALErrorDomain", code: -50000, userInfo: userInfo)
        
        let result = B2CErrorParser.parse(from: error)
        
        #expect(result != nil)
        #expect(result?.errorCode == "B2C0002")
    }
    
    @Test("Returns nil for non-B2C error")
    func parseNonB2CError() {
        let error = NSError(domain: "NSURLErrorDomain", code: -1009, userInfo: [
            NSLocalizedDescriptionKey: "The Internet connection appears to be offline."
        ])
        
        let result = B2CErrorParser.parse(from: error)
        
        #expect(result == nil)
    }
    
    // MARK: - toAuthError Conversion
    
    @Test("Convert B2C error to AuthError.custom")
    func convertB2CToAuthError() {
        let jsonString = """
        {"status": "400", "errorCode": "B2C0003", "message": "User blocked"}
        """
        let userInfo: [String: Any] = ["MSALErrorDescriptionKey": jsonString]
        let error = NSError(domain: "MSALErrorDomain", code: -50000, userInfo: userInfo)
        
        let result = B2CErrorParser.toAuthError(error)
        
        if case .custom(let b2cError) = result {
            #expect(b2cError.errorCode == "B2C0003")
        } else {
            Issue.record("Expected AuthError.custom")
        }
    }
    
    @Test("Convert user cancelled to AuthError.cancelled")
    func convertCancelledToAuthError() {
        let error = NSError(domain: "MSALErrorDomain", code: -50005, userInfo: nil)
        
        let result = B2CErrorParser.toAuthError(error)
        
        #expect(result == .cancelled)
    }
    
    @Test("Convert network error to AuthError.network")
    func convertNetworkToAuthError() {
        let error = NSError(domain: "NSURLErrorDomain", code: -1009, userInfo: [
            NSLocalizedDescriptionKey: "No internet"
        ])
        
        let result = B2CErrorParser.toAuthError(error)
        
        if case .network(let message) = result {
            #expect(message == "No internet")
        } else {
            Issue.record("Expected AuthError.network")
        }
    }
    
    @Test("Convert configuration error to AuthError.configuration")
    func convertConfigurationToAuthError() {
        let error = NSError(domain: "MSALErrorDomain", code: -50000, userInfo: [
            "MSALErrorDescriptionKey": "Invalid redirect URI"
        ])
        
        let result = B2CErrorParser.toAuthError(error)
        
        if case .configuration(let message) = result {
            #expect(message.contains("Invalid redirect URI"))
        } else {
            Issue.record("Expected AuthError.configuration")
        }
    }
    
    // MARK: - B2CCustomError Properties
    
    @Test("B2CCustomError known codes are identified")
    func b2cKnownCodes() {
        let error = B2CCustomError(status: "400", errorCode: "B2C0002", message: "Max attempts")
        
        #expect(error.isMaxAttemptsError == true)
        #expect(error.isRetryable == false)
        #expect(error.knownCode == .maxAttemptsReached)
    }
    
    @Test("B2CCustomError retryable for recoverable errors")
    func b2cRetryable() {
        let error = B2CCustomError(status: "400", errorCode: "B2C0004", message: "Invalid OTP")
        
        #expect(error.isRetryable == true)
        #expect(error.knownCode == .invalidOTP)
    }
    
    // MARK: - URL Query Parameter Parsing
    
    @Test("Parse B2C error from URL with b2c_error_code")
    func parseURLWithB2CErrorCode() {
        let url = URL(string: "https://example.com/callback?b2c_error_code=B2C0001&error_description=Token%20validation%20failed")!
        
        let result = B2CErrorParser.parse(from: url)
        
        #expect(result != nil)
        #expect(result?.errorCode == "B2C0001")
        #expect(result?.message == "Token validation failed")
        #expect(result?.status == "400")
    }
    
    @Test("Parse B2C error from URL with error_message param")
    func parseURLWithErrorMessage() {
        let url = URL(string: "https://example.com/callback?b2c_error_code=B2C0002&error_message=Max%20attempts%20reached")!
        
        let result = B2CErrorParser.parse(from: url)
        
        #expect(result != nil)
        #expect(result?.errorCode == "B2C0002")
        #expect(result?.message == "Max attempts reached")
    }
    
    @Test("Parse OAuth error fallback from URL")
    func parseURLWithOAuthError() {
        let url = URL(string: "https://example.com/callback?error=access_denied&error_description=B2C0003%3A%20User%20blocked")!
        
        let result = B2CErrorParser.parse(from: url)
        
        #expect(result != nil)
        #expect(result?.errorCode == "B2C0003")
    }
    
    @Test("Returns nil for URL without error params")
    func parseURLWithoutErrors() {
        let url = URL(string: "https://example.com/callback?code=auth_code&state=xyz")!
        
        let result = B2CErrorParser.parse(from: url)
        
        #expect(result == nil)
    }
    
    @Test("Returns nil for URL without query params")
    func parseURLWithoutQueryParams() {
        let url = URL(string: "https://example.com/callback")!
        
        let result = B2CErrorParser.parse(from: url)
        
        #expect(result == nil)
    }
    
    @Test("Parse URL with empty b2c_error_code returns nil")
    func parseURLWithEmptyErrorCode() {
        let url = URL(string: "https://example.com/callback?b2c_error_code=&error_description=Some%20error")!
        
        let result = B2CErrorParser.parse(from: url)
        
        #expect(result == nil)
    }
}
