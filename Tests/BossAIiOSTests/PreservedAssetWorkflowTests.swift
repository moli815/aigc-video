import XCTest
import UIKit
@testable import BossAI

@MainActor
final class PreservedAssetWorkflowTests: XCTestCase {
    private func image(_ color:UIColor,size:CGSize=CGSize(width:100,height:80))->UIImage {
        let format=UIGraphicsImageRendererFormat();format.scale=1
        return UIGraphicsImageRenderer(size:size,format:format).image{context in color.setFill();context.fill(CGRect(origin:.zero,size:size))}
    }
    private func context(box:[String:Any] = ["x":0.25,"y":0.25,"width":0.5,"height":0.5],
                         index:Int=2,preserveOutside:Bool=true,prompt:String="替换标识")->ImageRequestContext {
        ImageRequestContext(prompt:prompt,references:[image(.red).pngData()!,image(.green,size:CGSize(width:40,height:20)).pngData()!],
            taskKind:"edit",qualityTier:"high",requestedCount:nil,aspectRatio:"5:4",renderIntent:"flat_artwork",
            structured:["preserve_outside":preserveOutside,"preserve_assets":[["reference_index":index,"box":box]]],layerDecomposition:false)
    }
    private func pixels(_ data:Data)->[UInt8] {
        let cg=UIImage(data:data)!.cgImage!;var bytes=[UInt8](repeating:0,count:cg.width*cg.height*4)
        bytes.withUnsafeMutableBytes{raw in
            let ctx=CGContext(data:raw.baseAddress,width:cg.width,height:cg.height,bitsPerComponent:8,bytesPerRow:cg.width*4,
                space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
            ctx.draw(cg,in:CGRect(x:0,y:0,width:cg.width,height:cg.height))
        };return bytes
    }
    func testOnlyBaseIsSentToModelAndOriginalIdentityIsRetained() throws {
        let ctx=context(),plan=try XCTUnwrap(PreservedAssetWorkflow.plan(ctx))
        XCTAssertEqual(plan.background.references,[ctx.references[0]])
        XCTAssertEqual(plan.background.requestId,ctx.requestId)
        XCTAssertNil(plan.background.structured?["preserve_assets"])
        XCTAssertTrue(plan.background.prompt.contains("不绘制替换Logo"))
    }
    func testInvalidRegionsAndReferencesFailBeforePaidExecution() {
        for invalid in [context(box:["x":0.9,"y":0.1,"width":0.3,"height":0.2]),
                        context(box:["x":Double.nan,"y":0,"width":0.1,"height":0.1]),context(index:1),context(index:3)] {
            XCTAssertThrowsError(try PreservedAssetWorkflow.plan(invalid))
        }
    }
    func testOutsidePixelsAreOriginalAndLogoKeepsAspect() throws {
        let plan=try XCTUnwrap(PreservedAssetWorkflow.plan(context()))
        let result=try PreservedAssetWorkflow.compose(plan:plan,cleaned:image(.blue));let p=pixels(result)
        XCTAssertEqual(Array(p[0..<3]),[255,0,0])
        var xs:[Int]=[],ys:[Int]=[]
        for y in 0..<80 { for x in 0..<100 {let i=(y*100+x)*4;if p[i]<20 && p[i+1]>230 && p[i+2]<20 {xs.append(x);ys.append(y)}} }
        XCTAssertFalse(xs.isEmpty)
        let width=Double(xs.max()!-xs.min()!+1),height=Double(ys.max()!-ys.min()!+1)
        XCTAssertEqual(width/height,2,accuracy:0.2)
        let attachment=XCTAttachment(image:UIImage(data:result)!);attachment.name="brand-preserve-outside-and-aspect";attachment.lifetime = .keepAlways;add(attachment)
    }
    func testOtherEditsAreKeptOnlyWhenExplicitlyRequested() throws {
        let plan=try XCTUnwrap(PreservedAssetWorkflow.plan(context(preserveOutside:false)))
        let p=pixels(try PreservedAssetWorkflow.compose(plan:plan,cleaned:image(.blue)))
        XCTAssertEqual(Array(p[0..<3]),[0,0,255])
    }
    func testCanvasMismatchDoesNotStretchThePoster() throws {
        let plan=try XCTUnwrap(PreservedAssetWorkflow.plan(context()))
        XCTAssertThrowsError(try PreservedAssetWorkflow.compose(plan:plan,cleaned:image(.blue,size:CGSize(width:80,height:100))))
    }
    func testACompositionFailureReusesThePaidBackground() async throws {
        let plan=try XCTUnwrap(PreservedAssetWorkflow.plan(context(prompt:UUID().uuidString)))
        var calls=0
        for _ in 0..<2 {
            do {_ = try await PreservedAssetWorkflow.generate(plan:plan){_ in calls+=1;return Data("bad-local-decode".utf8)};XCTFail("must reject invalid image")}
            catch {XCTAssertTrue(error is PreservedAssetWorkflow.Failure)}
        }
        XCTAssertEqual(calls,1)
    }
    func testExportRealToolContractForControlledReleaseProbe() throws {
        let tool: [String:Any] = ["type":"function","function":ToolManifest.imageEditFunction]
        let fixture: [String:Any] = ["instructions":ImageDesignGuidance.instructions(for:"替换海报logo"),"tools":[tool],
            "base":image(.red).pngData()!.base64EncodedString(),"asset":image(.green,size:CGSize(width:40,height:20)).pngData()!.base64EncodedString()]
        let data=try JSONSerialization.data(withJSONObject:fixture,options:[.sortedKeys])
        let attachment=XCTAttachment(data:data,uniformTypeIdentifier:"public.json");attachment.name="brand-contract-fixture";attachment.lifetime = .keepAlways;add(attachment)
    }
}
