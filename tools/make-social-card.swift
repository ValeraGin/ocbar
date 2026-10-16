import AppKit
let size=NSSize(width:1200,height:630)
let rep=NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:1200,pixelsHigh:630,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current=NSGraphicsContext(bitmapImageRep:rep)
func color(_ hex:UInt32)->NSColor{NSColor(srgbRed:CGFloat((hex>>16)&255)/255,green:CGFloat((hex>>8)&255)/255,blue:CGFloat(hex&255)/255,alpha:1)}
color(0x17201D).setFill();NSRect(origin:.zero,size:size).fill()
let lime=color(0xC3F36B), paper=color(0xF4F6ED)
func label(_ text:String,_ x:CGFloat,_ y:CGFloat,_ font:NSFont,_ c:NSColor){(text as NSString).draw(at:NSPoint(x:x,y:y),withAttributes:[.font:font,.foregroundColor:c])}
NSImage(contentsOfFile:"app/Resources/AppIcon.icns")!.draw(in:NSRect(x:55,y:480,width:100,height:100))
label("ocbar",165,505,.systemFont(ofSize:44,weight:.semibold),paper)
label("Three routes.",70,310,NSFont(name:"Georgia",size:84)!,paper)
label("One Mac.",70,210,NSFont(name:"Georgia-Italic",size:84)!,lime)
label("OPENCONNECT FOR MACOS  /  OPEN SOURCE · MIT",74,65,.monospacedSystemFont(ofSize:17,weight:.regular),color(0xACB7AA))
let lines:[(CGFloat,UInt32,String)]=[(410,0x7787B4,"Personal VPN"),(315,0xC3F36B,"Work / ocbar"),(220,0xAD9671,"Home NAS")]
for(y,hex,title) in lines{
 color(hex).setStroke();let path=NSBezierPath();path.move(to:NSPoint(x:760,y:315));path.line(to:NSPoint(x:850,y:y));path.line(to:NSPoint(x:1105,y:y));path.lineWidth=3;path.stroke()
 color(0x17201D).setFill();NSRect(x:880,y:y-18,width:190,height:38).fill()
 label(title,890,y-9,.monospacedSystemFont(ofSize:19,weight:.medium),color(hex))
}
lime.setFill();NSBezierPath(roundedRect:NSRect(x:742,y:297,width:36,height:36),xRadius:7,yRadius:7).fill()
NSGraphicsContext.restoreGraphicsState()
let dir="website/dist/assets/"
try rep.representation(using:.png,properties:[:])!.write(to:URL(fileURLWithPath:dir+"social-card.png"))
try rep.representation(using:.jpeg,properties:[.compressionFactor:0.9])!.write(to:URL(fileURLWithPath:dir+"social-card.jpg"))
