/*
 * openq4_ios_metrics.m — MetricKit subscriber.
 *
 * The purpose-built instrument for "why did my app die in the field", which is
 * exactly this port's situation: a device on the other end of an OTA link, no
 * cable, and a termination that leaves no signal for any handler to catch.
 *
 * Two things arrive, both written into Documents/metrickit/ so they travel with
 * the other logs:
 *
 *  - MXAppExitMetric.foregroundExitData — cumulative foreground exit counts BY
 *    REASON: watchdog, memory resource limit, bad access, illegal instruction,
 *    normal. Even with no crash diagnostic attached, whichever counter
 *    increments after a reproduction names the killer's category. That is the
 *    single fact this investigation has been missing.
 *  - MXCrashDiagnostic payloads, which on iOS 15+ include watchdog
 *    terminations with the termination reason string and a call-stack tree.
 *
 * Payloads are delivered at most once a day, and on the NEXT launch after the
 * event — so the file that explains a crash appears after the following start,
 * not during it.
 */

#import <Foundation/Foundation.h>
#import <MetricKit/MetricKit.h>
#include <stdio.h>

#include "openq4_ios_metrics.h"

@interface OpenQ4MetricSubscriber : NSObject <MXMetricManagerSubscriber>
@end

static NSString *OpenQ4_MetricsDir(void) {
	NSArray<NSString *> *paths =
		NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
	if (paths.count == 0) {
		return nil;
	}
	NSString *dir = [paths.firstObject stringByAppendingPathComponent:@"metrickit"];
	[NSFileManager.defaultManager createDirectoryAtPath:dir
							withIntermediateDirectories:YES
											 attributes:nil
												  error:NULL];
	return dir;
}

static void OpenQ4_WritePayload(NSData *json, NSString *kind, NSUInteger index) {
	NSString *dir = OpenQ4_MetricsDir();
	if (dir == nil || json == nil) {
		return;
	}
	// Indexed rather than timestamped: the scratchpad rules out Date-based
	// naming being stable across the delivery delay, and an index is enough to
	// tell payloads apart within a delivery.
	NSString *path = [dir stringByAppendingPathComponent:
		[NSString stringWithFormat:@"%@-%lu.json", kind, (unsigned long)index]];
	[json writeToFile:path atomically:YES];
	fprintf(stdout, "openQ4 metrickit: wrote %s\n", path.lastPathComponent.UTF8String);
	fflush(stdout);
}

@implementation OpenQ4MetricSubscriber

- (void)didReceiveMetricPayloads:(NSArray<MXMetricPayload *> *)payloads {
	NSUInteger i = 0;
	for (MXMetricPayload *payload in payloads) {
		OpenQ4_WritePayload(payload.JSONRepresentation, @"metric", i++);

		// Summarise the exit reasons into the ordinary log as well, so the
		// answer is visible without parsing JSON.
		MXAppExitMetric *exits = payload.applicationExitMetrics;
		if (exits != nil) {
			MXForegroundExitData *fg = exits.foregroundExitData;
			fprintf(stdout,
					"openQ4 metrickit: foreground exits — watchdog=%lu memoryLimit=%lu "
					"badAccess=%lu abnormal=%lu illegalInstruction=%lu normal=%lu\n",
					(unsigned long)fg.cumulativeAppWatchdogExitCount,
					(unsigned long)fg.cumulativeMemoryResourceLimitExitCount,
					(unsigned long)fg.cumulativeBadAccessExitCount,
					(unsigned long)fg.cumulativeAbnormalExitCount,
					(unsigned long)fg.cumulativeIllegalInstructionExitCount,
					(unsigned long)fg.cumulativeNormalAppExitCount);
			fflush(stdout);
		}
	}
}

- (void)didReceiveDiagnosticPayloads:(NSArray<MXDiagnosticPayload *> *)payloads {
	NSUInteger i = 0;
	for (MXDiagnosticPayload *payload in payloads) {
		OpenQ4_WritePayload(payload.JSONRepresentation, @"diagnostic", i++);
		for (MXCrashDiagnostic *crash in payload.crashDiagnostics) {
			fprintf(stdout, "openQ4 metrickit: crash — reason='%s' signal=%s exception=%s\n",
					crash.terminationReason.UTF8String ?: "(none)",
					crash.signal.stringValue.UTF8String ?: "(none)",
					crash.exceptionType.stringValue.UTF8String ?: "(none)");
			fflush(stdout);
		}
	}
}

@end

static OpenQ4MetricSubscriber *g_subscriber = nil;

void OpenQ4_iOS_MetricsInit(void) {
	if (g_subscriber != nil) {
		return;
	}
	g_subscriber = [OpenQ4MetricSubscriber new];
	[MXMetricManager.sharedManager addSubscriber:g_subscriber];
	fprintf(stdout, "openQ4 metrickit: subscribed (payloads arrive on the NEXT launch after an event)\n");
	fflush(stdout);
}

const char *OpenQ4_iOS_ThermalState(void) {
	switch (NSProcessInfo.processInfo.thermalState) {
		case NSProcessInfoThermalStateNominal:  return "nominal";
		case NSProcessInfoThermalStateFair:     return "fair";
		case NSProcessInfoThermalStateSerious:  return "serious";
		case NSProcessInfoThermalStateCritical: return "critical";
	}
	return "?";
}
