/*
 * openq4_ios_fontcheck.m — see the header for why this exists.
 *
 * The method: take a string the app really displays, print it back byte for
 * byte, then draw each interesting character on its own into a small greyscale
 * bitmap and count the ink. A character that survives the round trip as bytes
 * but rasterises to an empty bitmap is a glyph failure; a character missing from
 * the bytes is a string failure. Nothing else needs to be inferred.
 */
#import <CoreText/CoreText.h>
#import <UIKit/UIKit.h>

#include <stdio.h>

#include "openq4_ios_fontcheck.h"

/*
 * Ink coverage for one character at the size the settings sheet actually uses.
 * Returns the fraction of pixels with any ink, and fills 'glyphOut' with the
 * glyph id CoreText resolves the character to — 0 means the font does not cover
 * it at all, which would mean a substituted font rather than a broken one.
 */
static float OpenQ4_GlyphInk(UniChar ch, UIFont *font, CGGlyph *glyphOut, BOOL *hasGlyphOut) {
	const int side = 32;
	*glyphOut = 0;
	*hasGlyphOut = NO;

	// Toll-free bridged, NOT CTFontCreateWithName(font.fontName): the system
	// font's name begins with a dot and is not a lookup key CoreText will
	// resolve, so creating from it silently yields a different face and the
	// measurement would be of a font the labels never use.
	CTFontRef ctFont = (__bridge CTFontRef)font;
	CGGlyph glyph = 0;
	*hasGlyphOut = CTFontGetGlyphsForCharacters(ctFont, &ch, &glyph, 1);
	*glyphOut = glyph;

	CGColorSpaceRef gray = CGColorSpaceCreateDeviceGray();
	CGContextRef ctx = CGBitmapContextCreate(NULL, side, side, 8, side, gray, (CGBitmapInfo)kCGImageAlphaNone);
	CGColorSpaceRelease(gray);
	if (ctx == NULL) {
		return -1.0f;
	}

	CGContextSetGrayFillColor(ctx, 0.0, 1.0);
	CGContextFillRect(ctx, CGRectMake(0, 0, side, side));

	// FLIP FIRST. UIKit text drawing assumes a top-left origin; a raw
	// CGBitmapContext is bottom-left. Without this the glyph is drawn outside
	// the bitmap and every character measures as blank — an instrument that
	// reports the very failure it was built to detect, no matter what the
	// device is doing. Caught by running the same logic on macOS first.
	CGContextTranslateCTM(ctx, 0.0, (CGFloat)side);
	CGContextScaleCTM(ctx, 1.0, -1.0);

	// Drawn through UIKit rather than CoreText directly, because UIKit is what
	// the labels use and the question is about the path the labels take.
	UIGraphicsPushContext(ctx);
	NSString *s = [NSString stringWithCharacters:&ch length:1];
	[s drawAtPoint:CGPointMake(2, 2)
	withAttributes:@{ NSFontAttributeName: font,
					  NSForegroundColorAttributeName: UIColor.whiteColor }];
	UIGraphicsPopContext();

	const unsigned char *pixels = (const unsigned char *)CGBitmapContextGetData(ctx);
	int lit = 0;
	if (pixels != NULL) {
		for (int i = 0; i < side * side; i++) {
			if (pixels[i] > 24) {
				lit++;
			}
		}
	}
	CGContextRelease(ctx);
	return (float)lit / (float)(side * side);
}

void OpenQ4_iOS_FontCheck(const char *when) {
	// UIKit text APIs are main-thread only, and this is called from the engine
	// thread and the bridge socket thread as well as from UIKit itself.
	if (!NSThread.isMainThread) {
		NSString *label = [NSString stringWithUTF8String:(when ? when : "?")];
		dispatch_async(dispatch_get_main_queue(), ^{
			OpenQ4_iOS_FontCheck(label.UTF8String);
		});
		return;
	}

	// A real label from the settings sheet, so a string-side fault would show up
	// here in the same form the maintainer photographed. It does not: the bytes arrive
	// intact and the glyphs draw nothing, which is what the device already told
	// us. The remaining question is WHICH font configurations fail.
	NSString *sample = @"openQ4 Settings: Look Sensitivity 100% (a s g S)";
	fprintf(stdout, "openQ4 fontcheck [%s]: len=%lu text=\"%s\"\n",
			when ? when : "?", (unsigned long)sample.length, sample.UTF8String);

	/*
	 * Four faces, chosen so that one run separates the surviving explanations.
	 *
	 * The system font on iOS 26/27 is a VARIABLE font: outlines are a base plus
	 * per-instance deltas, and a failure in that delta path would hit some glyphs
	 * and not others exactly as observed, while leaving glyph lookup working —
	 * which it does, since CoreText returns the same glyph ids macOS does.
	 *
	 *   system 17      what the labels actually use, and what is broken
	 *   system 13      same face, different size: separates a per-size raster
	 *                  cache problem from a per-glyph outline problem
	 *   system 17 bold a different variable INSTANCE of the same family
	 *   Helvetica 17   a plain static face, no variations anywhere
	 *
	 * If Helvetica is clean and the system font is not, the variable-font path is
	 * the culprit and switching the shell's labels to a static face both proves
	 * it and fixes the UI.
	 */
	UIFont *faces[4];
	const char *faceNames[4];
	faces[0] = [UIFont systemFontOfSize:17];               faceNames[0] = "system-17";
	faces[1] = [UIFont systemFontOfSize:13];               faceNames[1] = "system-13";
	faces[2] = [UIFont boldSystemFontOfSize:17];           faceNames[2] = "system-17-bold";
	faces[3] = [UIFont fontWithName:@"Helvetica" size:17]; faceNames[3] = "helvetica-17";

	for (int f = 0; f < 4; f++) {
		UIFont *font = faces[f];
		if (font == nil) {
			fprintf(stdout, "openQ4 fontcheck [%s]: %s unavailable\n", when ? when : "?", faceNames[f]);
			continue;
		}

		// Every printable ASCII character, not a hand-picked sample: the shape of
		// the failing SET is the evidence, and a list chosen from the maintainer's report
		// can only ever confirm the maintainer's report.
		char blank[128];
		int numBlank = 0;
		int missingGlyph = 0;
		for (UniChar ch = 33; ch < 127; ch++) {
			CGGlyph glyph = 0;
			BOOL hasGlyph = NO;
			const float ink = OpenQ4_GlyphInk(ch, font, &glyph, &hasGlyph);
			if (!hasGlyph) {
				missingGlyph++;
			}
			if (ink >= 0.0f && ink < 0.0005f && numBlank < (int)sizeof(blank) - 1) {
				blank[numBlank++] = (char)ch;
			}
		}
		blank[numBlank] = '\0';

		fprintf(stdout, "openQ4 fontcheck [%s]: %-14s name='%s' blank=%d unmapped=%d [%s]\n",
				when ? when : "?", faceNames[f], font.fontName.UTF8String,
				numBlank, missingGlyph, blank);
	}
	fflush(stdout);
}
