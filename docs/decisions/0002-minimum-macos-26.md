# 2. Require macOS 26 or later

Accepted on 2026-11-01.

## Context

As of November 2026, macOS 27 is the current release. A newer minimum version lets yaga rely on recent SwiftUI and Observation APIs and spend less effort on compatibility code. On the other hand, many Mac users wait months, or a full year, before upgrading.

## Decision

yaga's deployment target is macOS 26.0. In general, yaga supports the current macOS release and the one before it. We review the minimum each autumn when a new macOS ships, and record any change as a new decision.

## Consequences

- APIs that are new in macOS 27 need availability checks, with a fallback on macOS 26.
- We test on both supported releases.
- People on macOS 15 or earlier can't run yaga.
