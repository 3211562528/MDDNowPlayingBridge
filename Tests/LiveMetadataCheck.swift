import Foundation
@main struct LiveMetadataCheck {
 static func main() async {
  guard let pid = CommandLine.arguments.dropFirst().first.flatMap(Int32.init) else { exit(2) }
  switch await MDDPageClient().observe(pid:pid) {
  case .item(let item): print("Current course:",item.id,item.title,"cover:",item.coverURL != nil)
  case .none: print("No loaded course")
  case .unavailable: print("Metadata unavailable");exit(1)
  }
 }
}
