import Foundation

public enum APNsEnvironment: String {
    case development
    case production

    /// A locally signed app carries its provisioning profile, regardless of
    /// whether the binary was built in Debug or Release. Distributed builds
    /// without a profile use production APNs.
    public static func fromProvisioningProfile(_ profile: Data?) -> Self? {
        guard let profile else { return .production }
        // Apple wraps the profile's property list in a CMS envelope.
        let plist: Data
        if let start = profile.range(of: Data("<plist".utf8)),
           let end = profile.range(of: Data("</plist>".utf8), in: start.upperBound..<profile.endIndex) {
            plist = profile.subdata(in: start.lowerBound..<end.upperBound)
        } else {
            plist = profile
        }
        guard let contents = (try? PropertyListSerialization.propertyList(
            from: plist, options: [], format: nil
        )) as? [String: Any],
              let entitlements = contents["Entitlements"] as? [String: Any],
              let environment = entitlements["aps-environment"] as? String
        else { return nil }
        return Self(rawValue: environment)
    }
}
