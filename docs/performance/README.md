# Performance

This folder records performance work on yaga: what was slow, what caused it, what changed, and the measurements that show it, so that later work can tell what's been tried and compare against real numbers. [ARCHITECTURE.md](../../ARCHITECTURE.md) describes how yaga works now, and links here for the evidence behind it.

| Date | Analysis | Result |
| --- | --- | --- |
| 2026-11-03 | [Actions that waited on background work](2026-11-03-actions-waiting-on-background-work.md) | Checking out a branch in Linux went from about 2.8 seconds to 0.4, a checkout in a small repository from about 240 ms to 100, and a remote deletion during a quiet fetch from 3.9 seconds to 1.9. No git process starts on the main thread any more. |
