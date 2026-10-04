/*
 * openq4_ios_fontcheck.h — is the system font actually drawing its glyphs?
 *
 * the maintainer's device renders every UIKit label in this app with 'a', 's', 'g', 'S'
 * and '%' missing, spacing intact, while the same build on the simulator is
 * perfect. Two explanations fit that equally well from a photograph — the
 * strings are being mangled somewhere, or the glyphs are rasterising blank —
 * and they lead to completely different investigations. This tells them apart
 * in one line of log.
 */
#ifndef OPENQ4_IOS_FONTCHECK_H
#define OPENQ4_IOS_FONTCHECK_H

#ifdef __cplusplus
extern "C" {
#endif

/*
 * Log the string content and the per-glyph ink coverage for a sample of
 * characters. 'when' labels the call site, because WHEN it first fails is the
 * most useful single fact: clean at launch and broken after the engine has
 * loaded 2.5 GB points at memory pressure purging the glyph cache, whereas
 * broken from the first frame points somewhere else entirely.
 */
void OpenQ4_iOS_FontCheck(const char *when);

#ifdef __cplusplus
}
#endif

#endif /* OPENQ4_IOS_FONTCHECK_H */
