import Foundation

var config = Config()
config.blockedSites = ["x.com", "youtube.com", "instagram.com", "linkedin.com", "pinterest.com"]

let shouldBlock = [
    "https://x.com/", "https://x.com/home", "https://www.x.com/", "https://mobile.x.com/feed",
    "http://x.com", "https://youtube.com/watch?v=abc", "https://m.youtube.com/",
    "https://www.instagram.com/p/123", "https://linkedin.com/in/me",
]
let shouldNotBlock = [
    "https://dropbox.com/", "https://www.dropbox.com/home", "https://dropbox.com/s/xyz",
    "https://xx.com/", "https://notx.com/", "https://myx.com/",
    "https://google.com/search?q=x.com", "https://example.com/",
    "https://myyoutube.com/", "https://youtube.company.com/", "https://fakelinkedin.com/",
    "https://news.ycombinator.com/",
]

var failures = 0
for url in shouldBlock {
    if let hit = config.matchedSite(for: url) {
        print("  ok      BLOCK  \(url)  -> \(hit)")
    } else {
        print("  FAIL    should have blocked: \(url)"); failures += 1
    }
}
for url in shouldNotBlock {
    if let hit = config.matchedSite(for: url) {
        print("  FAIL    wrongly blocked: \(url)  -> matched \(hit)"); failures += 1
    } else {
        print("  ok      allow  \(url)")
    }
}
print(failures == 0 ? "\nALL PASS" : "\n\(failures) FAILURES")
exit(failures == 0 ? 0 : 1)
