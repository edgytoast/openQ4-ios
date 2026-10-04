// OpenQ4-Bridging-Header.h — what the iOS target's Swift (App Intents, D-112)
// sees of the ObjC shell. One header: the intents only ever hand a URL to the
// D-096 handler. The visionOS target has its own bridging header
// (shell-visionos/OpenQ4Vision-Bridging-Header.h), which imports the same file.
#import "openq4_ios_url.h"
