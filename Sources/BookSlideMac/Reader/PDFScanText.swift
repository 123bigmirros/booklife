import PDFKit
import CoreText
import Vision
#if canImport(BookSlideCore)
import BookSlideCore
#endif

/// Create a local searchable rendition of image pages while keeping their
/// original graphics. The library continues to identify and share the source.
enum PDFScanText {
    static func recognize(in data: Data) throws -> Data {
        let document = try BookImportFile.pdfDocument(data)
        var recognizedPages = 0
        for index in 0..<document.pageCount {
            try Task.checkCancellation()
            guard let page = document.page(at:index),
                  page.string?.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty != false,
                  let reference = page.pageRef,
                  let rendered = try recognizedPage(reference),
                  let replacement = rendered.page(at:0) else { continue }
            replacement.rotation = page.rotation
            for annotation in page.annotations {
                if let copy = annotation.copy() as? PDFAnnotation { replacement.addAnnotation(copy) }
            }
            // Exchange the page in place so neighboring pages keep their order.
            document.insert(replacement,at:index)
            document.removePage(at:index+1)
            recognizedPages += 1
        }
        guard recognizedPages > 0, let result = document.dataRepresentation(),
              result.count <= BookImportFile.maximumSize * 2 else {
            throw ReaderError.message("没有找到可补充的扫描文字")
        }
        return result
    }

    private static func recognizedPage(_ source: CGPDFPage) throws -> PDFDocument? {
        var mediaBox = source.getBoxRect(.mediaBox)
        let cropBox = source.getBoxRect(.cropBox)
        guard !cropBox.isEmpty, !cropBox.isInfinite, !mediaBox.isEmpty else { return nil }
        let rotated = abs(source.rotationAngle) % 180 == 90
        let size = rotated ? CGSize(width:cropBox.height,height:cropBox.width) : cropBox.size
        let factor = 1800 / max(size.width,size.height)
        let pixels = CGSize(width:max(1,(size.width*factor).rounded()),height:max(1,(size.height*factor).rounded()))
        let imageRect = CGRect(origin:.zero,size:pixels)
        guard let bitmap = CGContext(data:nil,width:Int(pixels.width),height:Int(pixels.height),bitsPerComponent:8,
            bytesPerRow:0,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }

        bitmap.setFillColor(CGColor(gray:1,alpha:1))
        bitmap.fill(imageRect)
        let transform = source.getDrawingTransform(.cropBox,rect:imageRect,rotate:0,preserveAspectRatio:true)
        bitmap.concatenate(transform)
        bitmap.drawPDFPage(source)
        guard let image = bitmap.makeImage() else { return nil }

        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.automaticallyDetectsLanguage = true
        try VNImageRequestHandler(cgImage:image).perform([request])
        let lines = (request.results ?? []).compactMap { result -> (String,CGRect)? in
            guard let text = result.topCandidates(1).first?.string, !text.isEmpty else { return nil }
            let box = result.boundingBox
            return (text,CGRect(x:box.minX*pixels.width,y:box.minY*pixels.height,
                                width:box.width*pixels.width,height:box.height*pixels.height))
        }
        guard !lines.isEmpty else { return nil }

        let output = NSMutableData()
        guard let consumer = CGDataConsumer(data:output as CFMutableData),
              let context = CGContext(consumer:consumer,mediaBox:&mediaBox,nil) else { return nil }
        context.beginPDFPage(nil)
        context.drawPDFPage(source)
        context.concatenate(transform.inverted())
        for (text, box) in lines where !box.isEmpty {
            let font = CTFontCreateUIFontForLanguage(.system,max(1,box.height),nil)
                ?? CTFontCreateWithName("Helvetica" as CFString,max(1,box.height),nil)
            let key = NSAttributedString.Key(kCTFontAttributeName as String)
            let line = CTLineCreateWithAttributedString(NSAttributedString(string:text,attributes:[key:font]))
            let width = CTLineGetTypographicBounds(line,nil,nil,nil)
            guard width > 0 else { continue }
            context.saveGState()
            context.textMatrix = CGAffineTransform(scaleX:box.width/width,y:1)
            context.textPosition = CGPoint(x:box.minX,y:box.minY+box.height*0.16)
            context.setTextDrawingMode(.invisible)
            CTLineDraw(line,context)
            context.restoreGState()
        }
        context.endPDFPage()
        context.closePDF()
        guard let document = PDFDocument(data:output as Data), let replacement = document.page(at:0),
              replacement.numberOfCharacters > 0 else { return nil }
        replacement.setBounds(cropBox,for:.cropBox)
        return document
    }
}
