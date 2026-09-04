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
// ---- Reason validator: the gate that stops lazy or mashed unlock reasons ----
let shouldReject: [(String, String)] = [
    ("als;djaskdj asdkjhasd qwerpoiu zxcvmnb lkjhgfds mnbvcxz asdfghjkl", "keyboard mash"),
    ("i need it because im tired", "too short"),
    ("need need need need need need need need need need need", "repeated words"),
    ("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa bbbb", "held-down key"),
    ("ok ok ok ok ok ok ok ok ok ok ok ok ok ok ok ok ok ok ok ok ok", "repeated short words"),
]
let shouldAccept: [String] = [
    "I need to check a work message on LinkedIn from a recruiter before my call at three.",
    "Looking up a tutorial on YouTube for the exact error I am hitting in the build right now.",
]
for (text, why) in shouldReject {
    if case .ok = ReasonValidator.check(text) {
        print("  FAIL    accepted a bad reason (\(why)): \(text)"); failures += 1
    } else { print("  ok      reject (\(why))") }
}
for text in shouldAccept {
    if case .rejected(let msg) = ReasonValidator.check(text) {
        print("  FAIL    rejected a real reason: \(msg)  <- \(text)"); failures += 1
    } else { print("  ok      accept  \(text.prefix(40))…") }
}

print(failures == 0 ? "\nALL PASS" : "\n\(failures) FAILURES")
exit(failures == 0 ? 0 : 1)
