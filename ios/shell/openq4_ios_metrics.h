/*
 * openq4_ios_metrics.h — MetricKit subscriber.
 *
 * Names the reason for a termination that leaves no catchable signal. Payloads
 * land in Documents/metrickit/ and arrive on the launch AFTER the event.
 */

#ifndef OPENQ4_IOS_METRICS_H
#define OPENQ4_IOS_METRICS_H

#ifdef __cplusplus
extern "C" {
#endif

/* Call once at launch. */
void OpenQ4_iOS_MetricsInit(void);

/*
 * "nominal" / "fair" / "serious" / "critical".
 *
 * The charter asks for thermal state on every measurement line and this port
 * never had it. The cost of not having it was a whole A/B batch: after twenty
 * minutes of sustained load the device's baseline had fallen 13% and every
 * result in that batch, including the control, drifted with it. A number with no
 * thermal state beside it cannot be compared with a number taken later.
 */
const char *OpenQ4_iOS_ThermalState(void);

#ifdef __cplusplus
}
#endif

#endif /* OPENQ4_IOS_METRICS_H */
