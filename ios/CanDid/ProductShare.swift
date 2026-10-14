import SwiftUI
import MessageUI
import UIKit
import CoreText

struct ProductFollowup:View {
    @EnvironmentObject var store:Store
    @Environment(\.dismiss) private var dismiss
    let draft:FollowupDraft
    @State private var current:FollowupDraft?
    @State private var title="";@State private var text="";@State private var recipient=""
    @State private var instruction="";@State private var rewriteJob:BusinessJob?
    @State private var mailVersion:Int?
    @State private var includeTranscript=false;@State private var email=false;@State private var sharing=false
    @State private var files:[URL]=[]
    private var value:FollowupDraft {current ?? draft}
    private var dirty:Bool {title != value.title || text != value.text || recipient != value.recipient}
    var body:some View {NavigationStack {Form {
        Section(value.internal ? "内部纪要":"客户跟进") {
            Text(value.internal ? "仅用于内部同步，请核对接收对象。":"默认只包含本场与客户讨论的内容。发送前可修改，不添加未经讨论的承诺。").font(.caption)
            TextField("标题",text:$title);TextField("接收对象",text:$recipient).textInputAutocapitalization(.never)
            TextEditor(text:$text).frame(minHeight:230).accessibilityLabel("跟进稿正文")
            TextField("让 Candid 改写，例如更简短",text:$instruction)
            Button("按要求改写") {Task {guard await save() else{return};await store.perform {rewriteJob=try await store.api.call("/v1/followups/"+value.id+"/rewrite",method:"POST",body:["instruction":instruction,"client_request_id":UUID().uuidString])}}}.disabled(instruction.isEmpty || store.busy || rewriteJob?.status=="running" || rewriteJob?.status=="queued")
            if let job=rewriteJob {ProductJobList(jobs:[job])}
            Button("保存修改"){Task {await save()}}.disabled(!dirty || store.busy)
            Text(value.send_status=="sent" ? "已发出 · 不代表对方已收到或回复":"尚未标记为已发出").font(.caption).foregroundStyle(RecordingFormat.secondary)
        }
        if !value.internal {Section("发送") {
            if value.channel=="email" && MFMailComposeViewController.canSendMail() {Button("用我的邮件发送",systemImage:"envelope") {Task {if await save(){mailVersion=value.version;email=true}}}.disabled(store.busy)}
            else {Text(value.channel=="email" ? "系统邮件暂不可用，可分享稿件后手动记录发送。":"使用自己的微信或 WhatsApp 发送，完成后标记一次。").font(.caption);ShareLink(item:text){Label("分享稿件",systemImage:"square.and.arrow.up")}}
            Button("我已发出",systemImage:"checkmark.circle") {Task {if await save(){await receipt("sent",manual:true)}}}.disabled(store.busy || value.send_status=="sent")
        }}
        Section("导出") {
            Toggle("包含本场原文",isOn:$includeTranscript)
            ForEach(["PDF","Word","图片卡片","文字"],id:\.self) {format in Button("导出 "+format){Task {await export(format)}}.disabled(store.busy)}
            Text("默认不包含全量原文。内部纪要与客户稿件分别导出。").font(.caption)
        }
    }.navigationTitle(value.internal ? "内部纪要":"客户跟进").navigationBarTitleDisplayMode(.inline)
        .toolbar{Button("关闭"){dismiss()}}
        .onAppear{title=draft.title;text=draft.text;recipient=draft.recipient}
        .task(id:rewriteJob?.id) {
            guard let id=rewriteJob?.id else{return}
            while !Task.isCancelled {
                do {
                    let job:BusinessJob=try await store.api.call("/v1/business-jobs/"+id);rewriteJob=job
                    if job.status=="completed" {try await store.reloadProducts();if let changed=store.productDetails.flatMap(\.followups).first(where:{$0.id==value.id}) {current=changed;text=changed.text;title=changed.title};break}
                    if ["failed","cancelled","interrupted"].contains(job.status){break}
                } catch {store.error=error.localizedDescription;break}
                try? await Task.sleep(for:.seconds(2))
            }
        }
        .sheet(isPresented:$email){ProductMail(title:title,text:text,recipient:recipient){result in email=false;Task {await receipt(result,manual:false)}}}
        .sheet(isPresented:$sharing){ProductFileShare(files:files)}
    }}
    @discardableResult private func save() async ->Bool {
        guard dirty else{return true}
        do {current=try await store.api.call("/v1/followups/"+value.id,method:"PATCH",body:["title":title,"text":text,"recipient":recipient,"expected_version":value.version]);try await store.reloadProducts();return true} catch {store.error=error.localizedDescription;return false}
    }
    private func receipt(_ result:String,manual:Bool) async {await store.perform {current=try await store.api.call("/v1/followups/"+value.id+"/receipt",method:"POST",body:["result":result,"manual":manual,"sent_version":mailVersion ?? value.version]);try await store.reloadProducts()}}
    private func export(_ format:String) async {
        guard await save() else{return}
        await store.perform {
            let path="/v1/followups/"+value.id+"/export?include_transcript="+(includeTranscript ? "true":"false")
            if format=="Word" {let data=try await store.api.raw(path+"&format=word");files=[try ProductRenderer.write(data,extension:"docx")]}
            else {let content:ProductExport=try await store.api.call(path);files=try ProductRenderer.render(content,format:format)}
            sharing=true
        }
    }
}
struct ProductMail:UIViewControllerRepresentable {
    let title:String;let text:String;let recipient:String;let result:(String)->Void
    func makeCoordinator()->Coordinator {Coordinator(result)}
    func makeUIViewController(context:Context)->MFMailComposeViewController {
        let controller=MFMailComposeViewController();controller.mailComposeDelegate=context.coordinator
        controller.setSubject(title);controller.setMessageBody(text,isHTML:false)
        if !recipient.isEmpty {controller.setToRecipients(recipient.split(separator:",").map(String.init))}
        return controller
    }
    func updateUIViewController(_ uiViewController:MFMailComposeViewController,context:Context){}
    final class Coordinator:NSObject,MFMailComposeViewControllerDelegate {
        let result:(String)->Void;init(_ result:@escaping(String)->Void){self.result=result}
        func mailComposeController(_ controller:MFMailComposeViewController,didFinishWith r:MFMailComposeResult,error:Error?) {result(error != nil ? "failed":r == .sent ? "sent":r == .saved ? "saved":"cancelled")}
    }
}
struct ProductFileShare:UIViewControllerRepresentable {
    let files:[URL]
    func makeUIViewController(context:Context)->UIActivityViewController {UIActivityViewController(activityItems:files,applicationActivities:nil)}
    func updateUIViewController(_ uiViewController:UIActivityViewController,context:Context){}
}
@MainActor enum ProductRenderer {
    static func write(_ data:Data,extension ext:String)throws->URL {
        let dir=FileManager.default.temporaryDirectory.appendingPathComponent("CandidExports")
        try FileManager.default.createDirectory(at:dir,withIntermediateDirectories:true)
        let path=dir.appendingPathComponent(UUID().uuidString+"."+ext)
        try data.write(to:path,options:[.atomic,.completeFileProtection]);return path
    }
    static func render(_ value:ProductExport,format:String)throws->[URL] {
        if format=="文字" {return [try write(Data((value.title+"\n\n"+value.text).utf8),extension:"txt")]}
        let paragraph=NSMutableParagraphStyle();paragraph.lineSpacing=7
        let content=NSAttributedString(string:value.title+"\n\n"+value.text,attributes:[.font:UIFont.systemFont(ofSize:14),.foregroundColor:UIColor(red:0.2,green:0.21,blue:0.18,alpha:1),.paragraphStyle:paragraph])
        let setter=CTFramesetterCreateWithAttributedString(content)
        let bounds=CGRect(x:0,y:0,width:595,height:842);var offset=0;var pages:[CTFrame]=[]
        while offset<content.length {
            let path=CGPath(rect:bounds.insetBy(dx:42,dy:48),transform:nil)
            let frame=CTFramesetterCreateFrame(setter,CFRange(location:offset,length:0),path,nil)
            let range=CTFrameGetVisibleStringRange(frame)
            guard range.length>0 else{throw PrototypeError.message("导出排版失败，请尝试文字版本。")}
            pages.append(frame);offset+=range.length
        }
        func draw(_ frame:CTFrame,_ context:CGContext) {context.saveGState();context.translateBy(x:0,y:842);context.scaleBy(x:1,y:-1);CTFrameDraw(frame,context);context.restoreGState()}
        if format=="PDF" {let data=UIGraphicsPDFRenderer(bounds:bounds).pdfData {renderer in for frame in pages {renderer.beginPage();draw(frame,renderer.cgContext)}};return [try write(data,extension:"pdf")]}
        return try pages.map {frame in let image=UIGraphicsImageRenderer(size:bounds.size).image {renderer in UIColor(red:0.969,green:0.953,blue:0.914,alpha:1).setFill();renderer.fill(bounds);draw(frame,renderer.cgContext)};guard let bytes=image.pngData() else{throw PrototypeError.message("图片导出失败。")};return try write(bytes,extension:"png")}
    }
}

struct ProductPreparationExports:View {
    @EnvironmentObject var store:Store
    let pack:PreparationPack
    @State private var files:[URL]=[];@State private var sharing=false
    var body:some View {Menu("导出与分享准备包",systemImage:"square.and.arrow.up") {
        ForEach(["PDF","Word","图片卡片","文字"],id:\.self){format in Button(format){Task {await store.perform {
            let path="/v1/preparations/"+pack.id+"/export"
            if format=="Word" {files=[try ProductRenderer.write(try await store.api.raw(path+"?format=word"),extension:"docx")]}
            else {let value:ProductExport=try await store.api.call(path);files=try ProductRenderer.render(value,format:format)}
            sharing=true
        }}}}
    }.frame(minHeight:44).sheet(isPresented:$sharing){ProductFileShare(files:files)}}
}
