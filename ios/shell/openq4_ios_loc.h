/*
 * openq4_ios_loc.h — the UIKit shell's one string lookup.
 *
 * The key IS the English string. Every read site keeps the literal it always
 * had; the lookup only swaps in a translation when the running locale has one.
 * Nothing else changes shape, which is why this could be retrofitted onto the
 * settings table without touching the table.
 */

#ifndef OPENQ4_IOS_LOC_H
#define OPENQ4_IOS_LOC_H

#ifdef __OBJC__
#import <Foundation/Foundation.h>

/*
 * Look `key` up in Localizable.strings for the running locale, falling back to
 * `key` itself — which is the English text — when the locale's table has no
 * entry. That fallback is per-KEY, not per-table: a fr.lproj carrying ten of a
 * hundred strings shows ten French rows and ninety English ones, which is
 * exactly what a partially translated slice needs.
 *
 * NULL or empty in, empty out. The settings table's `detail` column is NULL for
 * most rows and the call sites read better without a guard at each one.
 */
NSString *OpenQ4_L(const char *key);

/* Same lookup for a key already held as an NSString (section names, which are
 * looked up by their English spelling and localised only at display). */
NSString *OpenQ4_LS(NSString *key);

#endif /* __OBJC__ */
#endif /* OPENQ4_IOS_LOC_H */
