import Foundation

// MARK: - EDGAR Parsing Helpers
//
// HTML/XML heuristic extraction for SEC filing content.
// These are best-effort parsers — proxy filings vary wildly in format.

extension StocksEDGARService {

    // MARK: - Proposal Extraction

    static func parseProposals(from html: String) -> [ProxyFilingData.Proposal] {
        var proposals: [ProxyFilingData.Proposal] = []
        let patterns = [
            "(?i)(?:proposal|item)\\s*(\\d+)\\s*[.:\\-\u{2014}]\\s*(.+?)(?:<|$)",
            "(?i)vote\\s+on\\s+(?:the\\s+)?(?:proposal|matter)\\s*(\\d+)\\s*[.:\\-\u{2014}]?\\s*(.+?)(?:<|$)",
            "(?i)(\\d+)[.\\s]*(?:election|appointment|ratification|approval|authorization|advisory)\\s+(.+?)(?:<|$)",
        ]
        for pattern in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern) {
                let range = NSRange(html.startIndex..., in: html)
                let matches = regex.matches(in: html, range: range)
                for m in matches {
                    let num = Int((html as NSString).substring(with: m.range(at: 1))) ?? (proposals.count + 1)
                    let title = cleanHTML((html as NSString).substring(with: m.range(at: 2)))
                    if !title.isEmpty && !proposals.contains(where: { $0.title == title }) {
                        proposals.append(ProxyFilingData.Proposal(number: num, title: title, description: nil))
                    }
                }
            }
            if !proposals.isEmpty { break }
        }
        return proposals
    }

    // MARK: - Board Member Extraction

    static func parseBoardMembers(from html: String) -> [String] {
        var members: [String] = []
        let lower = html.lowercased()
        guard let boardRange = lower.range(of: "board of directors") else { return members }
        let section = String(String(html[boardRange.upperBound...]).prefix(5000))
        let namePattern = "(?i)(?:Mr\\.|Ms\\.|Mrs\\.)?\\s*([A-Z][a-z]+\\s+[A-Z][a-z]+(?:\\s+[A-Z][a-z]+)?)"
        if let regex = try? NSRegularExpression(pattern: namePattern) {
            let range = NSRange(section.startIndex..., in: section)
            for m in regex.matches(in: section, range: range) {
                let name = (section as NSString).substring(with: m.range(at: 1)).trimmingCharacters(in: .whitespaces)
                if !name.isEmpty && !members.contains(name) && name.count > 3 {
                    members.append(name)
                }
            }
        }
        return Array(members.prefix(20))
    }

    // MARK: - Meeting Date Extraction

    static func parseMeetingDate(from html: String) -> String? {
        let patterns = [
            "(?i)(?:annual|special)\\s+meeting.*?(?:on|held|scheduled)\\s+(?:on\\s+)?([A-Z][a-z]+\\s+\\d{1,2},?\\s+\\d{4})",
            "(?i)meeting\\s+date[:\\s]+([A-Z][a-z]+\\s+\\d{1,2},?\\s+\\d{4})",
            "(?i)(?:held|convene).*?(?:on|at)\\s+([A-Z][a-z]+\\s+\\d{1,2},?\\s+\\d{4})",
        ]
        for pattern in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern),
               let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)) {
                return cleanHTML((html as NSString).substring(with: match.range(at: 1)))
            }
        }
        return nil
    }

    // MARK: - Executive Compensation

    static func parseExecutiveCompensation(from html: String) -> String? {
        let lower = html.lowercased()
        guard let range = lower.range(of: "executive compensation")
                ?? lower.range(of: "compensation discussion") else {
            return nil
        }
        let section = String(html[range.lowerBound...]).prefix(2000)
        return cleanHTML(String(section))
    }

    // MARK: - Form 4 XML Parsing

    static func parseForm4(_ xml: String, accessionNumber: String, filingDate: String) -> [InsiderTransactionEntry] {
        var entries: [InsiderTransactionEntry] = []
        let ownerName = xmlExtract(xml, pattern: "(?i)<rptOwnerName>([^<]+)</rptOwnerName>") ?? "Unknown"
        let title = xmlExtract(xml, pattern: "(?i)<officerTitle>([^<]+)</officerTitle>")

        let txPattern = "(?i)<nonDerivativeTransaction>(.*?)</nonDerivativeTransaction>"
        if let regex = try? NSRegularExpression(pattern: txPattern, options: .dotMatchesLineSeparators) {
            let range = NSRange(xml.startIndex..., in: xml)
            for m in regex.matches(in: xml, range: range) {
                let txXML = (xml as NSString).substring(with: m.range(at: 1))
                let acqDisp = xmlExtract(txXML, pattern: "(?i)<transactionAcquiredDisposedCode.*?<value>([AD])</value>")
                let shares = xmlExtract(txXML, pattern: "(?i)<transactionShares.*?<value>([\\d.]+)</value>").flatMap(Double.init)
                let price = xmlExtract(txXML, pattern: "(?i)<transactionPricePerShare.*?<value>([\\d.]+)</value>").flatMap(Double.init)
                let txDate = xmlExtract(txXML, pattern: "(?i)<transactionDate.*?<value>([\\d-]+)</value>")
                let code = xmlExtract(txXML, pattern: "(?i)<transactionCode>([A-Z]+)</transactionCode>")

                let txType: String
                switch code?.uppercased() {
                case "S": txType = "Sale"
                case "P": txType = "Purchase"
                case "A", "M": txType = "Option Exercise"
                case "G": txType = "Gift"
                case "C": txType = "Conversion"
                default: txType = acqDisp == "D" ? "Disposition" : "Acquisition"
                }

                let totalValue: Double? = {
                    guard let s = shares, let p = price else { return nil }
                    return s * p
                }()
                entries.append(InsiderTransactionEntry(
                    insiderName: ownerName, title: title, transactionType: txType,
                    shares: shares, pricePerShare: price, totalValue: totalValue,
                    sharesOwned: nil, filingDate: filingDate,
                    transactionDate: txDate, accessionNumber: accessionNumber))
            }
        }
        return entries
    }

    // MARK: - Utilities

    static func cleanHTML(_ s: String) -> String {
        s.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
         .replacingOccurrences(of: "&amp;", with: "&")
         .replacingOccurrences(of: "&lt;", with: "<")
         .replacingOccurrences(of: "&gt;", with: ">")
         .replacingOccurrences(of: "&nbsp;", with: " ")
         .replacingOccurrences(of: "&#\\d+;", with: "", options: .regularExpression)
         .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func xmlExtract(_ xml: String, pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: xml, range: NSRange(xml.startIndex..., in: xml)),
              match.numberOfRanges > 1 else { return nil }
        return (xml as NSString).substring(with: match.range(at: 1)).trimmingCharacters(in: .whitespacesAndNewlines)
    }

}
