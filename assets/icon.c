#include <CoreGraphics/CoreGraphics.h>
#include <ImageIO/ImageIO.h>
#include <CoreFoundation/CoreFoundation.h>
#include <stdio.h>
static void roundRect(CGContextRef ctx, CGRect rect, double radius) {
    CGPathRef path = CGPathCreateWithRoundedRect(rect,radius,radius,NULL);
    CGContextAddPath(ctx,path); CGPathRelease(path);
}
int main(int argc, char **argv) {
    if (argc != 2) return 1;
    CGColorSpaceRef cs = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGContextRef c = CGBitmapContextCreate(NULL,1024,1024,8,0,cs,kCGImageAlphaPremultipliedLast);
    if (!c) return 1;
    roundRect(c, CGRectMake(72,72,880,880),190); CGContextClip(c);
    CGFloat colors[] = {.17,.36,.85,1, .06,.12,.30,1};
    CGGradientRef gradient = CGGradientCreateWithColorComponents(cs,colors,NULL,2);
    CGContextDrawLinearGradient(c,gradient,CGPointMake(180,900),CGPointMake(850,80),0);
    CGContextSetRGBStrokeColor(c,.80,.89,1,1); CGContextSetLineWidth(c,22);
    roundRect(c,CGRectMake(215,290,595,440),35); CGContextStrokePath(c);
    CGContextSetRGBFillColor(c,.11,.22,.48,1); roundRect(c,CGRectMake(230,305,565,355),21); CGContextFillPath(c);
    CGContextSetRGBStrokeColor(c,.80,.89,1,1); CGContextSetLineWidth(c,22);
    CGContextMoveToPoint(c,512,290); CGContextAddLineToPoint(c,512,215);
    CGContextMoveToPoint(c,400,205); CGContextAddLineToPoint(c,624,205); CGContextStrokePath(c);
    CGContextSetRGBFillColor(c,.35,.69,1,1); roundRect(c,CGRectMake(535,400,195,260),24); CGContextFillPath(c);
    CGContextSetRGBStrokeColor(c,.93,.97,1,1); CGContextSetLineWidth(c,14);
    roundRect(c,CGRectMake(535,400,195,260),24); CGContextStrokePath(c);
    CGContextSetRGBFillColor(c,.93,.97,1,1); CGContextFillEllipseInRect(c,CGRectMake(624,413,16,16));
    for (int i=0;i<3;++i) {
        CGContextSetRGBFillColor(c,.8,.89,1,1); CGContextFillEllipseInRect(c,CGRectMake(248+i*28,686,13,13));
    }
    CGImageRef image = CGBitmapContextCreateImage(c);
    CFURLRef url = CFURLCreateFromFileSystemRepresentation(NULL,(UInt8 *)argv[1],strlen(argv[1]),false);
    CGImageDestinationRef dest = CGImageDestinationCreateWithURL(url,CFSTR("public.png"),1,NULL);
    CGImageDestinationAddImage(dest,image,NULL); bool ok = CGImageDestinationFinalize(dest);
    CFRelease(dest); CFRelease(url); CGImageRelease(image); CGGradientRelease(gradient);
    CGContextRelease(c); CGColorSpaceRelease(cs); return ok ? 0 : 1;
}
