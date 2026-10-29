import Foundation
@main struct CacheCheck {
 static func main() async {
  guard let text=CommandLine.arguments.dropFirst().first,let pid=Int32(text) else { print("SKIP: open an MDD course before the live cache check"); return }
  let client=MDDPageClient()
  var expected:PlaybackItem?
  for _ in 0..<5 {
   guard case .item(let item)=await client.observe(pid:pid) else {fatalError("Missing live metadata")}
   if let expected {guard expected.id==item.id && expected.title==item.title else{fatalError("Course changed during cache test")}}
   expected=item
  }
  let lists=await client.listRequests,details=await client.detailRequests,scans=await client.portScans
  guard lists==5 && details==1 && scans==1 else{fatalError("Cache missed: lists=\(lists) details=\(details) scans=\(scans)")}
  guard case .item(let item)=await client.observe(pid:pid,forceRefresh:true),item.id==expected?.id else{fatalError("Forced refresh failed")}
  let refreshed=await client.detailRequests
  guard refreshed==2 else{fatalError("Forced refresh did not run")}
  print("PASS: 5 live reads used 1 port discovery and 1 detail evaluation; state-change refresh still works")
 }
}
