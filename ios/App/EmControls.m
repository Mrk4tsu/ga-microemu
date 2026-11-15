#import "EmControls.h"

UIImage *EmControlImage(EmControlIcon icon) {
    static NSMutableDictionary<NSNumber *, UIImage *> *images;
    if(!images)images=[NSMutableDictionary new]; // UIKit callers run on the main thread.
    UIImage *image=images[@(icon)];
    if(image)return image;
    NSArray<NSString *> *names=@[@"plus",@"square.on.square",@"keyboard",@"doc.text",
        @"xmark",@"arrow.up.left.and.arrow.down.right",@"gamecontroller",@"gamecontroller.fill",@"chevron.down",@"square.and.arrow.down",@"line.3.horizontal"];
    if(@available(iOS 13.0,*))image=[UIImage systemImageNamed:names[icon]];
    if(!image){
        // Vector fallback also keeps the iOS 12 deployment target usable.
        UIGraphicsBeginImageContextWithOptions(CGSizeMake(24,24),NO,0);
        [UIColor.whiteColor setStroke];[UIColor.whiteColor setFill];
        UIBezierPath *path=[UIBezierPath bezierPath];path.lineWidth=1.8;
        path.lineCapStyle=kCGLineCapRound;path.lineJoinStyle=kCGLineJoinRound;
        switch(icon){
            case EmControlMenu:
                for(int y=6;y<=18;y+=6){[path moveToPoint:CGPointMake(4,y)];[path addLineToPoint:CGPointMake(20,y)];}break;
            case EmControlAdd:
                [path moveToPoint:CGPointMake(12,4)];[path addLineToPoint:CGPointMake(12,20)];
                [path moveToPoint:CGPointMake(4,12)];[path addLineToPoint:CGPointMake(20,12)];break;
            case EmControlClose:
                [path moveToPoint:CGPointMake(6,6)];[path addLineToPoint:CGPointMake(18,18)];
                [path moveToPoint:CGPointMake(18,6)];[path addLineToPoint:CGPointMake(6,18)];break;
            case EmControlTabs:
                [[UIBezierPath bezierPathWithRoundedRect:CGRectMake(3,7,14,14) cornerRadius:2] stroke];
                [path moveToPoint:CGPointMake(8,3)];[path addLineToPoint:CGPointMake(21,3)];
                [path addLineToPoint:CGPointMake(21,16)];break;
            case EmControlLog:
                [[UIBezierPath bezierPathWithRoundedRect:CGRectMake(5,3,14,18) cornerRadius:2] stroke];
                for(int y=8;y<=16;y+=4){[path moveToPoint:CGPointMake(8,y)];[path addLineToPoint:CGPointMake(16,y)];}break;
            case EmControlExpand:
                [path moveToPoint:CGPointMake(4,10)];[path addLineToPoint:CGPointMake(4,4)];[path addLineToPoint:CGPointMake(10,4)];
                [path moveToPoint:CGPointMake(4,4)];[path addLineToPoint:CGPointMake(10,10)];
                [path moveToPoint:CGPointMake(20,14)];[path addLineToPoint:CGPointMake(20,20)];[path addLineToPoint:CGPointMake(14,20)];
                [path moveToPoint:CGPointMake(20,20)];[path addLineToPoint:CGPointMake(14,14)];break;
            case EmControlCollapse:
                [path moveToPoint:CGPointMake(5,9)];[path addLineToPoint:CGPointMake(12,16)];[path addLineToPoint:CGPointMake(19,9)];break;
            case EmControlImport:
                [path moveToPoint:CGPointMake(4,14)];[path addLineToPoint:CGPointMake(4,21)];[path addLineToPoint:CGPointMake(20,21)];[path addLineToPoint:CGPointMake(20,14)];
                [path moveToPoint:CGPointMake(12,3)];[path addLineToPoint:CGPointMake(12,15)];
                [path moveToPoint:CGPointMake(7,10)];[path addLineToPoint:CGPointMake(12,15)];[path addLineToPoint:CGPointMake(17,10)];break;
            case EmControlKeyboard:
                [[UIBezierPath bezierPathWithRoundedRect:CGRectMake(2,5,20,14) cornerRadius:2] stroke];
                for(int y=9;y<=12;y+=3)for(int x=6;x<=18;x+=4)UIRectFill(CGRectMake(x-1,y-1,2,2));
                [path moveToPoint:CGPointMake(7,16)];[path addLineToPoint:CGPointMake(17,16)];break;
            case EmControlPad: case EmControlPadHidden:
                [[UIBezierPath bezierPathWithRoundedRect:CGRectMake(2,6,20,13) cornerRadius:4] stroke];
                [path moveToPoint:CGPointMake(7,10)];[path addLineToPoint:CGPointMake(7,16)];
                [path moveToPoint:CGPointMake(4,13)];[path addLineToPoint:CGPointMake(10,13)];
                [[UIBezierPath bezierPathWithOvalInRect:CGRectMake(14,10,2,2)] fill];
                [[UIBezierPath bezierPathWithOvalInRect:CGRectMake(17,14,2,2)] fill];
                if(icon==EmControlPadHidden){[path moveToPoint:CGPointMake(3,3)];[path addLineToPoint:CGPointMake(21,21)];}break;
        }
        [path stroke];image=UIGraphicsGetImageFromCurrentImageContext();UIGraphicsEndImageContext();
    }
    image=[image imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];images[@(icon)]=image;
    return image;
}

UIBarButtonItem *EmIconItem(EmControlIcon icon, NSString *label, id target, SEL action) {
    UIBarButtonItem *item=[[UIBarButtonItem alloc] initWithImage:EmControlImage(icon) style:UIBarButtonItemStylePlain target:target action:action];
    item.accessibilityLabel=label;return item;
}

void EmSetButtonIcon(UIButton *button, EmControlIcon icon, NSString *label) {
    [button setTitle:nil forState:UIControlStateNormal];
    [button setImage:EmControlImage(icon) forState:UIControlStateNormal];
    button.accessibilityLabel=label;
}
