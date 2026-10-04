// OpenQ4Vision-Bridging-Header.h — what the Swift app entry needs to see of the
// ObjC shell. Deliberately tiny: the SwiftUI file is scene plumbing only, and
// every piece of engine and shell logic stays in C/ObjC/C++ where the iOS target
// already shares it.
#import "OpenQ4HostViewController.h"
#import "OpenQ4Immersive.h"
#import "OpenQ4Vision3D.h"
#import "../shell/openq4_ios_url.h"
#import "../shell/openq4_ios_settings.h"   // the gear ornament opens the 3D section
